// Unit tests included from the matching src module.

#[test]
fn rss_requires_valid_kib_field() {
    assert_eq!(
        super::parse_rss_kib("Name: sing-box\nVmRSS:\t131072 kB\n"),
        Some(131072)
    );
    for input in [
        "",
        "VmSize: 100 kB",
        "VmRSS: -1 kB",
        "VmRSS: 20 MB",
        "VmRSS: unknown kB",
    ] {
        assert_eq!(super::parse_rss_kib(input), None);
    }
    assert_eq!(super::singbox_rss_kib("stopped"), None);
    assert_eq!(super::singbox_rss_kib("unknown"), None);
}

use super::{
    api_host_port, config_apply_lock, config_apply_lock_bounded, normalize_transparent_mode,
    prepare_network_for_stop_command, prepare_transparent_transaction, read_transparent_mode,
    restart_command, restore_network_after_failed_stop_command, rollback_transparent_preflight,
    safe_log_name, service_log_path, singbox_webui, supervisor_cmdline_matches,
    transparent_transaction_active, REPAIR_COMMAND, START_KERNEL_COMMAND, TRANSPARENT_CAPABILITY,
    TRANSPARENT_CONFIG, TRANSPARENT_MODE_CONF, TRANSPARENT_PROBE_REPORT,
    TRANSPARENT_SHARED_INTERFACES, TRANSPARENT_SHARED_PENDING, TRANSPARENT_TRANSACTION,
};
use crate::App;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn fixture_app(name: &str) -> (App, PathBuf) {
    let root = std::env::temp_dir().join(format!("magicnet-service-{name}-{}", std::process::id()));
    let log_dir = root.join(".log");
    fs::create_dir_all(&log_dir).unwrap();
    let app = App {
        moddir: root.clone(),
        api: String::new(),
        log_dir,
    };
    (app, root)
}

#[test]
fn transparent_mode_only_accepts_tun_or_ebpf() {
    assert_eq!(normalize_transparent_mode("tun").unwrap(), "tun");
    assert_eq!(normalize_transparent_mode("ebpf").unwrap(), "ebpf");
    assert!(normalize_transparent_mode("proxy").is_err());
    assert!(normalize_transparent_mode("external").is_err());
    assert!(normalize_transparent_mode("external-tun").is_err());
    assert!(normalize_transparent_mode("hybrid").is_err());
    assert!(normalize_transparent_mode("tproxy").is_err());
}

