#![cfg(any(target_os = "android", target_os = "linux"))]

use std::fs;
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::mpsc;
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

fn install_fixture_cli(path: &std::path::Path) {
    if fs::hard_link(env!("CARGO_BIN_EXE_magicnet-cli"), path).is_err() {
        fs::copy(env!("CARGO_BIN_EXE_magicnet-cli"), path)
            .expect("copy fixture CLI into trusted module layout");
    }
}

fn spawn_fixture_cli(command: &mut Command) -> std::process::Child {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match command.spawn() {
            Ok(child) => return child,
            Err(err) if err.raw_os_error() == Some(libc::ETXTBSY) && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(20));
            }
            Err(err) => panic!("spawn fixture CLI: {err}"),
        }
    }
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
    install_fixture_cli(&fixture_cli);
    let mut command = Command::new(&fixture_cli);
    command
        .args(["sub", "status"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut cli = spawn_fixture_cli(&mut command);

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

#[test]
fn killed_cli_closes_output_even_while_watchdog_grace_is_long() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let fixture = std::env::temp_dir().join(format!(
        "magicnet-watchdog-eof-{}-{nonce}",
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
    printf '%s\n' "$$" >"$MODDIR/eof-shell.pid"
    trap 'exit 143' TERM
    while :; do :; done
}
"#,
    )
    .unwrap();
    let fixture_cli = fixture.join("bin/magicnet-cli");
    install_fixture_cli(&fixture_cli);
    let mut command = Command::new(&fixture_cli);
    command
        .args(["sub", "status"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut cli = spawn_fixture_cli(&mut command);
    let shell_pid = wait_for_published_pid(
        &fixture.join("eof-shell.pid"),
        Instant::now() + Duration::from_secs(5),
    );
    let mut stdout = cli.stdout.take().unwrap();
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.read_to_end(&mut bytes);
        let _ = sender.send(result);
    });
    cli.kill().unwrap();
    let _ = cli.wait();
    receiver
        .recv_timeout(Duration::from_secs(3))
        .expect("watchdog kept the CLI output pipe open")
        .expect("read CLI output");
    let deadline = Instant::now() + Duration::from_secs(3);
    while process_is_live(shell_pid) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    if process_is_live(shell_pid) {
        unsafe { libc::kill(-shell_pid, libc::SIGKILL) };
        panic!("privileged shell survived killed CLI");
    }
    let _ = fs::remove_dir_all(fixture);
}

fn process_start_time(pid: i32) -> Option<String> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    Some(
        stat.rsplit_once(") ")?
            .1
            .split_whitespace()
            .nth(19)?
            .to_owned(),
    )
}

struct CurlFixture {
    root: std::path::PathBuf,
    cli: Option<std::process::Child>,
    curl: Option<(i32, String)>,
}

impl Drop for CurlFixture {
    fn drop(&mut self) {
        if let Some(cli) = self.cli.as_mut() {
            let _ = cli.kill();
            let _ = cli.wait();
        }
        if let Some((pid, start_time)) = &self.curl {
            // A failed parent-death assertion must clean up only this helper,
            // not a process that has reused the fixture's PID.
            if process_start_time(*pid).as_ref() == Some(start_time) && process_is_live(*pid) {
                unsafe { libc::kill(*pid, libc::SIGKILL) };
            }
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn killing_cli_parent_terminates_local_api_curl() {
    use std::os::unix::fs::PermissionsExt;

    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let mut fixture = CurlFixture {
        root: std::env::temp_dir().join(format!(
            "magicnet-curl-parent-death-{}-{nonce}",
            std::process::id()
        )),
        cli: None,
        curl: None,
    };
    fs::create_dir_all(fixture.root.join("bin")).unwrap();
    fs::create_dir_all(fixture.root.join("lib/kamfw")).unwrap();
    fs::write(fixture.root.join("module.prop"), "id=MagicNet\n").unwrap();
    fs::write(fixture.root.join("lib/kamfw/.kamfwrc"), "import() { :; }\n").unwrap();
    let fixture_cli = fixture.root.join("bin/magicnet-cli");
    install_fixture_cli(&fixture_cli);
    let pid_file = fixture.root.join("curl.pid");
    let quoted_pid_file = format!("'{}'", pid_file.to_string_lossy().replace('\'', "'\\''"));
    let shell = if cfg!(target_os = "android") {
        "/system/bin/sh"
    } else {
        "/bin/sh"
    };
    let curl = fixture.root.join("bin/curl");
    // exec retains the recorded PID and creates no unowned sleep descendant.
    fs::write(
        &curl,
        format!("#!{shell}\nprintf '%s\\n' \"$$\" > {quoted_pid_file}\nexec sleep 30\n"),
    )
    .unwrap();
    fs::set_permissions(curl, fs::Permissions::from_mode(0o700)).unwrap();
    let mut command = Command::new(&fixture_cli);
    command
        .args(["api", "proxies"])
        .env_remove("MODDIR")
        .env_remove("MODPATH")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    fixture.cli = Some(spawn_fixture_cli(&mut command));
    let curl_pid = wait_for_published_pid(&pid_file, Instant::now() + Duration::from_secs(3));
    let start_time = process_start_time(curl_pid).expect("fixture curl has exited unexpectedly");
    fixture.curl = Some((curl_pid, start_time));
    assert!(process_is_live(curl_pid));
    fixture.cli.as_mut().unwrap().kill().unwrap();
    fixture.cli.as_mut().unwrap().wait().unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while process_is_live(curl_pid) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(
        !process_is_live(curl_pid),
        "local API curl survived its CLI parent"
    );
}
