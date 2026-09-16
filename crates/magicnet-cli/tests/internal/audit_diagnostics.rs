use super::{read_only_command_result_with_timeout, running};
use crate::test_support::temp_app;
use std::time::{Duration, Instant};

#[test]
fn diagnostic_capture_drains_after_its_retention_limit() {
    let app = temp_app();
    let marker = app.moddir.join("drained");
    let result = read_only_command_result_with_timeout(
        "sh",
        &["-ec", "i=0; while [ $i -lt 10000 ]; do printf '012345678901234567890123456789\n'; i=$((i+1)); done; printf done > \"$1\"", "audit", marker.to_str().unwrap()],
        Duration::from_secs(5),
    );
    assert!(
        marker.is_file(),
        "capture closed early and killed the producer: {result:?}"
    );
    assert!(result.text.len() < 1000, "display output was not bounded");
    assert!(!result.success, "truncated diagnostics cannot prove health");
}

#[test]
fn diagnostic_deadline_includes_escaped_pipe_holders() {
    let app = temp_app();
    let marker = app.moddir.join("ready");
    let started = Instant::now();
    let result = read_only_command_result_with_timeout(
        "sh",
        &["-c", "setsid sh -c 'echo ready > \"$1\"; sleep 2' audit \"$1\" & while [ ! -s \"$1\" ]; do sleep 0.01; done", "audit", marker.to_str().unwrap()],
        Duration::from_millis(300),
    );
    assert!(
        started.elapsed() < Duration::from_millis(1500),
        "read join escaped the deadline"
    );
    assert!(!result.success);
    assert!(result.text.contains("timeout"), "{result:?}");
}

#[test]
fn unavailable_processes_are_not_healthy() {
    for value in [
        "",
        "unknown",
        "stopped",
        "0",
        "-1",
        "123,",
        "1,unknown",
        "4294967296",
    ] {
        assert!(!running(value), "{value:?} is not a verified process list");
    }
    assert!(running("123"));
    assert!(running("123,456"));
}

#[test]
fn diagnostic_capture_retains_stderr_and_nonzero_exit() {
    let result = read_only_command_result_with_timeout(
        "sh",
        &["-c", "printf out; printf err >&2; exit 7"],
        Duration::from_secs(1),
    );
    assert!(!result.success);
    assert!(result.text.contains("out") && result.text.contains("err"));
}
