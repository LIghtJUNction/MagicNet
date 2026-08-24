// Unit tests included from the matching src module.

use std::ffi::CString;
use std::fs;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::App;

use super::{
    cmdline_has_command, cmdline_has_script, command_text_full_timeout, command_text_timeout,
    compact_command_output, kill_and_reap_with, merge_command_output,
    module_transaction_stage_name, proc_start_time, read_proc_argv, read_proc_file_bounded,
    rename_module_transaction_entry, replace_module_text_files_transactionally,
    replace_module_text_files_transactionally_with_rename,
    replace_module_text_files_transactionally_with_stage_writer, write_secret_file,
    write_text_file, KillAndWait, MAX_COMMAND_STREAM_BYTES, MAX_PROC_CMDLINE_BYTES,
    MODULE_TRANSACTION_STAGING_DIRECTORY, MODULE_TRANSACTION_STAGING_PARENT,
};

#[test]
fn proc_start_time_allows_spaces_and_parentheses_in_comm() {
    let stat = "42 (worker name (stage)) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 424242 20";
    assert_eq!(proc_start_time(stat).as_deref(), Some("424242"));
    assert_eq!(proc_start_time("malformed"), None);
}

#[test]
fn bounded_proc_reader_preserves_exact_argv() {
    let directory = test_directory("proc-reader-argv");
    let cmdline = directory.join("cmdline");
    fs::write(&cmdline, b"/system/bin/sh\0/module/loop.sh\0").unwrap();

    assert_eq!(
        read_proc_argv(&cmdline).unwrap(),
        vec!["/system/bin/sh".to_string(), "/module/loop.sh".to_string()]
    );
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn bounded_proc_reader_rejects_oversize_and_malformed_cmdlines() {
    let directory = test_directory("proc-reader-limits");
    let oversized = directory.join("oversized");
    fs::write(&oversized, vec![b'x'; MAX_PROC_CMDLINE_BYTES + 1]).unwrap();
    let error = read_proc_file_bounded(&oversized, MAX_PROC_CMDLINE_BYTES).unwrap_err();
    assert!(
        error.contains("exceeds") || error.contains("timed out"),
        "unexpected fail-closed error: {error}"
    );

    let malformed = directory.join("malformed");
    fs::write(&malformed, b"/system/bin/sh\0bad\nargument\0").unwrap();
    assert!(read_proc_argv(&malformed)
        .unwrap_err()
        .contains("invalid argument"));
    fs::write(&malformed, b"/system/bin/sh").unwrap();
    assert!(read_proc_argv(&malformed)
        .unwrap_err()
        .contains("unterminated"));
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn bounded_proc_reader_times_out_and_reaps_a_blocked_worker() {
    let directory = test_directory("proc-reader-timeout");
    let fifo = directory.join("cmdline");
    let fifo_c = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo_c.as_ptr(), 0o600) }, 0);

    let started = Instant::now();
    let error = read_proc_file_bounded(&fifo, MAX_PROC_CMDLINE_BYTES).unwrap_err();
    let elapsed = started.elapsed();
    assert!(error.contains("timed out"), "unexpected error: {error}");
    assert!(
        elapsed >= Duration::from_millis(400) && elapsed < Duration::from_secs(2),
        "bounded proc timeout took {elapsed:?}"
    );
    fs::remove_dir_all(directory).unwrap();
}

struct NeverReap {
    killed: bool,
}

impl KillAndWait for NeverReap {
    fn kill(&mut self) {
        self.killed = true;
    }

    fn try_reap(&mut self) -> Result<bool, std::io::Error> {
        Ok(false)
    }
}

#[test]
fn proc_reader_cleanup_does_not_wait_forever_after_sigkill() {
    let mut waiter = NeverReap { killed: false };
    let started = Instant::now();
    assert!(!kill_and_reap_with(&mut waiter, Duration::from_millis(35)));
    assert!(waiter.killed);
    assert!(started.elapsed() < Duration::from_millis(250));
}

