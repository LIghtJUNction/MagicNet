#![cfg(target_os = "linux")]

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

const PROBE_REPORT: &str = ".state/transparent-ebpf/probe.json";
const LIVE_REPORT: &str =
    r#"{"active_programs":[{"id":4242,"name":"sb_ebpf_conn4"}],"result":"supported"}"#;

struct Fixture(PathBuf);

impl Fixture {
    fn new(status_success: bool, existing_state: bool) -> Self {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "magicnet-ebpf-observation-{}-{stamp}",
            std::process::id()
        ));
        let fixture = Self(root);
        fixture.write(
            ".config/magicnet/transparent-mode.conf",
            "MAGICNET_TRANSPARENT_MODE=ebpf\n",
        );
        fixture.write(
            ".config/sing-box/config.json",
            r#"{"inbounds":[{"tag":"tun-in","type":"ebpf","mode":"local","local":{"dns_mode":"hijack","cgroup_path":"/sys/fs/cgroup"}}]}"#,
        );
        fixture.write("status.stdout", LIVE_REPORT);
        fixture.write("status.exit", if status_success { "0\n" } else { "7\n" });
        fixture.script(
            "bin/sing-box",
            r#"#!/bin/sh
case "$1" in
run)
    printf 'sing-box\n' > /proc/$$/comm
    printf 'ready\n'
    read hold
    exit 0
    ;;
tools)
    root=${0%/bin/sing-box}
    # The health capability check uses the configured cgroup. Its separate
    # active-state observation must also preserve recovery data on failure.
    case " $* " in
    *' --cgroup '*) cat "$root/status.stdout"; exit 0 ;;
    esac
    cat "$root/status.stdout"
    exit "$(cat "$root/status.exit")"
    ;;
