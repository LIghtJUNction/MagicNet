use super::{run_cli_with_timeout, Server};
use crate::test_support::temp_app;
use std::path::PathBuf;
use std::time::{Duration, Instant};

#[test]
fn mcp_deadline_includes_escaped_pipe_holders() {
    let app = temp_app();
    let marker = app.moddir.join("ready");
    let server = Server {
        cli: PathBuf::from("/bin/sh"),
        moddir: app.moddir.clone(),
        secret: String::new(),
    };
    let started = Instant::now();
    let output = run_cli_with_timeout(
        &server,
        &["-c", "setsid sh -c 'echo ready > \"$1\"; sleep 2' audit \"$1\" & while [ ! -s \"$1\" ]; do sleep 0.01; done", "audit", marker.to_str().unwrap()],
        Duration::from_millis(300),
    );
    assert!(
        started.elapsed() < Duration::from_millis(1500),
        "MCP stream wait escaped its deadline"
    );
    assert!(output.ends_with("rc=124"), "{output}");
}

#[test]
fn mcp_continuous_output_remains_bounded_and_times_out() {
    let app = temp_app();
    let server = Server {
        cli: PathBuf::from("/bin/sh"),
        moddir: app.moddir.clone(),
        secret: String::new(),
    };
    let output = run_cli_with_timeout(
        &server,
        &[
            "-c",
            "while :; do printf '012345678901234567890123456789\n'; done",
        ],
        Duration::from_millis(100),
    );
    assert!(output.ends_with("rc=124"), "timeout did not propagate");
    assert!(
        output.len() <= 1024 * 1024 + 256,
        "unbounded retained output"
    );
}
