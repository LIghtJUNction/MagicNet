//! Bounded execution of short-lived, explicitly selected tools. This runner
//! never invokes a shell or searches an inherited PATH. Dataplane processes
//! have a separate ownership-aware lifecycle and are not force-killed here.

use crate::{Error, Result};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub struct Spec {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub input: Vec<u8>,
    pub timeout: Duration,
    pub output_limit: usize,
    pub env: BTreeMap<String, String>,
    pub directory: Option<PathBuf>,
}

impl Spec {
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            input: Vec::new(),
            timeout: Duration::from_secs(10),
            output_limit: 1024 * 1024,
            env: BTreeMap::new(),
            directory: None,
        }
    }
    pub fn args(mut self, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.args = args.into_iter().map(Into::into).collect();
        self
    }
}

#[derive(Debug)]
pub struct Output {
    pub code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

fn nonblocking(fd: i32) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(Error::os("Configure bounded process pipe"));
    }
    Ok(())
}

fn drain(reader: &mut impl Read, output: &mut Vec<u8>, limit: usize) -> Result<bool> {
    let mut buffer = [0_u8; 8192];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return Ok(true),
            Ok(n) => {
                if output.len().saturating_add(n) > limit {
                    return Err(Error::new(
                        "output_limit",
                        "The tool produced more output than permitted",
                    ));
                }
                output.extend_from_slice(&buffer[..n]);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(false),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(Error::io("Read bounded process pipe", error)),
        }
    }
}

fn terminate(child: &mut std::process::Child) {
    // The child created its own session before exec. Its unreaped PID remains
    // allocated, so this process-group signal cannot hit a reused group ID.
    let group = -(child.id() as i32);
    unsafe {
        libc::kill(group, libc::SIGTERM);
    }
    // Do not reap the group leader until the last group signal. An exited
    // child remains a zombie and pins its PID, preventing group-ID reuse.
    std::thread::sleep(Duration::from_millis(100));
    unsafe {
        libc::kill(group, libc::SIGKILL);
    }
    let _ = child.wait();
}

pub fn execute(spec: &Spec) -> Result<Output> {
    execute_cancelable(spec, || false)
}

pub fn execute_cancelable(spec: &Spec, cancelled: impl Fn() -> bool) -> Result<Output> {
    if !spec.program.is_absolute()
        || spec.timeout.is_zero()
        || spec.timeout > Duration::from_secs(300)
        || spec.output_limit == 0
        || spec.output_limit > 16 * 1024 * 1024
        || spec.input.len() > 8 * 1024 * 1024
    {
        return Err(Error::new(
            "invalid_execution",
            "The tool path or execution bounds are invalid",
        ));
    }
    let mut command = Command::new(&spec.program);
    command
        .args(&spec.args)
        .env_clear()
        .env("PATH", "/system/bin:/system/xbin:/usr/bin:/bin")
        .env("LANG", "C")
        .env("LC_ALL", "C")
        .envs(&spec.env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(directory) = &spec.directory {
        command.current_dir(directory);
    }
    // SAFETY: pre_exec uses only async-signal-safe syscalls and allocates no
    // memory. This applies only to disposable tools, never sing-box run.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            libc::umask(0o077);
            Ok(())
        });
    }
    let mut child = command
        .spawn()
        .map_err(|e| Error::io("Launch trusted tool", e))?;
    let result = (|| {
        let input = child
            .stdin
            .take()
            .ok_or_else(|| Error::new("pipe_unavailable", "The tool input pipe is unavailable"))?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| Error::new("pipe_unavailable", "The tool output pipe is unavailable"))?;
        let mut stderr = child
            .stderr
            .take()
            .ok_or_else(|| Error::new("pipe_unavailable", "The tool error pipe is unavailable"))?;
        nonblocking(input.as_raw_fd())?;
        nonblocking(stdout.as_raw_fd())?;
        nonblocking(stderr.as_raw_fd())?;
        let mut input_position = 0;
        let mut input = Some(input);
        let mut out = Vec::new();
        let mut err = Vec::new();
        let mut stdout_done = false;
        let mut stderr_done = false;
        let deadline = Instant::now() + spec.timeout;
        loop {
            if cancelled() {
                return Err(
                    Error::new("cancelled", "The operation was superseded or cancelled").retry(),
                );
            }
            if Instant::now() >= deadline {
                return Err(
                    Error::new("timeout", "The tool did not finish before its deadline").retry(),
                );
            }
            let mut close_input = input_position == spec.input.len();
            if let Some(writer) = input.as_mut() {
                if !close_input {
                    match writer.write(&spec.input[input_position..]) {
                        Ok(0) => {
                            return Err(Error::new(
                                "input_closed",
                                "The tool stopped accepting input",
                            ))
                        }
                        Ok(n) => {
                            input_position += n;
                            close_input = input_position == spec.input.len();
                        }
                        Err(error)
                            if matches!(
                                error.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                            ) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => {
                            close_input = true
                        }
                        Err(error) => return Err(Error::io("Write tool input", error)),
                    }
                }
            }
            // Dropping the owned ChildStdin sends EOF. shutdown(2) only works
            // on sockets, not pipes, and dropping a reference closes nothing.
            if close_input {
                drop(input.take());
            }
            if !stdout_done {
                stdout_done = drain(&mut stdout, &mut out, spec.output_limit)?;
            }
            if !stderr_done {
                stderr_done = drain(&mut stderr, &mut err, spec.output_limit.min(64 * 1024))?;
            }
            // Do not reap while descendants might still hold a pipe. A
            // timeout can then safely signal the original, still-pinned group.
            if stdout_done && stderr_done {
                if let Some(status) = child
                    .try_wait()
                    .map_err(|e| Error::io("Observe trusted tool", e))?
                {
                    return Ok(Output {
                        code: status.code().unwrap_or(128),
                        stdout: out,
                        stderr: err,
                    });
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    })();
    if result.is_err() {
        terminate(&mut child);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sends_eof_and_does_not_deadlock_full_pipes() {
        let mut spec = Spec::new("/bin/cat");
        spec.input = vec![b'a'; 256 * 1024];
        let out = execute(&spec).unwrap();
        assert_eq!(out.code, 0);
        assert_eq!(out.stdout, spec.input);
    }
    #[test]
    fn empty_stdin_is_closed() {
        assert!(execute(&Spec::new("/bin/cat")).unwrap().stdout.is_empty());
    }
    #[test]
    fn timeout_cancel_and_output_limits_are_errors() {
        let mut spec = Spec::new("/bin/sleep").args(["5"]);
        spec.timeout = Duration::from_millis(30);
        assert_eq!(execute(&spec).unwrap_err().code, "timeout");
        assert_eq!(
            execute_cancelable(&spec, || true).unwrap_err().code,
            "cancelled"
        );
        spec = Spec::new("/usr/bin/yes");
        spec.output_limit = 100;
        assert_eq!(execute(&spec).unwrap_err().code, "output_limit");
    }
    #[test]
    fn rejects_relative_program_and_unbounded_limits() {
        assert_eq!(
            execute(&Spec::new("cat")).unwrap_err().code,
            "invalid_execution"
        );
    }
}