esac
exit 1
"#,
        );
        fixture.write("lib/kamfw/.kamfwrc", "import() { :; }\n");
        fixture.write(
            "lib/magicnet.sh",
            "magicnet_cmd_exists() { command -v \"$1\" >/dev/null 2>&1; }\n. \"$MODDIR/lib/magicnet/transparent.sh\"\n",
        );
        fixture.write(
            "lib/magicnet/transparent.sh",
            include_str!("../../../src/MagicNet/lib/magicnet/transparent.sh"),
        );
        // The old observer reaches the real production report publisher.
        // All successful inputs here are valid reports; jq itself is outside
        // this regression, so only its file-to-stdout boundary is doubled.
        fixture.script("bin/jq", "#!/bin/sh\nfor last; do :; done\ncat \"$last\"\n");
        // Host pidof implementations differ in whether shell scripts are
        // indexed. Only provide the candidate; CLI ownership still checks
        // its live /proc identity, argv, config and module executable path.
        fixture.script(
            "bin/pidof",
            "#!/bin/sh\n[ \"$1\" = sing-box ] || exit 1\nroot=${0%/bin/pidof}\ncat \"$root/core.pid\"\n",
        );
        if existing_state {
            fixture.write(
                PROBE_REPORT,
                r#"{"active_programs":[{"id":9999,"name":"sb_ebpf_conn4"}],"result":"supported","recovery_generation":"previous"}"#,
            );
            fixture.write(".state/transparent-ebpf/capability", "ok\n");
            fixture.write(".state/transparent-ebpf/shared.pending", "pending\n");
            fixture.write(".state/transparent-ebpf/shared-interfaces.list", "wlan2\n");
            fixture.write(
                ".state/machines/service.state",
                "schema=1\ndomain=service\nstate=unknown\nlifecycle=pending\n",
            );
            fixture.write(".state/transparent-transaction/phase", "prepared\n");
        }
        fixture
    }

    fn write(&self, relative: &str, contents: &str) {
        let path = self.0.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    fn script(&self, relative: &str, contents: &str) {
        self.write(relative, contents);
        fs::set_permissions(self.0.join(relative), fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn core(&self) -> Process {
        let mut child = Process(
            Command::new(self.0.join("bin/sing-box"))
                .arg("run")
                .arg("-c")
                .arg(self.0.join(".config/sing-box/config.json"))
                .arg("-D")
                .arg(self.0.join(".config/sing-box"))
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap(),
        );
        let mut ready = String::new();
        BufReader::new(child.0.stdout.take().unwrap())
            .read_line(&mut ready)
            .unwrap();
        assert_eq!(ready, "ready\n");
        self.write("core.pid", &format!("{}\n", child.0.id()));
        child
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
            .env("MODDIR", &self.0)
            .env("MAGICNET_API", "http://127.0.0.1:1")
            .env(
                "PATH",
                format!("{}:/usr/bin:/bin", self.0.join("bin").display()),
            )
            .args(args)
            .output()
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Process(Child);

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

type StateSnapshot = BTreeMap<PathBuf, (u64, u32, Option<Vec<u8>>)>;

fn state_snapshot(root: &Path) -> StateSnapshot {
    fn visit(path: &Path, root: &Path, snapshot: &mut StateSnapshot) {
        let Ok(metadata) = fs::symlink_metadata(path) else {
            return;
        };
        snapshot.insert(
            path.strip_prefix(root).unwrap().to_path_buf(),
            (
                metadata.ino(),
                metadata.mode(),
                metadata.is_file().then(|| fs::read(path).unwrap()),
            ),
        );
        if metadata.is_dir() {
            for entry in fs::read_dir(path).unwrap() {
                visit(&entry.unwrap().path(), root, snapshot);
            }
        }
    }
    let mut snapshot = BTreeMap::new();
    visit(&root.join(".state"), root, &mut snapshot);
    snapshot
}

fn assert_observation_preserves_state(args: &[&str]) {
    for status_success in [true, false] {
        for existing_state in [true, false] {
            let fixture = Fixture::new(status_success, existing_state);
            let _core = fixture.core();
            let before = state_snapshot(&fixture.0);
            let output = fixture.run(args);
            assert!(
                output.status.success(),
                "{args:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert_eq!(
                state_snapshot(&fixture.0), before,
                "observer {args:?} changed state (status_success={status_success}, existing_state={existing_state})"
            );

            let expected = if status_success { "missing" } else { "unknown" };
            if args.first() == Some(&"--json") {
                let value: Value = serde_json::from_slice(&output.stdout).unwrap();
                assert_eq!(value["ok"], true);
                let data = if args[1] == "service" {
                    assert_eq!(
                        value["data"]["core"]["sing_box"]["process_state"],
                        "running"
                    );
                    &value["data"]["transparent"]
                } else {
                    &value["data"]
                };
                assert_eq!(data["local_cgroup"], expected, "{value}");
                assert_eq!(
                    data["dataplane_ready"],
                    if status_success {
                        Value::Bool(false)
                    } else {
                        Value::Null
                    },
                    "a matching program name is not a current attachment: {value}"
                );
            } else {
                let text = String::from_utf8(output.stdout).unwrap();
                if args[0] == "health" {
                    assert!(text.contains("[warn] Dataplane:"), "{text}");
                    if status_success {
                        assert!(text.contains("attachment=core-bpf-fds-missing"), "{text}");
                    } else {
                        assert!(text.contains("attachment=active-status-failed"), "{text}");
                    }
                } else {
                    assert!(
                        text.contains(&format!("local_cgroup={expected}\n")),
                        "{text}"
                    );
                }
            }
        }
    }
}

#[test]
fn machine_transparent_observation_preserves_state_on_success_and_failure() {
    assert_observation_preserves_state(&["--json", "transparent", "status"]);
}

#[test]
fn machine_service_observation_preserves_state_on_success_and_failure() {
    assert_observation_preserves_state(&["--json", "service", "status"]);
}

#[test]
fn health_observation_preserves_state_on_success_and_failure() {
    assert_observation_preserves_state(&["health"]);
}

#[test]
fn human_transparent_observation_preserves_state_on_success_and_failure() {
    assert_observation_preserves_state(&["transparent", "status"]);
}
