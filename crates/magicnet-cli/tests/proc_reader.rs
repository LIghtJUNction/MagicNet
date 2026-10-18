use std::ffi::CString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
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

#[derive(Clone, Copy, Debug)]
struct ProcStat {
    pid: u32,
    parent: u32,
    state: u8,
    starttime: u64,
}

impl ProcStat {
    fn is_live(self) -> bool {
        !matches!(self.state, b'Z' | b'X' | b'x')
    }
}

fn read_proc_stat(pid: u32) -> std::io::Result<Option<ProcStat>> {
    let proc_dir = std::path::PathBuf::from(format!("/proc/{pid}"));
    let stat = match fs::read_to_string(proc_dir.join("stat")) {
        Ok(stat) => stat,
        Err(error)
            if error.kind() == std::io::ErrorKind::NotFound
                && fs::metadata(&proc_dir)
                    .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
        {
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    let malformed = || {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("malformed /proc/{pid}/stat"),
        )
    };
    let (identity, fields) = stat.rsplit_once(") ").ok_or_else(malformed)?;
    let (stat_pid, _) = identity.split_once(" (").ok_or_else(malformed)?;
    if stat_pid != pid.to_string() {
        return Err(malformed());
    }
    let mut fields = fields.split_whitespace();
    let state = match fields.next() {
        Some(value @ ("R" | "S" | "D" | "T" | "t" | "I" | "W" | "P" | "K" | "Z" | "X" | "x")) => {
            value.as_bytes()[0]
        }
        _ => return Err(malformed()),
    };
    let parent = fields
        .next()
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(malformed)?;
    let starttime = fields
        .nth(17)
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(malformed)?;
    Ok(Some(ProcStat {
        pid,
        parent,
        state,
        starttime,
    }))
}

fn wait_for_child(parent: u32, deadline: Instant) -> Option<ProcStat> {
    while Instant::now() < deadline {
        // The standard stat parent field also works with CONFIG_PROC_CHILDREN=n.
        for entry in fs::read_dir("/proc").expect("enumerate proc processes") {
            let entry = entry.expect("read proc process entry");
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|value| value.parse::<u32>().ok())
                .filter(|pid| *pid > 0 && *pid <= libc::pid_t::MAX as u32)
            else {
                continue;
            };
            let stat = read_proc_stat(pid)
                .unwrap_or_else(|error| panic!("read process {pid} while finding child: {error}"));
            if let Some(stat) = stat.filter(|stat| stat.parent == parent && stat.is_live()) {
                return Some(stat);
            }
        }
        thread::sleep(Duration::from_millis(5));
    }
    None
}

fn current_process(process: ProcStat) -> Option<ProcStat> {
    let current = read_proc_stat(process.pid)
        .unwrap_or_else(|error| panic!("read process {} state: {error}", process.pid));
    if let Some(current) = current {
        assert_eq!(
            current.starttime, process.starttime,
            "process {} identity changed before exit was observed",
            process.pid
        );
    }
    current
}

