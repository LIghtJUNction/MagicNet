use std::ffi::CString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn fixture(label: &str) -> std::path::PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before Unix epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "magicnet-proc-reader-{label}-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir_all(path.join("123")).expect("create proc reader fixture");
    path
}

fn make_fifo(path: &std::path::Path) {
    let path_c = CString::new(path.as_os_str().as_bytes()).expect("FIFO path contains NUL");
    assert_eq!(unsafe { libc::mkfifo(path_c.as_ptr(), 0o600) }, 0);
}

fn child_pids(pid: u32) -> Vec<u32> {
    fs::read_to_string(format!("/proc/{pid}/task/{pid}/children"))
        .unwrap_or_default()
        .split_whitespace()
        .filter_map(|value| value.parse().ok())
        .collect()
}

fn wait_for_child(pid: u32, deadline: Duration) -> Option<u32> {
    let started = Instant::now();
    while started.elapsed() < deadline {
        if let Some(child) = child_pids(pid).into_iter().next() {
            return Some(child);
        }
        thread::sleep(Duration::from_millis(5));
    }
    None
}

fn wait_until_gone(pid: u32, deadline: Duration) -> bool {
    let started = Instant::now();
    while started.elapsed() < deadline {
        if !std::path::Path::new(&format!("/proc/{pid}")).exists() {
            return true;
        }
        thread::sleep(Duration::from_millis(10));
    }
    false
}

struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn proc_cmdline_command_is_bounded_and_strict() {
    let root = fixture("strict");
    let cmdline = root.join("123/cmdline");
    fs::write(&cmdline, b"/system/bin/sh\0/module/worker.sh\0")
        .expect("write valid cmdline fixture");
    let cli = env!("CARGO_BIN_EXE_magicnet-cli");

    let output = Command::new(cli)
        .arg("__proc-cmdline")
        .arg(&root)
        .arg("123")
        .output()
        .expect("run bounded proc reader");
    assert!(output.status.success(), "stderr={:?}", output.stderr);
    assert_eq!(output.stdout, b"/system/bin/sh\n/module/worker.sh\n");

    fs::write(&cmdline, b"/system/bin/sh\0argument with spaces\0")
        .expect("write spaced argv fixture");
    let output = Command::new(cli)
        .arg("__proc-cmdline")
        .arg(&root)
        .arg("123")
        .output()
        .expect("run spaced argv reader");
    assert!(output.status.success(), "stderr={:?}", output.stderr);
    assert_eq!(output.stdout, b"/system/bin/sh\nargument with spaces\n");

    fs::write(&cmdline, b"/system/bin/sh\0\xff\0").expect("write non-UTF8 argv fixture");
    let output = Command::new(cli)
        .arg("__proc-cmdline")
        .arg(&root)
        .arg("123")
        .output()
        .expect("run non-UTF8 argv reader");
    assert!(!output.status.success());

    fs::write(&cmdline, vec![b'x'; 64 * 1024 + 1]).expect("write oversized fixture");
    let started = Instant::now();
    let output = Command::new(cli)
        .arg("__proc-cmdline")
        .arg(&root)
        .arg("123")
        .output()
        .expect("run oversized proc reader");
    assert!(!output.status.success());
    assert!(started.elapsed() < Duration::from_secs(2));
    fs::remove_dir_all(root).expect("remove strict proc reader fixture");
}

#[test]
fn blocked_proc_reader_times_out_without_a_live_worker() {
    let root = fixture("timeout");
    make_fifo(&root.join("123/cmdline"));
    let cli = env!("CARGO_BIN_EXE_magicnet-cli");

    let started = Instant::now();
    let output = Command::new(cli)
        .arg("__proc-cmdline")
        .arg(&root)
        .arg("123")
        .output()
        .expect("run blocked proc reader");
    assert!(!output.status.success());
    assert!(started.elapsed() >= Duration::from_millis(400));
    assert!(started.elapsed() < Duration::from_secs(2));
    fs::remove_dir_all(root).expect("remove timeout proc reader fixture");
}

#[test]
fn script_scan_is_framed_and_fifo_failure_is_indeterminate() {
    let root = fixture("script-scan");
    let script = "/module/.state/fswatch/managed.loop.sh";
    fs::write(
        root.join("123/cmdline"),
        format!("/system/bin/sh\0{script}\0").as_bytes(),
    )
    .expect("write matching script cmdline");
    let cli = env!("CARGO_BIN_EXE_magicnet-cli");
    let output = Command::new(cli)
        .args(["__proc-script-pids", root.to_str().unwrap(), script])
        .output()
        .expect("run framed script scan");
    assert!(output.status.success(), "stderr={:?}", output.stderr);
    assert_eq!(
        output.stdout,
        b"MAGICNET_PROC_PIDS_V1\n123\nMAGICNET_PROC_PIDS_END 1\n"
    );

    fs::remove_file(root.join("123/cmdline")).expect("remove regular cmdline");
    make_fifo(&root.join("123/cmdline"));
    let started = Instant::now();
    let output = Command::new(cli)
        .args(["__proc-script-pids", root.to_str().unwrap(), script])
        .output()
        .expect("run FIFO script scan");
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    assert!(started.elapsed() < Duration::from_secs(2));
    fs::remove_dir_all(root).expect("remove script scan fixture");
}

#[test]
fn oversized_pidof_output_is_indeterminate_and_never_framed() {
    let root = fixture("pidof-truncation");
    let pidof = root.join("pidof");
    fs::write(
        &pidof,
        "#!/bin/sh\ni=0\nwhile [ \"$i\" -lt 4000 ]; do printf '12345 '; i=$((i + 1)); done\nprintf '\\n'\n",
    )
    .expect("write pidof fixture");
    fs::set_permissions(&pidof, fs::Permissions::from_mode(0o755)).expect("chmod pidof fixture");
    let output = Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
        .args(["__proc-pids", "sing-box"])
        .env("PATH", &root)
        .output()
        .expect("run oversized pid lookup");
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    fs::remove_dir_all(root).expect("remove pidof fixture");
}

#[test]
fn killing_the_calling_shell_cascades_to_reader_descendants() {
    let root = fixture("parent-death");
    make_fifo(&root.join("123/cmdline"));
    let cli = env!("CARGO_BIN_EXE_magicnet-cli");
    let script = format!("\"{cli}\" __proc-cmdline \"{}\" 123 & wait", root.display());
    let shell = Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn proc reader calling shell");
    let mut shell = ChildGuard(shell);
    let shell_pid = shell.0.id();
    let cli_pid = wait_for_child(shell_pid, Duration::from_millis(300))
        .expect("calling shell did not spawn CLI");
    let worker_pid = wait_for_child(cli_pid, Duration::from_millis(300))
        .expect("CLI did not spawn bounded reader worker");

    shell.0.kill().expect("kill calling shell");
    shell.0.wait().expect("reap calling shell");
    assert!(wait_until_gone(cli_pid, Duration::from_secs(1)));
    assert!(wait_until_gone(worker_pid, Duration::from_secs(1)));
    fs::remove_dir_all(root).expect("remove parent-death proc reader fixture");
}