#[test]
fn managed_cmdlines_are_exact_and_prefix_decoys_are_rejected() {
    let script = "/module/.state/fswatch/magicnet-config.loop.sh";
    assert!(cmdline_has_script(
        &["/system/bin/sh".to_string(), script.to_string()],
        script
    ));
    assert!(!cmdline_has_script(
        &[
            "/tmp/decoy".to_string(),
            "-c".to_string(),
            "sleep 30; :".to_string(),
            "/system/bin/sh".to_string(),
            script.to_string(),
        ],
        script
    ));

    let cli = "/module/cli";
    assert!(cmdline_has_command(
        &[cli.to_string(), "config".to_string(), "apply".to_string()],
        cli,
        &["config", "apply"]
    ));
    assert!(!cmdline_has_command(
        &[
            "/tmp/decoy".to_string(),
            "-c".to_string(),
            "sleep 30; :".to_string(),
            "ignored".to_string(),
            cli.to_string(),
            "config".to_string(),
            "apply".to_string(),
        ],
        cli,
        &["config", "apply"]
    ));
}

fn test_directory(label: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "magicnet-utils-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is after the Unix epoch")
            .as_nanos()
    ));
    fs::create_dir_all(&directory).expect("create test directory");
    directory
}

fn test_app(label: &str) -> (App, PathBuf) {
    let directory = test_directory(label);
    let module_root = directory.join("module");
    fs::create_dir_all(&module_root).expect("create module root");
    (App::for_test(module_root), directory)
}

#[test]
fn full_output_preserves_trimmed_stdout_and_appends_trimmed_stderr() {
    assert_eq!(
        merge_command_output(b"  first\nsecond  \n", b"  warning\n  "),
        "first\nsecond; warning"
    );
}

#[test]
fn compact_output_keeps_the_last_nonempty_line() {
    assert_eq!(
        compact_command_output("first\n\n  final; warning  \n"),
        "final; warning"
    );
}

#[test]
fn compact_output_keeps_timeout_errors_byte_for_byte() {
    assert_eq!(
        compact_command_output("timeout after 5000ms"),
        "timeout after 5000ms"
    );
}

#[test]
fn full_and_compact_helpers_share_process_output_semantics() {
    let args = ["-c", "printf 'first\\nsecond'; printf 'warning' >&2"];
    let full = command_text_full_timeout("sh", &args, Duration::from_secs(1));
    let compact = command_text_timeout("sh", &args, Duration::from_secs(1));

    assert_eq!(
        (full, compact),
        (
            "first\nsecond; warning".to_string(),
            "second; warning".to_string()
        )
    );
}

#[test]
fn full_output_drains_more_than_pipe_capacity_without_waiting_for_timeout() {
    let script = "chunk=0123456789abcdef0123456789abcdef; i=0; while [ \"$i\" -lt 8192 ]; do printf %s \"$chunk\"; i=$((i + 1)); done";
    let started = Instant::now();
    let output = command_text_full_timeout("sh", &["-c", script], Duration::from_secs(8));

    assert_eq!(
        (output.len(), started.elapsed() < Duration::from_secs(4)),
        (32 * 8192, true)
    );
}

#[test]
fn command_output_is_drained_but_retained_within_the_memory_budget() {
    let script = "chunk=0123456789abcdef0123456789abcdef; i=0; while [ \"$i\" -lt 65536 ]; do printf %s \"$chunk\"; i=$((i + 1)); done";
    let output = command_text_full_timeout("sh", &["-c", script], Duration::from_secs(8));

    assert_eq!(
        output.len(),
        MAX_COMMAND_STREAM_BYTES + "\n[output truncated]".len()
    );
    assert!(output.ends_with("[output truncated]"));
}