fn wait_until_exited(process: ProcStat, deadline: Instant) -> bool {
    loop {
        if current_process(process).is_none_or(|stat| !stat.is_live()) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

struct DescendantGuard(ProcStat);

impl Drop for DescendantGuard {
    fn drop(&mut self) {
        if let Ok(Some(current)) = read_proc_stat(self.0.pid) {
            if current.starttime == self.0.starttime && current.is_live() {
                unsafe { libc::kill(current.pid as libc::pid_t, libc::SIGKILL) };
            }
        }
    }
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

    fs::write(root.join("123/cmdline"), b"com.tencent.mm:appbrand0\0\0\0")
        .expect("write padded unrelated cmdline");
    let output = Command::new(cli)
        .args(["__proc-script-pids", root.to_str().unwrap(), script])
        .output()
        .expect("scan padded unrelated cmdline");
    assert!(output.status.success(), "stderr={:?}", output.stderr);
    assert_eq!(
        output.stdout,
        b"MAGICNET_PROC_PIDS_V1\nMAGICNET_PROC_PIDS_END 0\n"
    );

    // Several OEM daemons expose a newline or other non-argv byte in
    // /proc/<pid>/cmdline. They are unrelated to our managed shell, so one
    // malformed process must not poison the whole supervisor scan.
    fs::write(root.join("123/cmdline"), b"/vendor/bin/xtra-daemon\0\n\0")
        .expect("write malformed unrelated cmdline");
    let output = Command::new(cli)
        .args(["__proc-script-pids", root.to_str().unwrap(), script])
        .output()
        .expect("scan malformed unrelated cmdline");
    assert!(output.status.success(), "stderr={:?}", output.stderr);
    assert_eq!(
        output.stdout,
        b"MAGICNET_PROC_PIDS_V1\nMAGICNET_PROC_PIDS_END 0\n"
    );

    fs::write(root.join("123/cmdline"), b"/vendor/bin/daemon\0\xff\0")
        .expect("write non-UTF8 unrelated cmdline");
    let output = Command::new(cli)
        .args(["__proc-script-pids", root.to_str().unwrap(), script])
        .output()
        .expect("scan non-UTF8 unrelated cmdline");
    assert!(output.status.success(), "stderr={:?}", output.stderr);

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
fn script_scan_applies_one_deadline_across_pid_lookups() {
    let root = fixture("pidof-deadline");
    let pidof = root.join("pidof");
    fs::write(&pidof, "#!/bin/sh\nsleep 5\n").expect("write slow pidof fixture");
    fs::set_permissions(&pidof, fs::Permissions::from_mode(0o755)).expect("chmod pidof fixture");
    let started = Instant::now();
    let root_arg = root.to_str().expect("deadline fixture path is UTF-8");
    let output = Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
        .args(["__proc-script-pids", root_arg, "/module/worker.sh"])
        .env("PATH", &root)
        .output()
        .expect("run deadline-bounded script scan");
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    assert!(started.elapsed() < Duration::from_secs(2));
    fs::remove_dir_all(root).expect("remove pidof deadline fixture");
}

#[test]
fn killing_the_calling_shell_cascades_to_reader_descendants() {
    let root = fixture("parent-death");
    let fifo = root.join("123/cmdline");
    make_fifo(&fifo);
    let cli = env!("CARGO_BIN_EXE_magicnet-cli");
    let script = format!("\"{cli}\" __proc-cmdline \"{}\" 123 & wait", root.display());
    let startup_deadline = Instant::now() + Duration::from_millis(400);
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
    let cli = DescendantGuard(
        wait_for_child(shell_pid, startup_deadline).expect("calling shell did not spawn CLI"),
    );
    // The writer can open only after the worker has armed its death signal.
    // Keep it empty and open so the worker cannot finish its read normally.
    let fifo_writer = loop {
        match fs::OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&fifo)
        {
            Ok(file) => break file,
            Err(error)
                if error.raw_os_error() == Some(libc::ENXIO)
                    && Instant::now() < startup_deadline =>
            {
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("worker did not open its fixture: {error}"),
        }
    };
    assert_eq!(
        unsafe { libc::kill(cli.0.pid as libc::pid_t, libc::SIGSTOP) },
        0,
        "stop CLI before its normal reader timeout"
    );
    loop {
        let current = current_process(cli.0).expect("CLI exited before suspension");
        // Confirm suspension before the production 500 ms reader timeout can
        // kill the worker and hide a missing parent-death signal.
        assert!(
            Instant::now() < startup_deadline,
            "CLI was not suspended before its reader timeout"
        );
        if current.state == b'T' {
            break;
        }
        assert!(current.is_live(), "CLI exited before suspension");
        thread::sleep(Duration::from_millis(5));
    }
    let worker = DescendantGuard(
        wait_for_child(cli.0.pid, Instant::now() + Duration::from_secs(1))
            .expect("CLI did not spawn bounded reader worker"),
    );

    shell.0.kill().expect("kill calling shell");
    shell.0.wait().expect("reap calling shell");
    let exit_deadline = Instant::now() + Duration::from_secs(1);
    assert!(
        wait_until_exited(cli.0, exit_deadline),
        "CLI survived calling shell death: {:?}",
        current_process(cli.0)
    );
    assert!(
        wait_until_exited(worker.0, exit_deadline),
        "reader worker survived CLI death: {:?}",
        current_process(worker.0)
    );
    drop(fifo_writer);
    fs::remove_dir_all(root).expect("remove parent-death proc reader fixture");
}
