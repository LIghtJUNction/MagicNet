use std::fs;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn process_is_live(pid: i32) -> bool {
    let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return false;
    };
    stat.rsplit_once(") ")
        .and_then(|(_, fields)| fields.split_whitespace().next())
        != Some("Z")
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
    while :; do :; done
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
    let deadline = Instant::now() + Duration::from_secs(5);
    while !pid_file.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    let shell_pid = fs::read_to_string(&pid_file)
        .expect("status shell did not publish its PID")
        .trim()
        .parse::<i32>()
        .unwrap();
    assert!(process_is_live(shell_pid));

    cli.kill().expect("kill CLI parent");
    let _ = cli.wait();
    let deadline = Instant::now() + Duration::from_secs(3);
    while process_is_live(shell_pid) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    if process_is_live(shell_pid) {
        unsafe {
            libc::kill(-shell_pid, libc::SIGKILL);
            libc::kill(shell_pid, libc::SIGKILL);
        }
        panic!("privileged status shell survived its CLI parent");
    }

    let _ = fs::remove_dir_all(fixture);
}