#[test]
fn timeout_terminates_background_children_in_the_command_group() {
    let directory = test_directory("command-group-timeout");
    fs::create_dir_all(&directory).unwrap();
    let pid_file = directory.join("child.pid");
    let script = format!(
            "sh -c 'trap \"\" TERM; printf \"%s\\\\n\" \"$$\" > \"{}\"; while :; do sleep 1; done' & wait",
            pid_file.display()
        );
    let output = command_text_full_timeout("sh", &["-c", &script], Duration::from_millis(300));
    assert_eq!(output, "timeout after 300ms");
    let pid = fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse::<libc::pid_t>()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline && unsafe { libc::kill(pid, 0) } == 0 {
        std::thread::sleep(Duration::from_millis(20));
    }
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    if alive {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
    assert!(!alive, "background child survived command timeout: {pid}");
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn deadline_covers_pipes_held_after_the_direct_child_exits() {
    let directory = test_directory("command-inherited-pipe-timeout");
    fs::create_dir_all(&directory).unwrap();
    let pid_file = directory.join("grandchild.pid");
    let script = format!(
        "(trap '' TERM; while :; do sleep 1; done) & echo $! > '{}'; exit 0",
        pid_file.display()
    );
    let started = Instant::now();
    let output = command_text_full_timeout("sh", &["-c", &script], Duration::from_millis(200));
    assert_eq!(output, "timeout after 200ms");
    assert!(started.elapsed() < Duration::from_secs(2));
    let pid = fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse::<libc::pid_t>()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline && unsafe { libc::kill(pid, 0) } == 0 {
        thread::sleep(Duration::from_millis(20));
    }
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    if alive {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
    assert!(
        !alive,
        "pipe-holding grandchild survived command timeout: {pid}"
    );
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn builtin_infinite_loop_times_out_promptly_and_exactly() {
    let started = Instant::now();
    let output = command_text_full_timeout(
        "sh",
        &["-c", "while :; do :; done"],
        Duration::from_millis(120),
    );

    assert_eq!(
        (output, started.elapsed() < Duration::from_secs(2)),
        ("timeout after 120ms".to_string(), true)
    );
}

#[test]
fn write_secret_file_replaces_contents_and_restricts_existing_mode() {
    let (app, directory) = test_app("replace-secret");
    let relative = Path::new(".config/magicnet/secret");
    let path = app.moddir.join(relative);
    fs::create_dir_all(path.parent().expect("secret parent")).expect("create secret parent");
    fs::write(&path, "old value").expect("write existing file");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
        .expect("broaden existing file permissions");

    write_secret_file(&app, relative, "replacement value").expect("replace secret file");

    let contents = fs::read_to_string(&path).expect("read replacement contents");
    let mode = fs::metadata(&path)
        .expect("stat replacement file")
        .permissions()
        .mode()
        & 0o777;
    fs::remove_dir_all(&directory).expect("remove test directory");

    assert_eq!(contents, "replacement value");
    assert_eq!(mode, 0o600);
}

#[test]
fn write_secret_file_creates_a_new_0600_file() {
    let (app, directory) = test_app("new-secret");
    let relative = Path::new(".config/magicnet/secret");
    let path = app.moddir.join(relative);

    write_secret_file(&app, relative, "new value").expect("create secret file");

    let contents = fs::read_to_string(&path).expect("read new secret");
    let mode = fs::metadata(&path)
        .expect("stat new secret")
        .permissions()
        .mode()
        & 0o777;
    fs::remove_dir_all(&directory).expect("remove test directory");

    assert_eq!(contents, "new value");
    assert_eq!(mode, 0o600);
}

#[test]
fn write_secret_file_refuses_a_final_symlink_without_touching_its_target() {
    let (app, directory) = test_app("secret-final-symlink");
    let victim = directory.join("victim");
    let relative = Path::new(".config/magicnet/secret");
    let path = app.moddir.join(relative);
    fs::create_dir_all(path.parent().expect("secret parent")).expect("create secret parent");
    fs::write(&victim, "preserve me").expect("write victim");
    symlink(&victim, &path).expect("create secret symlink");

    write_secret_file(&app, relative, "replacement").expect_err("refuse symlink");
    let contents = fs::read_to_string(&victim).expect("read victim");
    fs::remove_dir_all(&directory).expect("remove test directory");

    assert_eq!(contents, "preserve me");
}

#[test]
#[cfg_attr(target_os = "android", ignore = "Termux SELinux forbids hard links")]
fn write_secret_file_refuses_a_hard_linked_target_without_mutating_it() {
    let (app, directory) = test_app("secret-final-hardlink");
    let original = directory.join("original");
    let relative = Path::new(".config/magicnet/secret");
    let linked = app.moddir.join(relative);
    fs::create_dir_all(linked.parent().expect("secret parent")).expect("create secret parent");
    fs::write(&original, "preserve me").expect("write original");
    fs::hard_link(&original, &linked).expect("create hard link");

    let err = write_secret_file(&app, relative, "replacement").expect_err("refuse hard link");

    assert!(err.contains("non-private"), "unexpected error: {err}");
    assert_eq!(
        fs::read_to_string(&original).expect("read original"),
        "preserve me"
    );
    fs::remove_dir_all(&directory).expect("remove test directory");
}

#[test]
#[cfg_attr(target_os = "android", ignore = "Termux SELinux forbids hard links")]
fn write_text_file_refuses_final_symlink_and_hard_link() {
    for link_kind in ["symlink", "hardlink"] {
        let (app, directory) = test_app(&format!("text-final-{link_kind}"));
        let victim = directory.join("victim");
        let relative = Path::new(".config/magicnet/text.conf");
        let path = app.moddir.join(relative);
        fs::create_dir_all(path.parent().expect("text parent")).expect("create text parent");
        fs::write(&victim, "preserve me").expect("write victim");
        match link_kind {
            "symlink" => symlink(&victim, &path).expect("create text symlink"),
            "hardlink" => fs::hard_link(&victim, &path).expect("create text hard link"),
            _ => unreachable!(),
        }

        assert!(write_text_file(&app, relative, "replacement").is_err());
        assert_eq!(fs::read_to_string(&victim).unwrap(), "preserve me");
        fs::remove_dir_all(&directory).expect("remove test directory");
    }
}

#[test]
fn module_writers_reject_intermediate_symlinks() {
    assert_intermediate_symlinks_rejected("text", write_text_file);
    assert_intermediate_symlinks_rejected("secret", write_secret_file);
}

#[test]
fn module_writers_reject_non_relative_paths() {
    let (app, directory) = test_app("relative-paths");
    for path in [
        Path::new("../escape"),
        Path::new("/escape"),
        Path::new("./escape"),
    ] {
        assert!(write_text_file(&app, path, "nope").is_err());
        assert!(write_secret_file(&app, path, "nope").is_err());
    }
    fs::remove_dir_all(&directory).expect("remove test directory");
}

#[test]
fn module_transaction_replaces_both_app_lists() {
    let (app, directory) = test_app("transaction-success");
    let (bypass, proxy) = prepare_transaction_app_lists(&app);

    replace_module_text_files_transactionally(
        &app,
        &[
            (
                Path::new(".config/magicnet/app-bypass.list"),
                "new-bypass\n",
            ),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ],
    )
    .expect("replace app lists");

    assert_eq!(fs::read_to_string(&bypass).unwrap(), "new-bypass\n");
    assert_eq!(fs::read_to_string(&proxy).unwrap(), "new-proxy\n");
    assert_no_transaction_stages(&app);
    fs::remove_dir_all(&directory).expect("remove test directory");
}

#[test]
fn module_transaction_replaces_files_across_module_directories() {
    let (app, directory) = test_app("transaction-cross-directory");
    let (bypass, _) = prepare_transaction_app_lists(&app);
    let subscription = app.moddir.join(".config/sing-box/subscription.user-agent");
    fs::create_dir_all(subscription.parent().expect("subscription parent"))
        .expect("create subscription directory");
    fs::write(&subscription, "old-agent\n").expect("write subscription fixture");

    replace_module_text_files_transactionally(
        &app,
        &[
            (
                Path::new(".config/sing-box/subscription.user-agent"),
                "new-agent\n",
            ),
            (
                Path::new(".config/magicnet/app-bypass.list"),
                "new-bypass\n",
            ),
        ],
    )
    .expect("replace files across module directories");

    assert_eq!(fs::read_to_string(&subscription).unwrap(), "new-agent\n");
    assert_eq!(fs::read_to_string(&bypass).unwrap(), "new-bypass\n");
    assert_no_transaction_stages(&app);
    fs::remove_dir_all(&directory).expect("remove test directory");
}

#[test]
fn module_transaction_rolls_back_across_directories_after_replace_failure() {
    let (app, directory) = test_app("transaction-cross-directory-rollback");
    let (bypass, proxy) = prepare_transaction_app_lists(&app);
    let subscription = app.moddir.join(".config/sing-box/subscription.user-agent");
    fs::create_dir_all(subscription.parent().expect("subscription parent"))
        .expect("create subscription directory");
    fs::write(&subscription, "old-agent\n").expect("write subscription fixture");
    let mut replace_count = 0usize;

    let error = replace_module_text_files_transactionally_with_rename(
        &app,
        &[
            (
                Path::new(".config/sing-box/subscription.user-agent"),
                "new-agent\n",
            ),
            (
                Path::new(".config/magicnet/app-bypass.list"),
                "new-bypass\n",
            ),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ],
        |operation, source_directory, source, destination_directory, destination| {
            replace_count += 1;
            if replace_count == 3 {
                Err("injected cross-directory replace failure".to_string())
            } else {
                rename_module_transaction_entry(
                    operation,
                    source_directory,
                    source,
                    destination_directory,
                    destination,
                )
            }
        },
    )
    .expect_err("third replacement must fail");

    assert!(
        error.contains("injected cross-directory replace failure"),
        "{error}"
    );
    assert_eq!(fs::read_to_string(&subscription).unwrap(), "old-agent\n");
    assert_eq!(fs::read_to_string(&bypass).unwrap(), "old-bypass\n");
    assert_eq!(fs::read_to_string(&proxy).unwrap(), "old-proxy\n");
    assert_no_transaction_stages(&app);
    fs::remove_dir_all(&directory).expect("remove test directory");
}

#[test]
fn module_transaction_rolls_back_three_files_after_injected_third_replace_failure() {
    let (app, directory) = test_app("transaction-rollback");
    let (bypass, proxy) = prepare_transaction_app_lists(&app);
    let direct = bypass
        .parent()
        .expect("app list directory")
        .join("app-direct.list");
    fs::write(&direct, "old-direct\n").expect("write direct fixture");
    let mut replace_count = 0usize;

    let error = replace_module_text_files_transactionally_with_rename(
        &app,
        &[
            (
                Path::new(".config/magicnet/app-bypass.list"),
                "new-bypass\n",
            ),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
            (
                Path::new(".config/magicnet/app-direct.list"),
                "new-direct\n",
            ),
        ],
        |operation, source_directory, source, destination_directory, destination| {
            replace_count += 1;
            if replace_count == 3 {
                Err("injected third replace failure".to_string())
            } else {
                rename_module_transaction_entry(
                    operation,
                    source_directory,
                    source,
                    destination_directory,
                    destination,
                )
            }
        },
    )
    .expect_err("third replacement must fail");

    assert!(error.contains("injected third replace failure"), "{error}");
    assert_eq!(fs::read_to_string(&bypass).unwrap(), "old-bypass\n");
    assert_eq!(fs::read_to_string(&proxy).unwrap(), "old-proxy\n");
    assert_eq!(fs::read_to_string(&direct).unwrap(), "old-direct\n");
    assert_no_transaction_stages(&app);
    fs::remove_dir_all(&directory).expect("remove test directory");
}

#[test]
fn module_transaction_cleans_private_stage_after_injected_write_or_sync_failure() {
    let (write_app, write_directory) = test_app("transaction-stage-write-failure");
    let (write_bypass, write_proxy) = prepare_transaction_app_lists(&write_app);
    let write_error = replace_module_text_files_transactionally_with_stage_writer(
        &write_app,
        &[
            (
                Path::new(".config/magicnet/app-bypass.list"),
                "new-bypass\n",
            ),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ],
        |_file, _contents| Err("injected stage write failure".to_string()),
    )
    .expect_err("stage write failure must abort the transaction");
    assert!(
        write_error.contains("injected stage write failure"),
        "{write_error}"
    );
    assert_eq!(fs::read_to_string(&write_bypass).unwrap(), "old-bypass\n");
    assert_eq!(fs::read_to_string(&write_proxy).unwrap(), "old-proxy\n");
    assert_no_transaction_stages(&write_app);
    fs::remove_dir_all(&write_directory).expect("remove write-failure test directory");

    let (sync_app, sync_directory) = test_app("transaction-stage-sync-failure");
    let (sync_bypass, sync_proxy) = prepare_transaction_app_lists(&sync_app);
    let sync_error = replace_module_text_files_transactionally_with_stage_writer(
        &sync_app,
        &[
            (
                Path::new(".config/magicnet/app-bypass.list"),
                "new-bypass\n",
            ),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ],
        |file, contents| {
            file.write_all(contents)
                .expect("write private stage before injected sync failure");
            Err("injected stage sync failure".to_string())
        },
    )
    .expect_err("stage sync failure must abort the transaction");
    assert!(
        sync_error.contains("injected stage sync failure"),
        "{sync_error}"
    );
    assert_eq!(fs::read_to_string(&sync_bypass).unwrap(), "old-bypass\n");
    assert_eq!(fs::read_to_string(&sync_proxy).unwrap(), "old-proxy\n");
    assert_no_transaction_stages(&sync_app);
    fs::remove_dir_all(&sync_directory).expect("remove sync-failure test directory");
}

#[test]
fn module_transaction_stages_are_isolated_from_target_directory() {
    let (app, directory) = test_app("transaction-stage-isolation");
    let (bypass, proxy) = prepare_transaction_app_lists(&app);
    let config = bypass.parent().expect("app list directory");
    let victim = directory.join("victim");
    let stage_name = module_transaction_stage_name(1);
    let target_directory_entry = config.join(Path::new(stage_name.as_os_str()));
    fs::write(&victim, "preserve me").expect("write victim");
    symlink(&victim, &target_directory_entry).expect("create target-directory stage symlink");

    replace_module_text_files_transactionally(
        &app,
        &[
            (
                Path::new(".config/magicnet/app-bypass.list"),
                "new-bypass\n",
            ),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ],
    )
    .expect("target-directory entry must not be a transaction stage source");

    assert_eq!(fs::read_to_string(&victim).unwrap(), "preserve me");
    assert_eq!(fs::read_to_string(&bypass).unwrap(), "new-bypass\n");
    assert_eq!(fs::read_to_string(&proxy).unwrap(), "new-proxy\n");
    assert!(fs::symlink_metadata(&target_directory_entry)
        .unwrap()
        .file_type()
        .is_symlink());
    let mode = fs::metadata(transaction_staging_directory(&app))
        .expect("stat private staging directory")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o700);
    assert_no_transaction_stages(&app);
    fs::remove_dir_all(&directory).expect("remove test directory");
}

#[test]
fn module_transaction_rejects_a_private_stage_collision_without_touching_its_target() {
    let (app, directory) = test_app("transaction-private-stage-collision");
    let (bypass, proxy) = prepare_transaction_app_lists(&app);
    let victim = directory.join("victim");
    let staging_directory = transaction_staging_directory(&app);
    let stage_name = module_transaction_stage_name(1);
    let stage = staging_directory.join(Path::new(stage_name.as_os_str()));
    fs::create_dir_all(&staging_directory).expect("create private staging fixture");
    fs::set_permissions(&staging_directory, fs::Permissions::from_mode(0o700))
        .expect("secure private staging fixture");
    fs::write(&victim, "preserve me").expect("write victim");
    symlink(&victim, &stage).expect("create private stage symlink");

    assert!(replace_module_text_files_transactionally(
        &app,
        &[
            (
                Path::new(".config/magicnet/app-bypass.list"),
                "new-bypass\n"
            ),
            (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
        ]
    )
    .is_err());
    assert_eq!(fs::read_to_string(&victim).unwrap(), "preserve me");
    assert_eq!(fs::read_to_string(&bypass).unwrap(), "old-bypass\n");
    assert_eq!(fs::read_to_string(&proxy).unwrap(), "old-proxy\n");
    assert!(fs::symlink_metadata(&stage)
        .unwrap()
        .file_type()
        .is_symlink());
    fs::remove_dir_all(&directory).expect("remove test directory");
}

#[test]
fn module_transaction_rejects_intermediate_symlinks_without_writing_outside() {
    for (case, linked_directory) in [("config", ".config"), ("magicnet", ".config/magicnet")] {
        let directory = test_directory(&format!("transaction-intermediate-{case}"));
        let module_root = directory.join("module");
        let outside = directory.join("outside");
        fs::create_dir_all(&module_root).expect("create module root");
        fs::create_dir_all(&outside).expect("create outside directory");
        let linked_directory = module_root.join(linked_directory);
        if let Some(parent) = linked_directory.parent() {
            fs::create_dir_all(parent).expect("create symlink parent");
        }
        symlink(&outside, &linked_directory).expect("create intermediate symlink");
        let app = App::for_test(module_root);

        assert!(replace_module_text_files_transactionally(
            &app,
            &[
                (
                    Path::new(".config/magicnet/app-bypass.list"),
                    "new-bypass\n"
                ),
                (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
            ]
        )
        .is_err());
        assert!(fs::read_dir(&outside).unwrap().next().is_none());
        fs::remove_dir_all(&directory).expect("remove test directory");
    }
}

#[test]
#[cfg_attr(target_os = "android", ignore = "Termux SELinux forbids hard links")]
fn module_transaction_rejects_final_symlink_and_hard_link() {
    for link_kind in ["symlink", "hardlink"] {
        let (app, directory) = test_app(&format!("transaction-final-{link_kind}"));
        let (bypass, _) = prepare_transaction_app_lists(&app);
        let victim = directory.join("victim");
        fs::remove_file(&bypass).expect("remove fixture bypass list");
        fs::write(&victim, "preserve me").expect("write victim");
        match link_kind {
            "symlink" => symlink(&victim, &bypass).expect("create final symlink"),
            "hardlink" => fs::hard_link(&victim, &bypass).expect("create final hard link"),
            _ => unreachable!(),
        }

        assert!(replace_module_text_files_transactionally(
            &app,
            &[
                (
                    Path::new(".config/magicnet/app-bypass.list"),
                    "new-bypass\n"
                ),
                (Path::new(".config/magicnet/app-proxy.list"), "new-proxy\n"),
            ]
        )
        .is_err());
        assert_eq!(fs::read_to_string(&victim).unwrap(), "preserve me");
        fs::remove_dir_all(&directory).expect("remove test directory");
    }
}

fn prepare_transaction_app_lists(app: &App) -> (PathBuf, PathBuf) {
    let config = app.moddir.join(".config/magicnet");
    let bypass = config.join("app-bypass.list");
    let proxy = config.join("app-proxy.list");
    fs::create_dir_all(&config).expect("create app list directory");
    fs::write(&bypass, "old-bypass\n").expect("write bypass fixture");
    fs::write(&proxy, "old-proxy\n").expect("write proxy fixture");
    (bypass, proxy)
}

fn transaction_staging_directory(app: &App) -> PathBuf {
    app.moddir
        .join(MODULE_TRANSACTION_STAGING_PARENT)
        .join(MODULE_TRANSACTION_STAGING_DIRECTORY)
}

fn assert_no_transaction_stages(app: &App) {
    let staging_directory = transaction_staging_directory(app);
    assert!(
        staging_directory.is_dir(),
        "private staging directory was not created"
    );
    assert!(
        fs::read_dir(&staging_directory)
            .expect("read private staging directory")
            .next()
            .is_none(),
        "private staging directory still contains transaction entries"
    );
}

fn assert_intermediate_symlinks_rejected(
    writer_name: &str,
    writer: fn(&App, &Path, &str) -> Result<(), String>,
) {
    for (case, relative, linked_directory) in [
        ("config", ".config/magicnet/value", ".config"),
        ("magicnet", ".config/magicnet/value", ".config/magicnet"),
        ("sing-box", ".config/sing-box/value", ".config/sing-box"),
    ] {
        let directory = test_directory(&format!("intermediate-{writer_name}-{case}"));
        let module_root = directory.join("module");
        let outside = directory.join("outside");
        fs::create_dir_all(&module_root).expect("create module root");
        fs::create_dir_all(&outside).expect("create outside directory");
        let linked_directory = module_root.join(linked_directory);
        if let Some(parent) = linked_directory.parent() {
            fs::create_dir_all(parent).expect("create symlink parent");
        }
        symlink(&outside, &linked_directory).expect("create intermediate symlink");
        let app = App::for_test(module_root);

        assert!(writer(&app, Path::new(relative), "replacement").is_err());
        assert!(
            fs::read_dir(&outside)
                .expect("read outside directory")
                .next()
                .is_none(),
            "{writer_name} writer followed {linked_directory:?}"
        );
        fs::remove_dir_all(&directory).expect("remove test directory");
    }
}
