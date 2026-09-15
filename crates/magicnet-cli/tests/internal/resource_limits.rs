use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use super::{
    defer_reap, read_proc_file_bounded, reserve_child_probe, run_bounded_command, CommandPipe,
    DeferredReaper, CHILD_REAPER, MAX_CHILD_PROBES,
};

fn shell(script: &str) -> Command {
    let mut command = Command::new("sh");
    command.args(["-c", script]);
    command
}

// Run resource counts in a fresh test process: the normal parallel test
// harness legitimately creates threads/fds and would make them flaky.
fn isolated(name: &str) -> bool {
    if std::env::var("MAGICNET_RESOURCE_TEST_CHILD").as_deref() == Ok(name) {
        return false;
    }
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            &format!("utils::resource_tests::{name}"),
            "--nocapture",
        ])
        .env("MAGICNET_RESOURCE_TEST_CHILD", name)
        .stdin(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "isolated resource test failed: {name}");
            return true;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("isolated resource test hung: {name}");
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn proc_entries(path: &str) -> usize {
    fs::read_dir(path).unwrap().count()
}

#[test]
fn command_timeout_preserves_partial_output() {
    let started = Instant::now();
    let output = run_bounded_command(
        shell("printf partial; printf warning >&2; exec sleep 30"),
        Duration::from_millis(100),
        1024,
    )
    .unwrap();
    assert!(output.timed_out);
    assert!(output.stdout.starts_with(b"partial"));
    assert!(output.stderr.starts_with(b"warning"));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn output_overflow_is_drained_without_killing_successful_command() {
    let output = run_bounded_command(
        shell("i=0; while [ \"$i\" -lt 4096 ]; do printf 0123456789abcdef; printf fedcba9876543210 >&2; i=$((i + 1)); done"),
        Duration::from_secs(5),
        128,
    )
    .unwrap();
    assert!(!output.timed_out);
    assert!(output.status.unwrap().success());
    assert!(output.truncated);
    assert!(output.stdout.len() < 256);
    assert!(output.stderr.len() < 256);
    assert!(output.stdout.starts_with(b"0123456789abcdef"));
    assert!(output.stderr.starts_with(b"fedcba9876543210"));
}

#[test]
fn continuous_output_cannot_starve_command_deadline() {
    let started = Instant::now();
    let output = run_bounded_command(
        shell("while :; do printf 0123456789abcdef; printf fedcba9876543210 >&2; done"),
        Duration::from_millis(100),
        128,
    )
    .unwrap();
    assert!(output.timed_out);
    assert!(output.truncated);
    assert!(output.stdout.len() < 512);
    assert!(output.stderr.len() < 512);
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn held_open_pipe_is_closed_without_waiting_for_eof() {
    let (reader, mut writer) = UnixStream::pair().unwrap();
    writer.write_all(b"captured").unwrap();
    let mut capture = CommandPipe::new(reader, 128).unwrap();
    let started = Instant::now();
    capture.drain_ready(Instant::now() + Duration::from_secs(1));
    assert!(!capture.closed());
    let output = capture.finish("stdout");
    assert!(output.bytes.starts_with(b"captured"));
    assert!(output.truncated);
    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(writer.write_all(b"after close").is_err());
}

struct AlwaysReady {
    fd: UnixStream,
    reads: usize,
    interrupted: bool,
}

impl AsRawFd for AlwaysReady {
    fn as_raw_fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }
}

impl Read for AlwaysReady {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.reads += 1;
        if self.interrupted {
            Err(io::Error::from(io::ErrorKind::Interrupted))
        } else {
            bytes.fill(b'x');
            Ok(bytes.len())
        }
    }
}

#[test]
fn every_drain_has_a_finite_work_budget_even_on_eintr() {
    for interrupted in [false, true] {
        let (fd, _writer) = UnixStream::pair().unwrap();
        let mut capture = CommandPipe::new(
            AlwaysReady {
                fd,
                reads: 0,
                interrupted,
            },
            32,
        )
        .unwrap();
        capture.drain_ready(Instant::now() + Duration::from_secs(10));
        assert_eq!(capture.reader.as_ref().unwrap().reads, 16);
        assert!(capture.bytes.len() <= 32);
        assert_eq!(capture.truncated, !interrupted);
    }
}

#[test]
fn expired_drain_deadline_does_not_read() {
    let (fd, _writer) = UnixStream::pair().unwrap();
    let mut capture = CommandPipe::new(
        AlwaysReady {
            fd,
            reads: 0,
            interrupted: false,
        },
        32,
    )
    .unwrap();
    capture.drain_ready(Instant::now());
    assert_eq!(capture.reader.as_ref().unwrap().reads, 0);
}

#[test]
fn zero_command_timeout_does_not_spawn() {
    let error = run_bounded_command(shell("exit 0"), Duration::ZERO, 128)
        .err()
        .unwrap();
    assert!(error.contains("before spawn"));
}

