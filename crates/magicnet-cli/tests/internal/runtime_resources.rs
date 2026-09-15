use super::{run_bounded_command, PipeCapture};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::process::Command;
use std::time::{Duration, Instant};

#[test]
fn idle_pipe_is_nonblocking_and_drop_closes_the_reader() {
    let (reader, mut writer) = UnixStream::pair().unwrap();
    let mut capture = PipeCapture::new(reader, 16).unwrap();
    capture.drain().unwrap();
    assert!(!capture.eof);
    writer.write_all(b"prefix").unwrap();
    capture.drain().unwrap();
    assert_eq!(capture.bytes, b"prefix");
    drop(capture);
    assert!(writer.write_all(b"closed").is_err());
}

#[test]
fn both_output_streams_are_drained_and_bounded() {
    let mut command = Command::new("sh");
    command.args(["-c", "head -c 65536 /dev/zero; head -c 65536 /dev/zero >&2"]);
    let output = run_bounded_command(command, Duration::from_secs(3), 128).unwrap();
    assert!(!output.timed_out);
    assert!(output.status.unwrap().success());
    assert!(output.truncated);
    for stream in [&output.stdout, &output.stderr] {
        assert_eq!(&stream[..128], &[0; 128]);
        assert_eq!(&stream[128..], b"\n[output truncated]");
    }
}

#[test]
fn a_flooding_child_cannot_starve_the_timeout() {
    let mut command = Command::new("sh");
    command.args(["-c", "exec cat /dev/zero"]);
    let started = Instant::now();
    let output = run_bounded_command(command, Duration::from_millis(100), 64).unwrap();
    assert!(output.timed_out);
    assert!(output.truncated);
    assert!(output.stdout.len() <= 64 + b"\n[output truncated]".len());
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn escaped_pipe_holder_cannot_retain_a_reader_after_timeout() {
    for _ in 0..3 {
        let mut command = Command::new("sh");
        // The finite-lived descendant deliberately escapes the group
        // while retaining stdout/stderr. No reader thread may wait on it.
        command.args(["-c", "printf ready; setsid sh -c 'sleep 0.5' &"]);
        let started = Instant::now();
        let output = run_bounded_command(command, Duration::from_millis(80), 128).unwrap();
        assert!(output.timed_out);
        assert!(output.stdout.starts_with(b"ready"));
        assert!(started.elapsed() < Duration::from_millis(450));
    }
}

fn shell(script: &str) -> Command {
    let mut command = Command::new("sh");
    command.args(["-c", script]);
    command
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
fn zero_command_timeout_does_not_spawn() {
    let error = run_bounded_command(shell("exit 0"), Duration::ZERO, 128)
        .err()
        .unwrap();
    assert!(error.contains("before spawn"));
}

#[test]
fn interrupted_capture_yields_to_the_deadline() {
    struct Interrupted(std::os::unix::net::UnixStream, usize);
    impl std::os::fd::AsRawFd for Interrupted {
        fn as_raw_fd(&self) -> std::os::fd::RawFd {
            std::os::fd::AsRawFd::as_raw_fd(&self.0)
        }
    }
    impl std::io::Read for Interrupted {
        fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
            self.1 += 1;
            Err(std::io::ErrorKind::Interrupted.into())
        }
    }
    let (reader, _writer) = UnixStream::pair().unwrap();
    let mut capture = PipeCapture::new(Interrupted(reader, 0), 32).unwrap();
    capture.drain().unwrap();
    assert_eq!(capture.reader.1, 1);
    assert!(capture.bytes.is_empty());
    assert!(!capture.eof);
}
