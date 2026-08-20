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
    fs::create_dir_all(fixture.join("lib/kamfw")).unwrap();
    fs::write(fixture.join("lib/kamfw/.kamfwrc"), "import() { :; }\n").unwrap();
    fs::write(fixture.join("lib/magicnet.sh"), "").unwrap();
    fs::write(
        fixture.join("lib/magicnet_singbox_subscribe.sh"),
        r#"magicnet_singbox_status() {
    printf '%s\n' "$$" >"$MODDIR/status-shell.pid"
    sleep 30 &
    printf '%s\n' "$!" >"$MODDIR/status-grandchild.pid"
    wait
}
"#,
    )
    .unwrap();

    let mut cli = Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
        .args(["sub", "status"])
        .env("MODDIR", &fixture)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn fixture CLI");

    let pid_file = fixture.join("status-shell.pid");
    let grandchild_pid_file = fixture.join("status-grandchild.pid");
    let deadline = Instant::now() + Duration::from_secs(5);
    while (!pid_file.exists() || !grandchild_pid_file.exists()) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    let shell_pid = fs::read_to_string(&pid_file)
        .expect("status shell did not publish its PID")
        .trim()
        .parse::<i32>()
        .unwrap();
    let grandchild_pid = fs::read_to_string(&grandchild_pid_file)
        .expect("status grandchild did not publish its PID")
        .trim()
        .parse::<i32>()
        .unwrap();
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

    let _ = fs::remove_dir_all(fixture);
}