#[test]
fn probe_budget_counts_active_and_unreaped_children() {
    let mut state = DeferredReaper::default();
    state.defer(42);
    state.defer(42);
    state.defer(0);
    state.defer(-1);
    assert_eq!(state.pending, vec![42]);
    for _ in 1..MAX_CHILD_PROBES {
        state.reserve().unwrap();
    }
    assert!(state.reserve().is_err());
    state.pending.clear();
    state.reserve().unwrap();
    assert!(state.reserve().is_err());
}

#[test]
fn repeated_timeouts_do_not_leave_threads_or_fds() {
    if isolated("repeated_timeouts_do_not_leave_threads_or_fds") {
        return;
    }
    let threads = proc_entries("/proc/self/task");
    let fds = proc_entries("/proc/self/fd");
    for _ in 0..12 {
        let output = run_bounded_command(
            shell("exec sleep 30"),
            Duration::from_millis(20),
            128,
        )
        .unwrap();
        assert!(output.timed_out);
    }
    assert!(proc_entries("/proc/self/task") <= threads + 1);
    assert_eq!(proc_entries("/proc/self/fd"), fds);
}

#[test]
fn deferred_children_share_one_reaper_without_stealing_other_statuses() {
    if isolated("deferred_children_share_one_reaper_without_stealing_other_statuses") {
        return;
    }
    let before = proc_entries("/proc/self/task");
    let mut child = shell("exec sleep 2").spawn().unwrap();
    let pid = child.id() as libc::pid_t;
    for _ in 0..32 {
        defer_reap(pid);
    }
    let after = proc_entries("/proc/self/task");
    let mut independent = shell("exit 7").spawn().unwrap();
    let independent_status = independent.wait().unwrap();
    let _ = child.kill();
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let queued = CHILD_REAPER.lock().unwrap().pending.contains(&pid);
        if !queued {
            break;
        }
        assert!(Instant::now() < deadline, "child was not reaped");
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(after, before + 1);
    assert_eq!(independent_status.code(), Some(7));
}

// This subprocess fixture intentionally leaves a short-lived, session-detached
// child holding both inherited output pipes. Ordinary tests never enter it.
#[test]
fn escaped_pipe_holder_fixture() {
    use std::os::unix::process::CommandExt;

    let Ok(pid_file) = std::env::var("MAGICNET_ESCAPED_PIPE_PID") else {
        return;
    };
    let mut command = Command::new("sleep");
    command.arg("5").stdin(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let child = command.spawn().unwrap();
    fs::write(pid_file, child.id().to_string()).unwrap();
}

struct EscapedFixtures {
    directory: std::path::PathBuf,
}

impl Drop for EscapedFixtures {
    fn drop(&mut self) {
        // Only PIDs created by this test's fixtures are signalled. Each child
        // also exits after five seconds if a regression interrupts cleanup.
        if let Ok(entries) = fs::read_dir(&self.directory) {
            for entry in entries.flatten() {
                if let Ok(text) = fs::read_to_string(entry.path()) {
                    if let Ok(pid) = text.parse::<libc::pid_t>() {
                        if pid > 1 {
                            unsafe { libc::kill(pid, libc::SIGKILL) };
                        }
                    }
                }
            }
        }
        let _ = fs::remove_dir_all(&self.directory);
    }
}

#[test]
fn escaped_pipe_holders_do_not_accumulate_reader_threads() {
    if isolated("escaped_pipe_holders_do_not_accumulate_reader_threads") {
        return;
    }
    let directory = std::env::temp_dir().join(format!(
        "magicnet-escaped-pipe-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&directory).unwrap();
    let fixtures = EscapedFixtures { directory };
    let before_threads = proc_entries("/proc/self/task");
    let before_fds = proc_entries("/proc/self/fd");
    for index in 0..4 {
        let pid_file = fixtures.directory.join(index.to_string());
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "utils::resource_tests::escaped_pipe_holder_fixture",
                "--nocapture",
            ])
            .env("MAGICNET_ESCAPED_PIPE_PID", &pid_file);
        let started = Instant::now();
        let output = run_bounded_command(command, Duration::from_millis(250), 1024).unwrap();
        assert!(output.timed_out);
        assert!(output.truncated);
        assert!(pid_file.is_file(), "escaped child fixture did not start");
        assert!(started.elapsed() < Duration::from_secs(3));
    }
    assert!(proc_entries("/proc/self/task") <= before_threads + 1);
    assert_eq!(proc_entries("/proc/self/fd"), before_fds);
}

#[test]
fn exhausted_probe_budget_rejects_work_before_spawn() {
    if isolated("exhausted_probe_budget_rejects_work_before_spawn") {
        return;
    }
    let mut permits = Vec::new();
    for _ in 0..MAX_CHILD_PROBES {
        permits.push(reserve_child_probe().unwrap());
    }
    let error = run_bounded_command(shell("exit 0"), Duration::from_secs(1), 128)
        .err()
        .unwrap();
    assert!(error.contains("budget exhausted"));
    let error = read_proc_file_bounded(std::path::Path::new("/proc/self/status"), 4096)
        .unwrap_err();
    assert!(error.contains("budget exhausted"));
    drop(permits);
    let output = run_bounded_command(shell("exit 0"), Duration::from_secs(1), 128).unwrap();
    assert!(output.status.unwrap().success());
}