#[test]
fn transparent_mode_file_is_strict_and_missing_defaults_to_tun() {
    let (app, root) = fixture_app("transparent-mode");
    let mode_path = root.join(TRANSPARENT_MODE_CONF);
    fs::create_dir_all(mode_path.parent().unwrap()).unwrap();

    let missing = read_transparent_mode(&app).unwrap();
    assert_eq!(missing.mode, "tun");
    assert!(!missing.file_present);

    fs::write(
        &mode_path,
        "# explicit selection\nMAGICNET_TRANSPARENT_MODE=ebpf\n",
    )
    .unwrap();
    let ebpf = read_transparent_mode(&app).unwrap();
    assert_eq!(ebpf.mode, "ebpf");
    assert!(ebpf.file_present);

    fs::write(
        &mode_path,
        "MAGICNET_TRANSPARENT_MODE=tun\nMAGICNET_UNEXPECTED_ASSIGNMENT=1\n",
    )
    .unwrap();
    assert!(read_transparent_mode(&app).is_err());

    fs::write(
        &mode_path,
        "MAGICNET_TRANSPARENT_MODE=tun\nMAGICNET_TRANSPARENT_MODE=ebpf\n",
    )
    .unwrap();
    assert!(read_transparent_mode(&app).is_err());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn transparent_preflight_rollback_restores_ebpf_runtime_state() {
    let (app, root) = fixture_app("transparent-state-rollback");
    let mode_path = root.join(TRANSPARENT_MODE_CONF);
    let config_path = root.join(TRANSPARENT_CONFIG);
    fs::create_dir_all(mode_path.parent().unwrap()).unwrap();
    fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    fs::write(&mode_path, "MAGICNET_TRANSPARENT_MODE=ebpf\n").unwrap();
    fs::write(&config_path, b"old-ebpf-config\n").unwrap();

    let old_state = [
        (TRANSPARENT_CAPABILITY, b"ok\n".as_slice()),
        (
            TRANSPARENT_PROBE_REPORT,
            br#"{"active_programs":[{"name":"sb_ebpf_conn4"}]}"#.as_slice(),
        ),
        (TRANSPARENT_SHARED_INTERFACES, b"wlan2\n".as_slice()),
    ];
    for (path, contents) in old_state {
        let path = root.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    let old_mode = read_transparent_mode(&app).unwrap();
    prepare_transparent_transaction(&app, &old_mode, "tun").unwrap();

    fs::write(&mode_path, "MAGICNET_TRANSPARENT_MODE=tun\n").unwrap();
    fs::write(&config_path, b"candidate-tun-config\n").unwrap();
    fs::remove_file(root.join(TRANSPARENT_CAPABILITY)).unwrap();
    fs::remove_file(root.join(TRANSPARENT_PROBE_REPORT)).unwrap();
    fs::write(root.join(TRANSPARENT_SHARED_PENDING), b"candidate\n").unwrap();
    fs::write(root.join(TRANSPARENT_SHARED_INTERFACES), b"").unwrap();

    rollback_transparent_preflight(&app, &old_mode).unwrap();

    assert_eq!(
        fs::read_to_string(&mode_path).unwrap(),
        "MAGICNET_TRANSPARENT_MODE=ebpf\n"
    );
    assert_eq!(fs::read(&config_path).unwrap(), b"old-ebpf-config\n");
    for (path, contents) in old_state {
        assert_eq!(fs::read(root.join(path)).unwrap(), contents);
    }
    assert!(!root.join(TRANSPARENT_SHARED_PENDING).exists());
    assert!(!root.join(TRANSPARENT_TRANSACTION).exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn lifecycle_commands_detach_optional_supervisors_after_core_start() {
    assert!(START_KERNEL_COMMAND.contains("MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2"));
    assert!(START_KERNEL_COMMAND.contains("magicnet_start_kernel"));
    assert!(START_KERNEL_COMMAND.contains("magicnet_supervisors_start_detached"));
    for target in ["sing-box", "singbox"] {
        let command = restart_command(target);
        assert!(command.contains("MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2"));
        assert!(command.contains("magicnet_start_kernel"));
        assert!(command.contains("magicnet_supervisors_start_detached"));
        assert!(!command.contains("supervisor start all >/dev/null"));
    }
}

#[test]
fn config_apply_detects_a_journaled_transparent_transition() {
    let (app, root) = fixture_app("transparent-apply-gate");
    fs::create_dir_all(root.join(TRANSPARENT_TRANSACTION)).unwrap();
    assert!(transparent_transaction_active(&app));
    fs::remove_dir_all(root.join(TRANSPARENT_TRANSACTION)).unwrap();
    assert!(!transparent_transaction_active(&app));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn stop_prepares_network_before_terminating_the_core() {
    assert_eq!(
        prepare_network_for_stop_command(),
        "magicnet_prepare_network_for_core_stop"
    );
    assert_eq!(
        restore_network_after_failed_stop_command(),
        "magicnet_after_kernel_start_unlocked"
    );
}

#[test]
fn repair_explicitly_opts_into_disruptive_recovery() {
    assert!(REPAIR_COMMAND.contains("MAGICNET_ALLOW_DISRUPTIVE_RECOVERY=1"));
    assert!(REPAIR_COMMAND.contains("magicnet_ensure_kernel"));
}

#[test]
fn config_apply_lock_is_exclusive_and_releases_on_drop() {
    let (app, root) = fixture_app("config-apply-lock");
    let lock_path = root.join(".state/config-apply.lock");
    let guard = config_apply_lock(&app).expect("create config apply lock");
    let probe = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&lock_path)
        .expect("open config apply lock probe");
    assert_eq!(
        unsafe {
            libc::flock(
                std::os::fd::AsRawFd::as_raw_fd(&probe),
                libc::LOCK_EX | libc::LOCK_NB,
            )
        },
        -1,
        "a second config apply must not enter while the first owns the lock"
    );
    drop(probe);
    let started = Instant::now();
    let error = config_apply_lock_bounded(&app, Duration::from_millis(30))
        .err()
        .expect("bounded lifecycle lock must not wait behind config apply forever");
    assert!(error.contains("config apply is still busy"));
    assert!(started.elapsed() < Duration::from_secs(1));
    drop(guard);
    let reacquired = config_apply_lock(&app).expect("reacquire config apply lock");
    drop(reacquired);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn service_log_targets_reject_path_traversal() {
    assert!(!safe_log_name("../../etc/passwd"));
    assert!(!safe_log_name("../outside.log"));
    assert!(!safe_log_name("nested/outside.log"));
    assert!(safe_log_name("custom.log"));
    assert!(safe_log_name("custom-name_2.log"));
}

#[test]
fn service_log_path_rejects_symlink_escape() {
    let (app, root) = fixture_app("symlink");
    let outside = root.join("outside.log");
    fs::write(&outside, "do not expose\n").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&outside, app.log_dir.join("custom.log")).unwrap();
    #[cfg(unix)]
    assert!(service_log_path(&app, "custom").is_err());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn service_log_path_selects_latest_webui_task_log() {
    let (app, root) = fixture_app("latest-webui");
    let older = app.log_dir.join("webui-start-old.log");
    let newer = app.log_dir.join("webui-start-new.log");
    fs::write(&older, "older\n").unwrap();
    std::thread::sleep(Duration::from_millis(20));
    fs::write(&newer, "newer\n").unwrap();
    fs::write(app.log_dir.join("service.log"), "unrelated\n").unwrap();

    assert_eq!(
        service_log_path(&app, "webui").unwrap(),
        fs::canonicalize(&newer).unwrap()
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn service_log_path_reports_missing_webui_task_log() {
    let (app, root) = fixture_app("missing-webui");
    let error = service_log_path(&app, "webui").unwrap_err();
    assert!(error.starts_with("log file unavailable:"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn webui_setup_uses_the_configured_api_endpoint() {
    assert_eq!(
        api_host_port("http://127.0.0.1:19090"),
        Some(("127.0.0.1".to_string(), "19090".to_string()))
    );
    assert_eq!(
        api_host_port("http://[::1]:19090"),
        Some(("::1".to_string(), "19090".to_string()))
    );
    for invalid in [
        "invalid",
        "http://127.0.0.1:0",
        "http://192.0.2.1:1234",
        "http://[::1]:bad",
    ] {
        assert_eq!(api_host_port(invalid), None);
    }

    let (mut app, root) = fixture_app("webui-route");
    app.api = "http://127.0.0.1:19090".to_string();
    assert_eq!(
        singbox_webui(&app),
        "http://127.0.0.1:19090/ui/#/setup?hostname=127.0.0.1&port=19090"
    );
    app.api = "invalid".to_string();
    assert!(singbox_webui(&app).is_empty());
    let _ = fs::remove_dir_all(root);
}

fn argv(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[test]
fn supervisor_pidfiles_require_the_matching_module_command() {
    let module = PathBuf::from("/data/adb/modules/MagicNet");
    let kernel = module.join(".state/watchdog/magicnet-kernel.pid");
    let fswatch = module.join(".state/fswatch/magicnet-config.pid");
    let hotspot = module.join(".state/watchdog/magicnet-hotspot-route.pid");
    assert!(supervisor_cmdline_matches(
        &module,
        &kernel,
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/MagicNet/.state/watchdog/magicnet-kernel.loop.sh",
        ])
    ));
    assert!(supervisor_cmdline_matches(
        &module,
        &fswatch,
        &argv(&["/data/adb/modules/MagicNet/cli", "config", "apply"])
    ));
    assert!(supervisor_cmdline_matches(
        &module,
        &hotspot,
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/MagicNet/.state/watchdog/magicnet-hotspot-route.loop.sh",
        ])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        &fswatch,
        &argv(&[
            "/system/bin/sh",
            "/data/adb/modules/Other/.state/fswatch/magicnet-config.loop.sh",
        ])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        &kernel,
        &argv(&[
            "sleep",
            "600",
            "/data/adb/modules/MagicNet/.state/watchdog/magicnet-kernel.loop.sh",
        ])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        &fswatch,
        &argv(&["/data/adb/modules/MagicNet/cli config apply"])
    ));
    assert!(!supervisor_cmdline_matches(
        &module,
        &module.join(".state/unknown-supervisor.pid"),
        &argv(&["/data/adb/modules/MagicNet/cli", "config", "apply"])
    ));
}

#[test]
fn supervisor_stop_escalates_only_after_confirmed_survival_and_verifies_exit() {
    use std::cell::Cell;
    let killed = Cell::new(false);
    let mut signals = Vec::new();
    super::stop_supervisor_with(
        || Ok(!killed.get()),
        |force| {
            signals.push(force);
            killed.set(force);
            Ok(())
        },
        Duration::ZERO,
        Duration::ZERO,
        Duration::ZERO,
    )
    .unwrap();
    assert_eq!(signals, vec![false, true]);

    for observations in [vec![true, false], vec![true, true, false]] {
        let mut observations = observations.into_iter();
        let mut signals = Vec::new();
        super::stop_supervisor_with(
            || {
                Ok(observations
                    .next()
                    .expect("unexpected observation after exit"))
            },
            |force| {
                signals.push(force);
                Ok(())
            },
            Duration::ZERO,
            Duration::ZERO,
            Duration::ZERO,
        )
        .unwrap();
        assert_eq!(
            signals,
            vec![false],
            "a confirmed exit must never receive KILL"
        );
    }
}

#[test]
fn supervisor_stop_unknown_or_replacement_never_receives_kill() {
    for error in [
        "ownership unknown",
        "PID marker changed",
        "process generation changed",
        "argv changed",
    ] {
        for successful_observations in 0..=2 {
            let mut observations = 0;
            let mut signals = Vec::new();
            let result = super::stop_supervisor_with(
                || {
                    observations += 1;
                    if observations > successful_observations {
                        Err(error.to_string())
                    } else {
                        Ok(true)
                    }
                },
                |force| {
                    signals.push(force);
                    Ok(())
                },
                Duration::ZERO,
                Duration::ZERO,
                Duration::ZERO,
            );
            assert_eq!(result.unwrap_err(), error);
            assert_eq!(
                signals,
                if successful_observations == 0 {
                    vec![]
                } else {
                    vec![false]
                }
            );
        }
    }
}

#[test]
fn supervisor_stop_retains_failed_signals_and_failed_exit() {
    for failed_force in [false, true] {
        let mut signals = Vec::new();
        let result = super::stop_supervisor_with(
            || Ok(true),
            |force| {
                signals.push(force);
                if force == failed_force {
                    Err("signal denied".to_string())
                } else {
                    Ok(())
                }
            },
            Duration::ZERO,
            Duration::ZERO,
            Duration::ZERO,
        );
        assert_eq!(result.unwrap_err(), "signal denied");
        assert_eq!(
            signals,
            if failed_force {
                vec![false, true]
            } else {
                vec![false]
            }
        );
    }
    let mut signals = Vec::new();
    let result = super::stop_supervisor_with(
        || Ok(true),
        |force| {
            signals.push(force);
            Ok(())
        },
        Duration::ZERO,
        Duration::ZERO,
        Duration::ZERO,
    );
    assert_eq!(
        result.unwrap_err(),
        "managed supervisor did not stop after SIGKILL"
    );
    assert_eq!(signals, vec![false, true]);
}

#[test]
fn supervisor_pidfile_unlink_failure_preserves_evidence_and_returns_error() {
    use std::os::unix::fs::PermissionsExt;
    if unsafe { libc::geteuid() } == 0 {
        // Root bypasses directory write permissions. The nonregular and
        // marker-generation cases still verify fail-closed cleanup there.
        return;
    }
    let (app, root) = fixture_app("watcher-unlink-failure");
    let path = app.moddir.join(".state/fswatch/magicnet-config.pid");
    let parent = path.parent().unwrap();
    fs::create_dir_all(parent).unwrap();
    fs::write(&path, "2147483647\n").unwrap();
    let marker = crate::process::read_pidfile_identity(&path)
        .unwrap()
        .unwrap();
    fs::set_permissions(parent, fs::Permissions::from_mode(0o500)).unwrap();
    let result = super::remove_supervisor_pidfile_if_unchanged(&path, marker);
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(
        result.unwrap_err(),
        "unable to remove stopped supervisor PID file"
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), "2147483647\n");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn supervisor_invalid_signal_targets_are_rejected_without_signaling() {
    for pid in [0, libc::pid_t::MAX as u32 + 1, u32::MAX] {
        assert!(crate::process::pin_supervisor_process(pid).is_none());
        for force in [false, true] {
            assert_eq!(
                crate::process::signal_supervisor_process(pid, None, force)
                    .unwrap_err()
                    .kind(),
                std::io::ErrorKind::InvalidInput
            );
        }
    }
}

struct OwnedSupervisorChild(std::process::Child);

impl Drop for OwnedSupervisorChild {
    fn drop(&mut self) {
        // Every fixture starts its own session. Clean its external sleep too.
        unsafe {
            libc::kill(-(self.0.id() as libc::pid_t), libc::SIGKILL);
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn spawn_supervisor_fixture(app: &App, ignore_term: bool) -> (OwnedSupervisorChild, PathBuf) {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    let directory = app.moddir.join(".state/fswatch");
    fs::create_dir_all(&directory).unwrap();
    let script = directory.join("magicnet-config.loop.sh");
    let ready = app.moddir.join("ready");
    fs::write(
        &script,
        format!(
            "trap '' HUP\n{}printf ready >'{}'\nwhile :; do /bin/sleep 15; done\n",
            if ignore_term { "trap '' TERM\n" } else { "" },
            ready.display()
        ),
    )
    .unwrap();
    let mut command = Command::new("/bin/sh");
    command
        .arg(&script)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let child = OwnedSupervisorChild(command.spawn().unwrap());
    let deadline = Instant::now() + Duration::from_secs(2);
    while !ready.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(ready.exists(), "fixture supervisor failed to start");
    let marker = directory.join("magicnet-config.pid");
    fs::write(&marker, format!("{}\n", child.0.id())).unwrap();
    (child, marker)
}

#[test]
fn supervisor_stop_terminates_cooperative_and_term_ignoring_watchers() {
    use std::os::unix::process::ExitStatusExt;
    for ignore_term in [false, true] {
        let (app, root) = fixture_app(if ignore_term {
            "watcher-kill"
        } else {
            "watcher-term"
        });
        let (mut child, marker) = spawn_supervisor_fixture(&app, ignore_term);
        let started = Instant::now();
        super::stop_supervisor_pidfile(&app, marker.clone()).unwrap();
        assert!(!marker.exists());
        assert_eq!(
            child.0.wait().unwrap().signal(),
            Some(if ignore_term {
                libc::SIGKILL
            } else {
                libc::SIGTERM
            })
        );
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "stop exceeded bounded TERM/KILL grace"
        );
        drop(child);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn supervisor_stop_preserves_a_foreign_process_and_cleans_its_unchanged_stale_marker() {
    use std::os::unix::process::CommandExt;
    let (app, root) = fixture_app("foreign-watcher");
    let marker = root.join(".state/fswatch/magicnet-config.pid");
    fs::create_dir_all(marker.parent().unwrap()).unwrap();
    let mut command = std::process::Command::new("/bin/sleep");
    command.arg("30");
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let mut child = OwnedSupervisorChild(command.spawn().unwrap());
    fs::write(&marker, child.0.id().to_string()).unwrap();
    super::stop_supervisor_pidfile(&app, marker.clone()).unwrap();
    assert!(!marker.exists());
    assert!(
        child.0.try_wait().unwrap().is_none(),
        "foreign process was signaled"
    );
    drop(child);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn supervisor_generation_and_marker_changes_block_signals_and_cleanup() {
    let (app, root) = fixture_app("watcher-generation");
    let (mut child, path) = spawn_supervisor_fixture(&app, true);
    let marker = crate::process::read_pidfile_identity(&path)
        .unwrap()
        .unwrap();
    let identity = crate::process::live_process_identity(marker.pid)
        .unwrap()
        .unwrap();
    let mut reused = identity.clone();
    reused.starttime = reused.starttime.saturating_add(1);
    assert!(
        super::supervisor_generation_is_live(&app, &path, marker, &reused)
            .unwrap_err()
            .contains("generation changed")
    );
    let mut foreign = identity.clone();
    foreign.argv = argv(&["/bin/sleep", "30"]);
    assert!(
        super::supervisor_generation_is_live(&app, &path, marker, &foreign)
            .unwrap_err()
            .contains("ownership changed")
    );

    let replacement = path.with_extension("replacement");
    fs::write(&replacement, marker.pid.to_string()).unwrap();
    fs::rename(&replacement, &path).unwrap();
    assert!(
        super::supervisor_generation_is_live(&app, &path, marker, &identity)
            .unwrap_err()
            .contains("PID file changed")
    );
    assert!(super::remove_supervisor_pidfile_if_unchanged(&path, marker).is_err());
    assert!(path.exists(), "same-PID replacement marker must survive");
    fs::remove_file(&path).unwrap();
    assert!(
        super::supervisor_generation_is_live(&app, &path, marker, &identity).is_err(),
        "missing marker is not evidence of exit"
    );
    assert!(child.0.try_wait().unwrap().is_none());
    drop(child);
    fs::remove_dir_all(root).unwrap();
}

#[test]
#[ignore = "requires a separately built AOSP Android-profile mksh and generated watcher fixture"]
fn android_mksh_external_sleep_watcher_stops_before_the_sleep_finishes() {
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::process::{Command, Stdio};
    let shell =
        std::env::var_os("MAGICNET_TEST_MKSH").expect("AOSP Android-profile mksh fixture required");
    let root = PathBuf::from(
        std::env::var_os("MAGICNET_TEST_MKSH_MODULE").expect("generated watcher fixture required"),
    );
    let app = App {
        moddir: root.clone(),
        log_dir: root.join(".log"),
        api: String::new(),
    };
    let marker = root.join(".state/fswatch/magicnet-config.pid");
    let script = root.join(".state/fswatch/magicnet-config.loop.sh");
    let mut command = Command::new(shell);
    command
        .arg(&script)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let mut child = OwnedSupervisorChild(command.spawn().unwrap());
    let deadline = Instant::now() + Duration::from_secs(3);
    let children = PathBuf::from(format!(
        "/proc/{}/task/{}/children",
        child.0.id(),
        child.0.id()
    ));
    let mut sleeping = false;
    while Instant::now() < deadline {
        if let Ok(pids) = fs::read_to_string(&children) {
            sleeping = pids.split_whitespace().any(|pid| {
                fs::read(format!("/proc/{pid}/cmdline"))
                    .is_ok_and(|argv| argv.starts_with(b"sleep\0"))
            });
            if sleeping {
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        sleeping,
        "generated watcher did not enter its external sleep"
    );
    fs::write(&marker, child.0.id().to_string()).unwrap();
    let started = Instant::now();
    let result = super::stop_supervisor_pidfile(&app, marker.clone());
    eprintln!(
        "Android-profile mksh watcher stop: {result:?}; elapsed={:?}",
        started.elapsed()
    );
    assert!(
        result.is_ok(),
        "normal Android watcher could not stop: {result:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(!marker.exists());
    assert_eq!(child.0.wait().unwrap().signal(), Some(libc::SIGKILL));
}
