use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "magicnet-cli-observation-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&root).expect("create fixture");
        Self(root)
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
            .env("MODDIR", &self.0)
            .env("MAGICNET_API", "http://127.0.0.1:1")
            .args(args)
            .output()
            .expect("run CLI")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn help_and_rejected_commands_do_not_create_state() {
    for (args, success) in [
        (vec![], true),
        (vec!["help"], true),
        (vec!["--help"], true),
        (vec!["-h"], true),
        (vec!["not-a-magicnet-command"], false),
        (vec!["state", "not-an-operation"], false),
        (vec!["--json", "capabilities"], true),
        (vec!["--json", "service", "start"], false),
    ] {
        let fixture = Fixture::new();
        let output = fixture.run(&args);
        assert_eq!(
            output.status.success(),
            success,
            "args={args:?}, stderr={}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            !fixture.0.join(".state").exists(),
            "observation created state: {args:?}"
        );
    }
}

#[test]
fn a_path_query_does_not_replace_existing_canonical_observations() {
    let fixture = Fixture::new();
    let machines = fixture.0.join(".state/machines");
    fs::create_dir_all(&machines).expect("create machines");
    let service = machines.join("service.state");
    let sentinel = "schema=1\ndomain=service\nstate=unknown\nlifecycle=pending\n";
    fs::write(&service, sentinel).expect("write observation");

    let output = fixture.run(&["sub", "file", "sing-box"]);
    assert!(output.status.success());
    assert_eq!(fs::read_to_string(service).unwrap(), sentinel);
    assert_eq!(fs::read_dir(machines).unwrap().count(), 1);
}

#[test]
fn a_failed_control_command_still_publishes_observed_state() {
    let fixture = Fixture::new();
    let output = fixture.run(&["core", "select", "not-a-supported-core"]);
    assert!(!output.status.success());
    assert!(
        fixture.0.join(".state/machines/service.state").is_file(),
        "failed control command skipped publication: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[cfg(target_os = "linux")]
#[test]
fn live_singbox_with_unreadable_argv_is_unknown_not_stopped() {
    use std::io::{BufRead, BufReader};
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Child, Stdio};
    use std::time::{Duration, Instant};

    struct ChildGuard(Child);
    impl Drop for ChildGuard {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    let fixture = Fixture::new();
    fs::create_dir_all(fixture.0.join("bin")).unwrap();
    // Ownership lookup needs a real module path even when argv cannot be
    // inspected. A live process may expose invalid argv bytes after rewriting
    // its title; that is not evidence that it has exited.
    let binary = fixture.0.join("bin/sing-box");
    fs::write(
        &binary,
        "#!/bin/sh\nprintf 'sing-box\\n' > /proc/$$/comm\nprintf 'ready\\n'\nread hold\n",
    )
    .unwrap();
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
    let mut child = ChildGuard(
        Command::new("/bin/sh")
            .args([
                "-c",
                "printf 'sing-box\\n' > /proc/$$/comm\nprintf 'ready\\n'\nread hold",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("spawn live malformed-argv candidate"),
    );
    let mut ready = String::new();
    BufReader::new(child.0.stdout.take().unwrap())
        .read_line(&mut ready)
        .unwrap();
    assert_eq!(ready, "ready\n");
    let pidof = fixture.0.join("pidof");
    fs::write(
        &pidof,
        format!("#!/bin/sh\nprintf '%s\\n' {}\n", child.0.id()),
    )
    .unwrap();
    fs::set_permissions(&pidof, fs::Permissions::from_mode(0o755)).unwrap();

    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
            .env("MODDIR", &fixture.0)
            .env("PATH", &fixture.0)
            .env("MAGICNET_API", "http://127.0.0.1:1")
            .args(args)
            .output()
            .expect("inspect process evidence")
    };
    let status = || {
        let output = run(&["--json", "service", "status"]);
        assert!(output.status.success(), "stderr={:?}", output.stderr);
        serde_json::from_slice::<serde_json::Value>(&output.stdout).unwrap()
    };
    let unknown = status();
    assert_eq!(
        unknown["data"]["core"]["sing_box"]["process_state"],
        "unknown"
    );
    assert!(unknown["data"]["core"]["sing_box"]["running"].is_null());
    assert_eq!(unknown["data"]["lifecycle"], "unknown");
    assert!(child.0.try_wait().unwrap().is_none());

    let pidfile = fixture
        .0
        .join(".state/wifi-policy/magicnet-wifi-policy.pid");
    fs::create_dir_all(pidfile.parent().unwrap()).unwrap();
    let sentinel = format!("{}\n", child.0.id());
    fs::write(&pidfile, &sentinel).unwrap();
    let stopped = run(&["service", "stop"]);
    assert!(!stopped.status.success());
    assert_eq!(fs::read_to_string(&pidfile).unwrap(), sentinel);
    assert!(child.0.try_wait().unwrap().is_none());

    // A valid owned generation must still be recognized. Combining its PID
    // with indeterminate evidence cannot hide that uncertainty.
    let config = fixture.0.join(".config/sing-box/config.json");
    let workdir = fixture.0.join(".config/sing-box");
    let mut owned = ChildGuard(
        Command::new(&binary)
            .arg("run")
            .arg("-c")
            .arg(&config)
            .arg("-D")
            .arg(&workdir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    ready.clear();
    BufReader::new(owned.0.stdout.take().unwrap())
        .read_line(&mut ready)
        .unwrap();
    assert_eq!(ready, "ready\n");
    let candidates = |pids: &str| {
        fs::write(&pidof, format!("#!/bin/sh\nprintf '%s\\n' '{pids}'\n")).unwrap();
    };
    candidates(&owned.0.id().to_string());
    let running = status();
    assert_eq!(
        running["data"]["core"]["sing_box"]["process_state"],
        "running"
    );
    assert_eq!(running["data"]["core"]["sing_box"]["running"], true);
    candidates(&format!("{} {}", owned.0.id(), child.0.id()));
    assert_eq!(
        status()["data"]["core"]["sing_box"]["process_state"],
        "unknown"
    );
    assert!(owned.0.try_wait().unwrap().is_none());
    assert!(child.0.try_wait().unwrap().is_none());

    child.0.kill().unwrap();
    child.0.wait().unwrap();
    assert_eq!(
        status()["data"]["core"]["sing_box"]["process_state"],
        "running"
    );

    // Keep the exited owned child unreaped so /proc still exists with state Z.
    // This must remain definite stopped evidence rather than becoming unknown.
    drop(owned.0.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(2);
    while !fs::read_to_string(format!("/proc/{}/stat", owned.0.id()))
        .unwrap()
        .rsplit_once(") ")
        .is_some_and(|(_, fields)| fields.starts_with("Z "))
    {
        assert!(Instant::now() < deadline, "owned child did not exit");
        std::thread::sleep(Duration::from_millis(5));
    }
    let stopped = status();
    assert_eq!(
        stopped["data"]["core"]["sing_box"]["process_state"],
        "stopped"
    );
    assert_eq!(stopped["data"]["core"]["sing_box"]["running"], false);
    owned.0.wait().unwrap();
    assert_eq!(
        status()["data"]["core"]["sing_box"]["process_state"],
        "stopped"
    );
}
