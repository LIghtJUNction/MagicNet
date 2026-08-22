use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};

fn cli() -> Command {
    Command::new(env!("CARGO_BIN_EXE_magicnet-cli"))
}

fn closed_pipe() -> Stdio {
    let (reader, writer) = UnixStream::pair().expect("create closed output pipe");
    drop(reader);
    let writer: OwnedFd = writer.into();
    Stdio::from(writer)
}

#[test]
fn closed_stdout_does_not_abort_help() {
    let mut child = cli()
        .stdout(closed_pipe())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn CLI help");
    let status = child.wait().expect("wait for CLI help");
    assert!(
        status.success(),
        "CLI help aborted after stdout closed: {status}"
    );
}

#[test]
fn closed_stderr_preserves_command_error_status() {
    let mut child = cli()
        .arg("definitely-unknown-command")
        .stdout(Stdio::null())
        .stderr(closed_pipe())
        .spawn()
        .expect("spawn failing CLI command");
    let status = child.wait().expect("wait for failing CLI command");
    assert_eq!(status.code(), Some(1), "CLI error path aborted: {status}");
}
