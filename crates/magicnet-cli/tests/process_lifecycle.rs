#![cfg(any(target_os = "android", target_os = "linux"))]

use std::fs;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Reports whether Linux `/proc` still contains a non-zombie process.
/// Stopped processes count as live because they still retain runtime state.
fn process_is_live(pid: i32) -> bool {
    let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return false;
    };
    stat.rsplit_once(") ")
        .and_then(|(_, fields)| fields.split_whitespace().next())
        != Some("Z")
}

fn wait_for_published_pid(path: &std::path::Path, deadline: Instant) -> i32 {
    while Instant::now() < deadline {
        if let Some(pid) = fs::read_to_string(path)
            .ok()
            .and_then(|value| value.trim().parse().ok())
        {
            return pid;
        }
        thread::sleep(Duration::from_millis(20));
    }
    panic!("PID was not published to {}", path.display());
}

#[test]
fn process_is_live_treats_a_zombie_as_terminated() {
    let mut child = Command::new("sh")
        .args(["-c", "exit 0"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn short-lived child");
    let pid = child.id() as i32;
    let deadline = Instant::now() + Duration::from_secs(1);
    while process_is_live(pid) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(!process_is_live(pid));
    let _ = child.wait();
}

#[test]
fn killing_cli_parent_terminates_privileged_shell() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let fixture = std::env::temp_dir().join(format!(
        "magicnet-parent-death-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir_all(fixture.join("bin")).unwrap();
    fs::create_dir_all(fixture.join("lib/kamfw")).unwrap();
    fs::write(fixture.join("module.prop"), "id=MagicNet\n").unwrap();
    fs::write(fixture.join("lib/kamfw/.kamfwrc"), "import() { :; }\n").unwrap();
    fs::write(fixture.join("lib/magicnet.sh"), "").unwrap();
    fs::write(
        fixture.join("lib/magicnet_singbox_subscribe.sh"),
        r#"magicnet_singbox_status() {
    printf '%s\n' "$$" >"$MODDIR/status-shell.pid"
    trap 'sleep 1; printf "%s\n" complete >"$MODDIR/rollback-marker"; exit 143' TERM
    sleep 30 &
    printf '%s\n' "$!" >"$MODDIR/status-grandchild.pid"
    wait
}
"#,
    )
    .unwrap();

    // Android production builds intentionally ignore MODDIR.  Execute a copy
    // from a fixture that satisfies the same trusted module-root discovery
    // contract instead of weakening that boundary for tests.
    let fixture_cli = fixture.join("bin/magicnet-cli");
    fs::copy(env!("CARGO_BIN_EXE_magicnet-cli"), &fixture_cli)
        .expect("copy fixture CLI into trusted module layout");
    let mut cli = Command::new(&fixture_cli)
        .args(["sub", "status"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn fixture CLI");

    let pid_file = fixture.join("status-shell.pid");
    let grandchild_pid_file = fixture.join("status-grandchild.pid");
    let deadline = Instant::now() + Duration::from_secs(5);
    let shell_pid = wait_for_published_pid(&pid_file, deadline);
    let grandchild_pid = wait_for_published_pid(&grandchild_pid_file, deadline);
    assert!(process_is_live(shell_pid));
    assert!(process_is_live(grandchild_pid));

    cli.kill().expect("kill CLI parent");
    let _ = cli.wait();
    let deadline = Instant::now() + Duration::from_secs(5);
    while (process_is_live(shell_pid) || process_is_live(grandchild_pid))
        && Instant::now() < deadline
    {
        thread::sleep(Duration::from_millis(20));
    }
    if process_is_live(shell_pid) || process_is_live(grandchild_pid) {
        unsafe {
            libc::kill(-shell_pid, libc::SIGKILL);
            libc::kill(shell_pid, libc::SIGKILL);
            libc::kill(grandchild_pid, libc::SIGKILL);
        }
        panic!("privileged status process group survived its CLI parent");
    }
    assert_eq!(
        fs::read_to_string(fixture.join("rollback-marker"))
            .expect("watchdog killed the worker before TERM rollback completed"),
        "complete\n"
    );

    let _ = fs::remove_dir_all(fixture);
}
