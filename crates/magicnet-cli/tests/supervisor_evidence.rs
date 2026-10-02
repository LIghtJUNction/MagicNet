#![cfg(target_os = "linux")]

use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

const FSWATCH_PID: &str = ".state/fswatch/magicnet-config.pid";
const KERNEL_PID: &str = ".state/watchdog/magicnet-kernel.pid";

#[test]
fn enabled_mcp_does_not_project_unknown_pid_evidence_as_stopped() {
    let fixture = Fixture::new();
    fixture.write(".config/magicnet/mcp.conf", "MAGICNET_MCP_ENABLED=1\n");
    fixture.write(".state/magicnet-mcp.pid", "invalid\n");
    fixture.canonical("fswatch");
    let state = fs::read_to_string(fixture.path(".state/machines/mcp.state")).unwrap();
    assert!(state.contains("process=unknown\n"), "{state}");
    assert!(state.contains("state=unknown\n"), "{state}");
}

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let fixture = Self(std::env::temp_dir().join(format!(
            "magicnet-supervisor-evidence-{}-{nonce}",
            std::process::id()
        )));
        fixture.write(FSWATCH_PID, "");
        fixture.write(KERNEL_PID, "");
        fs::remove_file(fixture.path(FSWATCH_PID)).unwrap();
        fs::remove_file(fixture.path(KERNEL_PID)).unwrap();
        fixture.script("bin/pidof", "#!/bin/sh\nexit 1\n");
        fixture.write("lib/kamfw/.kamfwrc", "import() { :; }\n");
        fixture.write(
            "lib/magicnet.sh",
            "magicnet_prepare_network_for_core_stop() { printf prepare > \"$MODDIR/cleanup-entered\"; }\n\
             magicnet_lifecycle_after_stop() { printf final > \"$MODDIR/cleanup-finished\"; }\n\
             magicnet_supervisors_start_detached() { :; }\n",
        );
        fixture
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.0.join(relative)
    }

    fn write(&self, relative: &str, contents: &str) {
        let path = self.path(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    fn script(&self, relative: &str, contents: &str) {
        self.write(relative, contents);
        fs::set_permissions(self.path(relative), fs::Permissions::from_mode(0o700)).unwrap();
    }

    fn run(&self, args: &[&str]) -> Output {
        // The override lets this same regression suite exercise a preserved
        // pre-fix binary without introducing a production environment hook.
        let cli = std::env::var_os("MAGICNET_SUPERVISOR_TEST_CLI")
            .unwrap_or_else(|| env!("CARGO_BIN_EXE_magicnet-cli").into());
        let mut child = Process(
            Command::new(cli)
                .env("MODDIR", &self.0)
                .env("MAGICNET_API", "http://127.0.0.1:1")
                .env("MAGICNET_COMMAND_TIMEOUT", "3")
                .env(
                    "PATH",
                    format!("{}:/usr/bin:/bin", self.path("bin").display()),
                )
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            if child.0.try_wait().unwrap().is_some() {
                let stdout = child.0.stdout.take().unwrap();
                let stderr = child.0.stderr.take().unwrap();
                use std::io::Read;
                let mut output = Vec::new();
                let mut errors = Vec::new();
                BufReader::new(stdout).read_to_end(&mut output).unwrap();
                BufReader::new(stderr).read_to_end(&mut errors).unwrap();
                return Output {
                    status: child.0.wait().unwrap(),
                    stdout: output,
                    stderr: errors,
                };
            }
            assert!(
                Instant::now() < deadline,
                "CLI blocked on evidence: {args:?}"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn fswatch(&self) -> Value {
        let output = self.run(&["--json", "supervisor", "status"]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(value["schema"], 1);
        assert_eq!(value["ok"], true);
        assert_eq!(value["command"], "supervisor.status");
        value["data"]["fswatch"].clone()
    }

    fn canonical(&self, field: &str) -> String {
        let output = self.run(&["state", "reconcile"]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let state = fs::read_to_string(self.path(".state/machines/supervisors.state")).unwrap();
        assert!(state.contains("schema=1\n"));
        state
            .lines()
            .find_map(|line| {
                let (key, value) = line.split_once('=')?;
                (key == field).then(|| value.to_owned())
            })
            .unwrap_or_else(|| panic!("missing {field}: {state}"))
    }

    fn set_pid(&self, pid: u32) {
        self.write(FSWATCH_PID, &format!("{pid}\n"));
        self.write(KERNEL_PID, &format!("{pid}\n"));
    }

    fn unknown_stop_preserves(&self, process: Option<&mut Process>) {
        let path = self.path(FSWATCH_PID);
        let before = fs::symlink_metadata(&path).unwrap();
        let contents = before.is_file().then(|| fs::read(&path).ok()).flatten();
        let output = self.run(&["service", "stop"]);
        assert!(
            !output.status.success(),
            "stop claimed success despite unknown evidence"
        );
        assert!(
            fs::symlink_metadata(&path).is_ok(),
            "stop discarded unknown pidfile"
        );
        if let Some(contents) = contents {
            assert_eq!(fs::read(&path).unwrap(), contents);
        }
        assert!(
            !self.path("cleanup-entered").exists(),
            "unknown stop entered shell cleanup"
        );
        if let Some(process) = process {
            assert!(
                process.0.try_wait().unwrap().is_none(),
                "unknown process was signaled"
            );
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Process(Child);

impl Process {
    fn ready(command: &mut Command) -> Self {
        let mut process = Self(
            command
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap(),
        );
        let mut ready = String::new();
        BufReader::new(process.0.stdout.take().unwrap())
            .read_line(&mut ready)
            .unwrap();
        assert_eq!(ready, "ready\n");
        process
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn foreign_process() -> Process {
    Process::ready(Command::new("/bin/sh").args(["-c", "printf 'ready\\n'; read hold"]))
}

fn malformed_argv_process() -> Process {
    Process::ready(Command::new("/bin/sh").args(["-c", "printf 'ready\\n'\nread hold"]))
}

#[test]
fn live_owned_supervisor_is_reported_and_term_exit_precedes_cleanup() {
    let fixture = Fixture::new();
    fixture.script(
        ".state/fswatch/magicnet-config.loop.sh",
        "#!/bin/sh\ntrap 'sleep 0.5; test -f \"$MODDIR/.state/fswatch/magicnet-config.pid\" || printf lost > \"$MODDIR/owner-lost-before-exit\"; printf exited > \"$MODDIR/supervisor-exited\"; exit 0' TERM\nprintf 'ready\\n'\nread hold\n",
    );
    let mut child = Process::ready(
        Command::new("/bin/sh")
            .arg(fixture.path(".state/fswatch/magicnet-config.loop.sh"))
            .env("MODDIR", &fixture.0),
    );
    fixture.write(FSWATCH_PID, &format!("{}\n", child.0.id()));
    assert_eq!(fixture.fswatch(), child.0.id().to_string());
    assert_eq!(fixture.canonical("fswatch"), "running");
    fixture.write("lib/magicnet.sh", "magicnet_prepare_network_for_core_stop() { test -f \"$MODDIR/supervisor-exited\" || return 90; printf prepare > \"$MODDIR/cleanup-entered\"; }\nmagicnet_lifecycle_after_stop() { :; }\nmagicnet_supervisors_start_detached() { :; }\n");
    let stopped = fixture.run(&["service", "stop"]);
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    assert!(
        child.0.try_wait().unwrap().is_some(),
        "success returned before supervisor exit"
    );
    assert!(fixture.path("supervisor-exited").exists());
    assert!(
        !fixture.path("owner-lost-before-exit").exists(),
        "pidfile was removed before exit"
    );
    assert!(!fixture.path(FSWATCH_PID).exists());
    assert!(fixture.path("cleanup-entered").exists());
    assert_eq!(fixture.fswatch(), "stopped");
}

#[test]
fn sigterm_survivor_is_killed_before_pidfile_and_network_cleanup() {
    use std::os::unix::process::ExitStatusExt;
    let fixture = Fixture::new();
    fixture.script(
        ".state/fswatch/magicnet-config.loop.sh",
        "#!/bin/sh\ntrap '' TERM\nprintf 'ready\\n'\nread hold\n",
    );
    let mut child = Process::ready(
        Command::new("/bin/sh").arg(fixture.path(".state/fswatch/magicnet-config.loop.sh")),
    );
    fixture.write(FSWATCH_PID, &format!("{}\n", child.0.id()));
    assert_eq!(fixture.fswatch(), child.0.id().to_string());
    fixture.write("lib/magicnet.sh", &format!(
        "magicnet_prepare_network_for_core_stop() {{ if [ -r /proc/{}/stat ]; then test \"$(awk '{{print $3}}' /proc/{}/stat)\" = Z || return 90; fi; test ! -e \"$MODDIR/.state/fswatch/magicnet-config.pid\" || return 91; printf prepare > \"$MODDIR/cleanup-entered\"; }}\nmagicnet_lifecycle_after_stop() {{ printf final > \"$MODDIR/cleanup-finished\"; }}\nmagicnet_supervisors_start_detached() {{ :; }}\n",
        child.0.id(), child.0.id()
    ));
    let started = Instant::now();
    let output = fixture.run(&["service", "stop"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(started.elapsed() < Duration::from_secs(4));
    assert_eq!(child.0.wait().unwrap().signal(), Some(libc::SIGKILL));
    assert!(!fixture.path(FSWATCH_PID).exists());
    assert!(fixture.path("cleanup-entered").exists());
    assert!(fixture.path("cleanup-finished").exists());
    assert_eq!(fixture.fswatch(), "stopped");
}

#[test]
fn same_pid_atomic_marker_replacement_during_stop_is_preserved() {
    let fixture = Fixture::new();
    fixture.script(
        ".state/fswatch/magicnet-config.loop.sh",
        "#!/bin/sh\ntrap 'printf \"%s\\n\" \"$$\" > \"$MODDIR/.state/fswatch/replacement.pid\"; mv \"$MODDIR/.state/fswatch/replacement.pid\" \"$MODDIR/.state/fswatch/magicnet-config.pid\"; exit 0' TERM\nprintf 'ready\\n'\nread hold\n",
    );
    let mut child = Process::ready(
        Command::new("/bin/sh")
            .arg(fixture.path(".state/fswatch/magicnet-config.loop.sh"))
            .env("MODDIR", &fixture.0),
    );
    fixture.write(FSWATCH_PID, &format!("{}\n", child.0.id()));
    let output = fixture.run(&["service", "stop"]);
    assert!(!output.status.success());
    assert!(child.0.try_wait().unwrap().is_some());
    assert_eq!(
        fs::read_to_string(fixture.path(FSWATCH_PID)).unwrap(),
        format!("{}\n", child.0.id())
    );
    assert!(!fixture.path("cleanup-entered").exists());
}

#[test]
fn generation_change_observed_during_stop_preserves_the_new_marker() {
    let fixture = Fixture::new();
    fixture.script(
        ".state/fswatch/magicnet-config.loop.sh",
        "#!/bin/sh\ntrap 'printf \"2147483647\\n\" > \"$MODDIR/.state/fswatch/magicnet-config.pid\"; exit 0' TERM\nprintf 'ready\\n'\nread hold\n",
    );
    let mut child = Process::ready(
        Command::new("/bin/sh")
            .arg(fixture.path(".state/fswatch/magicnet-config.loop.sh"))
            .env("MODDIR", &fixture.0),
    );
    fixture.write(FSWATCH_PID, &format!("{}\n", child.0.id()));
    let output = fixture.run(&["service", "stop"]);
    assert!(!output.status.success());
    assert!(child.0.try_wait().unwrap().is_some());
    assert_eq!(
        fs::read_to_string(fixture.path(FSWATCH_PID)).unwrap(),
        "2147483647\n"
    );
    assert!(!fixture.path("cleanup-entered").exists());
}

#[test]
fn live_malformed_argv_remains_unknown_and_is_not_signaled() {
    let fixture = Fixture::new();
    let mut child = malformed_argv_process();
    fixture.set_pid(child.0.id());
    assert_eq!(fixture.fswatch(), "unknown");
    assert_eq!(fixture.canonical("fswatch"), "unknown");
    assert_eq!(fixture.canonical("kernel_watchdog"), "unknown");
    fixture.unknown_stop_preserves(Some(&mut child));
}

#[test]
fn indeterminate_stop_preserves_owner_before_any_shell_cleanup() {
    let fixture = Fixture::new();
    let mut child = malformed_argv_process();
    fixture.write(FSWATCH_PID, &format!("{}\n", child.0.id()));
    fixture.unknown_stop_preserves(Some(&mut child));
}

#[test]
fn canonical_watchdogs_require_real_module_argv_and_observe_exit() {
    for (name, field) in [
        ("magicnet-kernel", "kernel_watchdog"),
        ("magicnet-hotspot-route", "hotspot_watchdog"),
    ] {
        let fixture = Fixture::new();
        let script = format!(".state/watchdog/{name}.loop.sh");
        let pidfile = format!(".state/watchdog/{name}.pid");
        fixture.script(&script, "#!/bin/sh\nprintf 'ready\\n'\nread hold\n");
        let mut child = Process::ready(Command::new("/bin/sh").arg(fixture.path(&script)));
        fixture.write(&pidfile, &format!("{}\n", child.0.id()));
        assert_eq!(fixture.canonical(field), "running");
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        assert_eq!(fixture.canonical(field), "stale");
        assert!(
            fixture.path(&pidfile).exists(),
            "observation cleaned stale evidence"
        );
    }
}

#[test]
fn live_foreign_argv_is_stopped_without_signaling_the_process() {
    let fixture = Fixture::new();
    let mut child = foreign_process();
    fixture.set_pid(child.0.id());
    assert_eq!(fixture.fswatch(), "stopped");
    assert_eq!(fixture.canonical("fswatch"), "stopped");
    assert_eq!(fixture.canonical("kernel_watchdog"), "stale");
    assert!(
        fixture.path(FSWATCH_PID).exists(),
        "status mutated evidence"
    );
    let output = fixture.run(&["service", "stop"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!fixture.path(FSWATCH_PID).exists());
    assert!(
        child.0.try_wait().unwrap().is_none(),
        "foreign process was signaled"
    );
}

#[test]
fn an_unreaped_zombie_is_stopped_and_its_pidfile_is_stale() {
    let fixture = Fixture::new();
    let child = Process(
        Command::new("/bin/sh")
            .args(["-c", "exit 0"])
            .spawn()
            .unwrap(),
    );
    let stat = PathBuf::from(format!("/proc/{}/stat", child.0.id()));
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let value = fs::read_to_string(&stat).unwrap();
        if value.rsplit_once(") ").unwrap().1.starts_with("Z ") {
            break;
        }
        assert!(Instant::now() < deadline, "child did not become a zombie");
        thread::sleep(Duration::from_millis(10));
    }
    fixture.set_pid(child.0.id());
    assert_eq!(fixture.fswatch(), "stopped");
    assert_eq!(fixture.canonical("fswatch"), "stopped");
    assert_eq!(fixture.canonical("kernel_watchdog"), "stale");
    let output = fixture.run(&["service", "stop"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!fixture.path(FSWATCH_PID).exists());
}

#[test]
fn malformed_pidfiles_are_unknown_and_preserved_by_stop() {
    for contents in [
        "",
        "0\n",
        "-1\n",
        "+1\n",
        "2147483648\n",
        "12\n34\n",
        "not-a-pid\n",
    ] {
        let fixture = Fixture::new();
        fixture.write(FSWATCH_PID, contents);
        fixture.write(KERNEL_PID, contents);
        assert_eq!(fixture.fswatch(), "unknown", "content={contents:?}");
        assert_eq!(fixture.canonical("fswatch"), "unknown");
        assert_eq!(fixture.canonical("kernel_watchdog"), "unknown");
        fixture.unknown_stop_preserves(None);
    }
    let fixture = Fixture::new();
    fixture.write(FSWATCH_PID, &"1".repeat(4096));
    assert_eq!(fixture.fswatch(), "unknown");
    fixture.unknown_stop_preserves(None);
}

#[test]
fn nonregular_pidfiles_are_unknown_without_blocking_or_cleanup() {
    for kind in ["directory", "symlink", "fifo"] {
        let fixture = Fixture::new();
        let mut child = foreign_process();
        let path = fixture.path(FSWATCH_PID);
        match kind {
            "directory" => fs::create_dir(&path).unwrap(),
            "symlink" => {
                fixture.write("foreign.pid", &format!("{}\n", child.0.id()));
                symlink(fixture.path("foreign.pid"), &path).unwrap();
            }
            "fifo" => {
                let path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
            }
            _ => unreachable!(),
        }
        assert_eq!(fixture.fswatch(), "unknown", "source={kind}");
        assert_eq!(fixture.canonical("fswatch"), "unknown");
        fixture.unknown_stop_preserves(Some(&mut child));
        let kernel = fixture.path(KERNEL_PID);
        match kind {
            "directory" => fs::create_dir(kernel).unwrap(),
            "symlink" => symlink(fixture.path("foreign.pid"), kernel).unwrap(),
            "fifo" => {
                let path = std::ffi::CString::new(kernel.as_os_str().as_encoded_bytes()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
            }
            _ => unreachable!(),
        }
        assert_eq!(
            fixture.canonical("kernel_watchdog"),
            "unknown",
            "source={kind}"
        );
    }
}

#[test]
fn unreadable_pidfile_is_unknown_and_keeps_the_live_owner() {
    if unsafe { libc::geteuid() } == 0 {
        // Root can read chmod(000) files; nonregular and malformed sources
        // still exercise deterministic read failure in every environment.
        return;
    }
    let fixture = Fixture::new();
    let mut child = foreign_process();
    fixture.set_pid(child.0.id());
    fs::set_permissions(fixture.path(FSWATCH_PID), fs::Permissions::from_mode(0o000)).unwrap();
    assert_eq!(fixture.fswatch(), "unknown");
    assert_eq!(fixture.canonical("fswatch"), "unknown");
    fixture.unknown_stop_preserves(Some(&mut child));
}
