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
