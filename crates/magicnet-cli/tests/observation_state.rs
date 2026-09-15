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
