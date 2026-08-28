use std::ffi::{CString, OsStr, OsString};
use std::fs::{self, File};
use std::io::{self, ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use crate::App;

const MAX_COMMAND_STREAM_BYTES: usize = 1024 * 1024;
pub(crate) const MAX_PROC_CMDLINE_BYTES: usize = 64 * 1024;
pub(crate) const MAX_PROC_STAT_BYTES: usize = 4 * 1024;
pub(crate) const MAX_PROC_COMM_BYTES: usize = 256;
const MAX_PROC_FILE_BYTES: usize = MAX_PROC_CMDLINE_BYTES;
const PROC_FILE_READ_TIMEOUT: Duration = Duration::from_millis(500);
const PROC_READER_OVERSIZE_EXIT: i32 = 65;
const PROC_READER_IO_EXIT: i32 = 66;
const PROC_READER_PARENT_EXIT: i32 = 67;
const PROCESS_REAP_GRACE: Duration = Duration::from_millis(100);
const PROCESS_REAP_POLL: Duration = Duration::from_millis(10);

fn close_raw_fd(fd: RawFd) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
    }
}

#[cfg(target_os = "android")]
fn child_errno() -> libc::c_int {
    unsafe { *libc::__errno() }
}

#[cfg(not(target_os = "android"))]
fn child_errno() -> libc::c_int {
    unsafe { *libc::__errno_location() }
}

trait KillAndWait {
    fn kill(&mut self);
    fn try_reap(&mut self) -> Result<bool, io::Error>;
}

struct LibcKillAndWait {
    pid: libc::pid_t,
}

impl KillAndWait for LibcKillAndWait {
    fn kill(&mut self) {
        unsafe {
            libc::kill(self.pid, libc::SIGKILL);
        }
    }

    fn try_reap(&mut self) -> Result<bool, io::Error> {
        loop {
            let mut status = 0;
            let result = unsafe { libc::waitpid(self.pid, &mut status, libc::WNOHANG) };
            if result == self.pid {
                return Ok(true);
            }
            if result == 0 {
                return Ok(false);
            }
            let err = io::Error::last_os_error();
            if err.kind() == ErrorKind::Interrupted {
                continue;
            }
            // ECHILD means another reaper already collected it.
            return if err.raw_os_error() == Some(libc::ECHILD) {
                Ok(true)
            } else {
                Err(err)
            };
        }
    }
}

fn kill_and_reap_with<W: KillAndWait>(waiter: &mut W, grace: Duration) -> bool {
    waiter.kill();
    let deadline = Instant::now() + grace;
    loop {
        match waiter.try_reap() {
            Ok(true) => return true,
            Err(_) => return false,
            Ok(false) if Instant::now() >= deadline => return false,
            Ok(false) => thread::sleep(PROCESS_REAP_POLL),
        }
    }
}

fn defer_reap(pid: libc::pid_t) {
    // Never put an unbounded wait on a deadline-bearing API path. A single
    // detached poller eventually collects the child if a kernel-side D state
    // clears; process exit safely reparents it otherwise.
    let _ = thread::Builder::new()
        .name("magicnet-child-reaper".to_string())
        .spawn(move || {
            let mut waiter = LibcKillAndWait { pid };
            loop {
                match waiter.try_reap() {
                    Ok(true) | Err(_) => break,
                    Ok(false) => thread::sleep(Duration::from_millis(250)),
                }
            }
        });
}

pub(crate) fn kill_and_reap(pid: libc::pid_t) {
    let mut waiter = LibcKillAndWait { pid };
    if !kill_and_reap_with(&mut waiter, PROCESS_REAP_GRACE) {
        defer_reap(pid);
    }
}

fn child_exit_code(status: i32) -> Option<i32> {
    if libc::WIFEXITED(status) {
        Some(libc::WEXITSTATUS(status))
    } else {
        None
    }
}

/// Read a proc-style pseudo-file with both a byte ceiling and a monotonic
/// deadline. The actual open/read runs in a short-lived child so a wedged OEM
/// proc handler can always be killed and reaped. PR_SET_PDEATHSIG prevents the
/// worker from surviving if its caller is interrupted.
pub(crate) fn read_proc_file_bounded(path: &Path, max_bytes: usize) -> Result<Vec<u8>, String> {
    read_proc_file_bounded_with_timeout(path, max_bytes, PROC_FILE_READ_TIMEOUT)
}

pub(crate) fn read_proc_file_bounded_with_timeout(
    path: &Path,
    max_bytes: usize,
    timeout: Duration,
) -> Result<Vec<u8>, String> {
    if max_bytes == 0 || max_bytes > MAX_PROC_FILE_BYTES {
        return Err(format!(
            "invalid proc read limit {max_bytes}; expected 1..={MAX_PROC_FILE_BYTES}"
        ));
    }
    if timeout.is_zero() {
        return Err(format!("proc read deadline expired: {}", path.display()));
    }
    let path_c = cstring_from_os_str(path.as_os_str(), "proc path")?;
    let mut pipe_fds = [-1; 2];
    if unsafe { libc::pipe2(pipe_fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(format!(
            "create bounded proc reader pipe for {}: {}",
            path.display(),
            io::Error::last_os_error()
        ));
    }

    let mut worker_buffer = vec![0_u8; max_bytes + 1];
    let parent_pid = unsafe { libc::getpid() };
    let worker_pid = unsafe { libc::fork() };
    if worker_pid < 0 {
        let err = io::Error::last_os_error();
        close_raw_fd(pipe_fds[0]);
        close_raw_fd(pipe_fds[1]);
        return Err(format!(
            "fork bounded proc reader for {}: {err}",
            path.display()
        ));
    }

    if worker_pid == 0 {
        close_raw_fd(pipe_fds[0]);
        let armed = unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) } == 0;
        if !armed || unsafe { libc::getppid() } != parent_pid {
            unsafe { libc::_exit(PROC_READER_PARENT_EXIT) };
        }
        let source_fd = unsafe {
            libc::open(
                path_c.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        if source_fd < 0 {
            unsafe { libc::_exit(PROC_READER_IO_EXIT) };
        }

        let mut read_len = 0_usize;
        while read_len < worker_buffer.len() {
            let result = unsafe {
                libc::read(
                    source_fd,
                    worker_buffer.as_mut_ptr().add(read_len).cast(),
                    worker_buffer.len() - read_len,
                )
            };
            if result > 0 {
                read_len += result as usize;
                continue;
            }
            if result == 0 {
                break;
            }
            if child_errno() == libc::EINTR {
                continue;
            }
            close_raw_fd(source_fd);
            unsafe { libc::_exit(PROC_READER_IO_EXIT) };
        }
        close_raw_fd(source_fd);
        if read_len > max_bytes {
            unsafe { libc::_exit(PROC_READER_OVERSIZE_EXIT) };
        }

        let mut written = 0_usize;
        while written < read_len {
            let result = unsafe {
                libc::write(
                    pipe_fds[1],
                    worker_buffer.as_ptr().add(written).cast(),
                    read_len - written,
                )
            };
            if result > 0 {
                written += result as usize;
                continue;
            }
            if result < 0 && child_errno() == libc::EINTR {
                continue;
            }
            close_raw_fd(pipe_fds[1]);
            unsafe { libc::_exit(PROC_READER_IO_EXIT) };
        }
        close_raw_fd(pipe_fds[1]);
        unsafe { libc::_exit(0) };
    }

    close_raw_fd(pipe_fds[1]);
    let flags = unsafe { libc::fcntl(pipe_fds[0], libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(pipe_fds[0], libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        let err = io::Error::last_os_error();
        close_raw_fd(pipe_fds[0]);
        kill_and_reap(worker_pid);
        return Err(format!(
            "configure bounded proc reader for {}: {err}",
            path.display()
        ));
    }

    let deadline = Instant::now() + timeout;
    let mut output = Vec::with_capacity(max_bytes.min(4096));
    let mut pipe_eof = false;
    let mut worker_status = None;
    loop {
        let mut chunk = [0_u8; 4096];
        loop {
            let read_count =
                unsafe { libc::read(pipe_fds[0], chunk.as_mut_ptr().cast(), chunk.len()) };
            if read_count > 0 {
                output.extend_from_slice(&chunk[..read_count as usize]);
                if output.len() > max_bytes {
                    close_raw_fd(pipe_fds[0]);
                    kill_and_reap(worker_pid);
                    return Err(format!(
                        "proc file exceeds {max_bytes} bytes: {}",
                        path.display()
                    ));
                }
                continue;
            }
            if read_count == 0 {
                pipe_eof = true;
                break;
            }
            let err = io::Error::last_os_error();
            if err.kind() == ErrorKind::Interrupted {
                continue;
            }
            if err.kind() == ErrorKind::WouldBlock {
                break;
            }
            close_raw_fd(pipe_fds[0]);
            kill_and_reap(worker_pid);
            return Err(format!(
                "read bounded proc result for {}: {err}",
                path.display()
            ));
        }

        if worker_status.is_none() {
            let mut status = 0;
            let waited = unsafe { libc::waitpid(worker_pid, &mut status, libc::WNOHANG) };
            if waited == worker_pid {
                worker_status = Some(status);
            } else if waited < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == ErrorKind::Interrupted {
                    continue;
                }
                close_raw_fd(pipe_fds[0]);
                return Err(format!(
                    "reap bounded proc reader for {}: {err}",
                    path.display()
                ));
            }
        }
        if pipe_eof && worker_status.is_some() {
            break;
        }
        if Instant::now() >= deadline {
            close_raw_fd(pipe_fds[0]);
            kill_and_reap(worker_pid);
            return Err(format!(
                "proc read timed out after {}ms: {}",
                timeout.as_millis(),
                path.display()
            ));
        }

        let remaining = deadline.saturating_duration_since(Instant::now());
        let wait_ms = remaining.as_millis().clamp(1, 25) as i32;
        let mut poll_fd = libc::pollfd {
            fd: pipe_fds[0],
            events: libc::POLLIN | libc::POLLHUP,
            revents: 0,
        };
        let polled = unsafe { libc::poll(&mut poll_fd, 1, wait_ms) };
        if polled < 0 && io::Error::last_os_error().kind() != ErrorKind::Interrupted {
            let err = io::Error::last_os_error();
            close_raw_fd(pipe_fds[0]);
            kill_and_reap(worker_pid);
            return Err(format!(
                "poll bounded proc reader for {}: {err}",
                path.display()
            ));
        }
    }
    close_raw_fd(pipe_fds[0]);

    match worker_status.and_then(child_exit_code) {
        Some(0) => Ok(output),
        Some(PROC_READER_OVERSIZE_EXIT) => Err(format!(
            "proc file exceeds {max_bytes} bytes: {}",
            path.display()
        )),
        Some(PROC_READER_IO_EXIT) => Err(format!("proc file read failed: {}", path.display())),
        Some(PROC_READER_PARENT_EXIT) => Err(format!(
            "proc reader parent changed before startup: {}",
            path.display()
        )),
        Some(code) => Err(format!(
            "proc reader exited with status {code}: {}",
            path.display()
        )),
        None => Err(format!("proc reader was terminated: {}", path.display())),
    }
}

pub(crate) fn read_proc_text_bounded(path: &Path, max_bytes: usize) -> Result<String, String> {
    String::from_utf8(read_proc_file_bounded(path, max_bytes)?)
        .map_err(|_| format!("proc file is not UTF-8: {}", path.display()))
}

pub(crate) fn read_proc_argv(path: &Path) -> Result<Vec<String>, String> {
    let bytes = read_proc_file_bounded(path, MAX_PROC_CMDLINE_BYTES)?;
    parse_proc_argv(path, &bytes)
}

pub(crate) fn read_proc_argv_with_timeout(
    path: &Path,
    timeout: Duration,
) -> Result<Vec<String>, String> {
    let bytes = read_proc_file_bounded_with_timeout(path, MAX_PROC_CMDLINE_BYTES, timeout)?;
    // Kernel threads legitimately expose an empty cmdline and cannot match a
    // userspace script. An all-NUL buffer is the same non-match: some Android
    // processes zero the entire argv area. The bounded all-/proc scanner
    // treats both as a definite skip; exact ownership reads remain strict.
    if bytes.is_empty() || bytes.iter().all(|byte| *byte == 0) {
        return Ok(Vec::new());
    }
    parse_proc_argv(path, &bytes)
}

fn parse_proc_argv(path: &Path, bytes: &[u8]) -> Result<Vec<String>, String> {
    if bytes.is_empty() || bytes.last() != Some(&0) {
        return Err(format!(
            "proc cmdline is empty or unterminated: {}",
            path.display()
        ));
    }
    // Android apps may rewrite argv[0] and leave extra NUL padding after the
    // logical terminator. Keep one terminator and reject empty arguments
    // that appear before that logical end.
    let Some(last_non_nul) = bytes.iter().rposition(|byte| *byte != 0) else {
        return Err(format!("proc cmdline has no arguments: {}", path.display()));
    };
    let logical = &bytes[..=last_non_nul + 1];
    let mut argv = Vec::new();
    for argument in logical[..logical.len() - 1].split(|byte| *byte == 0) {
        if argument.is_empty() || argument.contains(&b'\n') || argument.contains(&b'\r') {
            return Err(format!(
                "proc cmdline contains an invalid argument: {}",
                path.display()
            ));
        }
        argv.push(
            String::from_utf8(argument.to_vec())
                .map_err(|_| format!("proc cmdline is not UTF-8: {}", path.display()))?,
        );
    }
    if argv.is_empty() {
        return Err(format!("proc cmdline has no arguments: {}", path.display()));
    }
    Ok(argv)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn arm_parent_death_signal() -> Result<(), String> {
    let parent = unsafe { libc::getppid() };
    if parent <= 1 || unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) } != 0 {
        return Err(format!(
            "arm proc reader parent-death signal: {}",
            io::Error::last_os_error()
        ));
    }
    if unsafe { libc::getppid() } != parent {
        return Err("proc reader parent exited during startup".to_string());
    }
    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub(crate) fn arm_parent_death_signal() -> Result<(), String> {
    Ok(())
}

fn internal_proc_path(args: &[String], file_name: &str) -> Result<PathBuf, String> {
    if args.len() != 2 {
        return Err("internal proc reader usage error".to_string());
    }
    let root = Path::new(&args[0]);
    if !root.is_absolute()
        || root
            .components()
            .any(|component| matches!(component, Component::ParentDir))
    {
        return Err("invalid proc root".to_string());
    }
    let pid = args[1]
        .parse::<u32>()
        .ok()
        .filter(|pid| *pid > 0)
        .ok_or_else(|| "invalid proc PID".to_string())?;
    Ok(root.join(pid.to_string()).join(file_name))
}

pub(crate) fn proc_cmdline_command(args: &[String]) -> Result<(), String> {
    arm_parent_death_signal()?;
    let path = internal_proc_path(args, "cmdline")?;
    let argv = read_proc_argv(&path)?;
    let mut stdout = io::stdout().lock();
    for argument in argv {
        stdout
            .write_all(argument.as_bytes())
            .and_then(|_| stdout.write_all(b"\n"))
            .map_err(|err| format!("write bounded proc cmdline: {err}"))?;
    }
    Ok(())
}

pub(crate) fn proc_comm_command(args: &[String]) -> Result<(), String> {
    arm_parent_death_signal()?;
    let path = internal_proc_path(args, "comm")?;
    let comm = read_proc_text_bounded(&path, MAX_PROC_COMM_BYTES)?;
    let comm = comm.trim_end_matches(['\r', '\n']);
    if comm.is_empty() || comm.contains(['\r', '\n']) {
        return Err(format!("invalid proc comm: {}", path.display()));
    }
    let mut stdout = io::stdout().lock();
    stdout
        .write_all(comm.as_bytes())
        .and_then(|_| stdout.write_all(b"\n"))
        .map_err(|err| format!("write bounded proc comm: {err}"))
}

pub(crate) fn proc_stat_command(args: &[String]) -> Result<(), String> {
    arm_parent_death_signal()?;
    let path = internal_proc_path(args, "stat")?;
    let stat = read_proc_text_bounded(&path, MAX_PROC_STAT_BYTES)?;
    let close = stat
        .rfind(')')
        .ok_or_else(|| format!("malformed proc stat: {}", path.display()))?;
    let state = stat[close + 1..]
        .split_whitespace()
        .next()
        .filter(|value| value.len() == 1)
        .ok_or_else(|| format!("missing proc state: {}", path.display()))?;
    let start = proc_start_time(&stat)
        .ok_or_else(|| format!("missing proc starttime: {}", path.display()))?;
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{state} {start}").map_err(|err| format!("write bounded proc stat: {err}"))
}

pub(crate) fn command_text_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    compact_command_output(&command_text_full_timeout(program, args, timeout))
}

pub(crate) fn command_text_full_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    let mut command = Command::new(program);
    command.args(args);
    match run_bounded_command(command, timeout, MAX_COMMAND_STREAM_BYTES) {
        Ok(output) if output.timed_out => format!("timeout after {}ms", timeout.as_millis()),
        Ok(output) => merge_command_output(&output.stdout, &output.stderr),
        Err(err) => format!("{program} not available: {err}"),
    }
}

pub(crate) struct BoundedCommandOutput {
    pub(crate) status: Option<ExitStatus>,
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
    pub(crate) timed_out: bool,
    pub(crate) truncated: bool,
}

pub(crate) fn run_bounded_command(
    mut command: Command,
    timeout: Duration,
    stream_limit: usize,
) -> Result<BoundedCommandOutput, String> {
    // Isolate the command so timeout cleanup also reaches shell helpers and
    // grandchildren that inherited the captured pipes. The direct child also
    // dies with this CLI if an outer app/su timeout interrupts its parent.
    let parent_pid = unsafe { libc::getpid() };
    unsafe {
        command.pre_exec(move || {
            #[cfg(any(target_os = "linux", target_os = "android"))]
            {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0
                    || libc::getppid() != parent_pid
                {
                    return Err(io::Error::last_os_error());
                }
            }
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        });
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| err.to_string())?;
    let stdout = child
        .stdout
        .take()
        .map(|stream| spawn_output_reader(stream, stream_limit));
    let stderr = child
        .stderr
        .take()
        .map(|stream| spawn_output_reader(stream, stream_limit));
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let mut status = None;
    let mut stdout_result = None;
    let mut stderr_result = None;
    loop {
        if status.is_none() {
            match child.try_wait() {
                Ok(Some(exit)) => status = Some(exit),
                Ok(None) => {}
                Err(err) => {
                    let _ = terminate_command_group(&mut child);
                    return Err(format!("wait failed: {err}"));
                }
            }
        }
        try_receive_output(&stdout, &mut stdout_result);
        try_receive_output(&stderr, &mut stderr_result);
        if status.is_some() && stdout_result.is_some() && stderr_result.is_some() {
            break;
        }
        if Instant::now() >= deadline {
            timed_out = true;
            status = terminate_command_group(&mut child).or(status);
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    let stdout = finish_output(stdout, stdout_result, "stdout");
    let stderr = finish_output(stderr, stderr_result, "stderr");
    Ok(BoundedCommandOutput {
        status,
        stdout: stdout.bytes,
        stderr: stderr.bytes,
        timed_out,
        truncated: stdout.truncated || stderr.truncated,
    })
}

trait CommandGroupWait {
    fn signal_group(&mut self, signal: libc::c_int);
    fn try_wait(&mut self) -> Result<Option<ExitStatus>, io::Error>;
    fn pid(&self) -> libc::pid_t;
}

impl CommandGroupWait for Child {
    fn signal_group(&mut self, signal: libc::c_int) {
        unsafe {
            libc::kill(-(self.id() as libc::pid_t), signal);
        }
    }

    fn try_wait(&mut self) -> Result<Option<ExitStatus>, io::Error> {
        Child::try_wait(self)
    }

    fn pid(&self) -> libc::pid_t {
        self.id() as libc::pid_t
    }
}

fn terminate_command_group_with<W: CommandGroupWait>(
    child: &mut W,
    term_grace: Duration,
    reap_grace: Duration,
) -> Option<ExitStatus> {
    child.signal_group(libc::SIGTERM);
    let term_deadline = Instant::now() + term_grace;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                // The leader may have exited while pipe-holding descendants
                // remain. Kill the now-identity-bound group before returning.
                child.signal_group(libc::SIGKILL);
                return Some(status);
            }
            Err(_) => return None,
            Ok(None) if Instant::now() >= term_deadline => break,
            Ok(None) => thread::sleep(PROCESS_REAP_POLL),
        }
    }

    child.signal_group(libc::SIGKILL);
    let reap_deadline = Instant::now() + reap_grace;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Err(_) => return None,
            Ok(None) if Instant::now() >= reap_deadline => return None,
            Ok(None) => thread::sleep(PROCESS_REAP_POLL),
        }
    }
}

fn terminate_command_group(child: &mut Child) -> Option<ExitStatus> {
    let pid = child.pid();
    let status =
        terminate_command_group_with(child, Duration::from_millis(250), PROCESS_REAP_GRACE);
    if status.is_none() {
        defer_reap(pid);
    }
    status
}

struct OutputCapture {
    bytes: Vec<u8>,
    truncated: bool,
}

type OutputReader = Receiver<io::Result<OutputCapture>>;

fn spawn_output_reader<R>(mut reader: R, limit: usize) -> OutputReader
where
    R: Read + Send + 'static,
{
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let result = (|| {
            let mut output = Vec::new();
            let mut buffer = [0_u8; 8192];
            let mut truncated = false;
            loop {
                let read = reader.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                let available = limit.saturating_sub(output.len());
                let keep = read.min(available);
                output.extend_from_slice(&buffer[..keep]);
                truncated |= keep < read;
            }
            if truncated {
                output.extend_from_slice(b"\n[output truncated]");
            }
            Ok(OutputCapture {
                bytes: output,
                truncated,
            })
        })();
        let _ = sender.send(result);
    });
    receiver
}

fn try_receive_output(
    reader: &Option<OutputReader>,
    result: &mut Option<io::Result<OutputCapture>>,
) {
    if result.is_some() {
        return;
    }
    let Some(reader) = reader else {
        return;
    };
    match reader.try_recv() {
        Ok(output) => *result = Some(output),
        Err(TryRecvError::Empty) => {}
        Err(TryRecvError::Disconnected) => {
            *result = Some(Err(io::Error::new(
                ErrorKind::BrokenPipe,
                "output reader disconnected",
            )));
        }
    }
}

fn finish_output(
    reader: Option<OutputReader>,
    result: Option<io::Result<OutputCapture>>,
    name: &str,
) -> OutputCapture {
    let result = result
        .or_else(|| reader.and_then(|reader| reader.recv_timeout(Duration::from_millis(100)).ok()));
    match result {
        Some(Ok(output)) => output,
        Some(Err(err)) => OutputCapture {
            bytes: format!("[{name} read failed: {err}]").into_bytes(),
            truncated: true,
        },
        None => OutputCapture {
            bytes: format!("[{name} unavailable]").into_bytes(),
            truncated: true,
        },
    }
}

fn filter_clean_lines(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(ToOwned::to_owned)
        .collect()
}

/// Reads a text file through the same module-root fd boundary used by the
/// writers. Missing or malformed ordinary list files return an empty list,
/// while symlinks, nonregular files, and hard links are rejected instead of
/// being silently followed.
pub(crate) fn clean_module_lines(app: &App, relative: &Path) -> Result<Vec<String>, String> {
    let target = split_module_relative_file(relative)?;
    let directory = open_module_directory(app, &target.directory)?;
    let Some(mut file) = open_existing_private_module_file(&directory, &target.name)? else {
        return Ok(Vec::new());
    };
    let mut text = String::new();
    if file.read_to_string(&mut text).is_err() {
        return Ok(Vec::new());
    }
    Ok(filter_clean_lines(&text))
}

pub(crate) fn first_clean_module_line(app: &App, relative: &Path) -> String {
    clean_module_lines(app, relative)
        .unwrap_or_default()
        .into_iter()
        .next()
        .unwrap_or_default()
}

/// Writes an ordinary file below `app.moddir` without resolving any
/// caller-supplied absolute path. Every component must be a normal relative
/// component and is opened from the module root descriptor with `O_NOFOLLOW`.
pub(crate) fn write_text_file(app: &App, relative: &Path, text: &str) -> Result<(), String> {
    replace_module_text_files_transactionally(app, &[(relative, text)])
}

/// Like [`write_text_file`], but documents that the payload contains secret
/// material. The transaction writer always creates a synced `0600` stage and
/// atomically publishes it, so an interrupted write cannot expose or truncate
/// the previous secret.
pub(crate) fn write_secret_file(app: &App, relative: &Path, text: &str) -> Result<(), String> {
    replace_module_text_files_transactionally(app, &[(relative, text)])
}

fn module_relative_components(relative: &Path) -> Result<Vec<&OsStr>, String> {
    let components = normal_module_components(relative)?;
    if components.is_empty() {
        Err("module file path must be a nonempty normal relative path".to_string())
    } else {
        Ok(components)
    }
}

fn normal_module_components(relative: &Path) -> Result<Vec<&OsStr>, String> {
    let mut components = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(name) => components.push(name),
            Component::CurDir
            | Component::ParentDir
            | Component::RootDir
            | Component::Prefix(_) => {
                return Err("module path must contain only normal relative components".to_string())
            }
        }
    }
    Ok(components)
}

fn open_module_root(app: &App) -> Result<File, String> {
    let path = cstring_from_os_str(app.moddir.as_os_str(), "module root")?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(format!("open module root: {}", io::Error::last_os_error()));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn ensure_module_directory_at(parent: &File, name: &OsStr) -> Result<File, String> {
    let name = cstring_from_os_str(name, "module directory name")?;
    let result = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o755) };
    if result != 0 && io::Error::last_os_error().kind() != ErrorKind::AlreadyExists {
        return Err(format!(
            "create module directory: {}",
            io::Error::last_os_error()
        ));
    }
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(format!(
            "open module directory: {}",
            io::Error::last_os_error()
        ));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn require_private_regular_module_file(file: &File) -> Result<(), String> {
    private_regular_module_file_identity(file).map(|_| ())
}

fn private_regular_module_file_identity(file: &File) -> Result<ModuleFileIdentity, String> {
    let metadata = file
        .metadata()
        .map_err(|err| format!("inspect module file: {err}"))?;
    if !metadata.file_type().is_file() || metadata.nlink() != 1 {
        return Err("refusing non-private regular module file".to_string());
    }
    Ok(ModuleFileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

pub(crate) fn cstring_from_os_str(value: &OsStr, description: &str) -> Result<CString, String> {
    CString::new(value.as_bytes())
        .map_err(|_| format!("{description} contains an unsupported NUL byte"))
}

pub(crate) fn cmdline_has_script(argv: &[String], script: &str) -> bool {
    argv.len() == 2
        && matches!(
            argv[0].rsplit('/').next(),
            Some("sh" | "ash" | "dash" | "bash" | "ksh" | "mksh")
        )
        && argv[1] == script
}

pub(crate) fn cmdline_has_command(argv: &[String], executable: &str, args: &[&str]) -> bool {
    let direct = argv.len() == args.len() + 1
        && argv[0] == executable
        && argv[1..]
            .iter()
            .map(String::as_str)
            .eq(args.iter().copied());
    let shell_wrapper = argv.len() == args.len() + 2
        && matches!(
            argv[0].rsplit('/').next(),
            Some("sh" | "ash" | "dash" | "bash" | "ksh" | "mksh")
        )
        && argv[1] == executable
        && argv[2..]
            .iter()
            .map(String::as_str)
            .eq(args.iter().copied());
    direct || shell_wrapper
}

pub(crate) fn proc_start_time(stat: &str) -> Option<String> {
    let fields = stat.rsplit_once(") ")?.1;
    fields.split_whitespace().nth(19).map(ToOwned::to_owned)
}

pub(crate) fn clear_node_cache(app: &App) {
    let _ = fs::remove_file(app.moddir.join(".tmp/magicnet-node-list.cache"));
}

pub(crate) fn read_kv(path: PathBuf) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let text = fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        map.insert(key.trim().to_string(), value);
    }
    map
}

/// Whether a value is inert when written unquoted into a `.`-sourced
/// `KEY=VALUE` conf: only characters the shell cannot act on. These confs hold
/// simple tokens (flags, enums, numbers, plain URLs); anything a source could
/// interpret — spaces, quotes, `$`, backticks, `;`, `|`, `&`, redirects,
/// globs — is rejected. Every writer of a sourced conf must go through this
/// single definition so the allowlist cannot drift between call sites.
pub(crate) fn shell_inert_conf_value(value: &str) -> bool {
    value.chars().all(|c| {
        matches!(c,
            'A'..='Z' | 'a'..='z' | '0'..='9'
            | '.' | '-' | '_' | ':' | '/' | '?' | '=' | '%' | '+' | '@' | ',')
    })
}

pub(crate) fn write_kv(
    app: &App,
    relative: &Path,
    values: &[(&str, String)],
) -> Result<(), String> {
    let text = values
        .iter()
        .map(|(key, value)| format!("{key}={value}\n"))
        .collect::<String>();
    write_text_file(app, relative, &text)
}

const MODULE_TRANSACTION_STAGING_PARENT: &str = ".tmp";
const MODULE_TRANSACTION_STAGING_DIRECTORY: &str = "magicnet-app-transaction";

/// Replaces ordinary module files as one recoverable transaction. All targets
/// must be distinct strict relative paths below the module root. New contents
/// and backups stay in a private module-root staging directory, so no stage
/// name is ever resolved through a target directory.
pub(crate) fn replace_module_text_files_transactionally(
    app: &App,
    replacements: &[(&Path, &str)],
) -> Result<(), String> {
    replace_module_text_files_transactionally_with_rename(
        app,
        replacements,
        rename_module_transaction_entry,
    )
}

struct ModuleRelativeFile {
    directory: PathBuf,
    name: OsString,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct ModuleFileIdentity {
    device: u64,
    inode: u64,
}

struct ModuleTransactionStage {
    name: OsString,
    identity: ModuleFileIdentity,
}

enum ModuleTransactionCommit {
    Created {
        new_identity: ModuleFileIdentity,
    },
    Replaced {
        backup: ModuleTransactionStage,
        new_identity: ModuleFileIdentity,
    },
}

struct ModuleTransactionCommitFailure {
    message: String,
    cleanup_stage: Option<ModuleTransactionStage>,
}

#[derive(Clone, Copy)]
enum ModuleTransactionRename {
    NoReplace,
    Exchange,
}

enum ModuleFileSnapshot {
    Missing,
    Present { identity: ModuleFileIdentity },
}

fn replace_module_text_files_transactionally_with_rename<F>(
    app: &App,
    replacements: &[(&Path, &str)],
    rename: F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    replace_module_text_files_transactionally_with_operations(
        app,
        replacements,
        write_and_sync_module_transaction_stage,
        rename,
    )
}

#[cfg(test)]
fn replace_module_text_files_transactionally_with_stage_writer<W>(
    app: &App,
    replacements: &[(&Path, &str)],
    stage_writer: W,
) -> Result<(), String>
where
    W: FnMut(&mut File, &[u8]) -> Result<(), String>,
{
    replace_module_text_files_transactionally_with_operations(
        app,
        replacements,
        stage_writer,
        rename_module_transaction_entry,
    )
}

fn replace_module_text_files_transactionally_with_operations<W, F>(
    app: &App,
    replacements: &[(&Path, &str)],
    mut stage_writer: W,
    mut rename: F,
) -> Result<(), String>
where
    W: FnMut(&mut File, &[u8]) -> Result<(), String>,
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    if replacements.is_empty() {
        return Err("module transaction requires at least one target".to_string());
    }
    let targets = replacements
        .iter()
        .map(|(relative, _)| split_module_relative_file(relative))
        .collect::<Result<Vec<_>, _>>()?;
    if targets.iter().enumerate().any(|(index, target)| {
        targets[..index].iter().any(|seen| {
            seen.directory == target.directory && seen.name.as_os_str() == target.name.as_os_str()
        })
    }) {
        return Err("module transaction targets must be distinct files".to_string());
    }
    let module_root = open_module_root(app)?;
    let directories = targets
        .iter()
        .map(|target| {
            open_module_directory_from_root(
                module_root
                    .try_clone()
                    .map_err(|err| format!("clone module root directory: {err}"))?,
                &target.directory,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    let names = targets
        .into_iter()
        .map(|target| target.name)
        .collect::<Vec<_>>();
    let contents = replacements
        .iter()
        .map(|(_, text)| text.as_bytes())
        .collect::<Vec<_>>();
    let snapshots = names
        .iter()
        .zip(&directories)
        .map(|(name, directory)| snapshot_module_transaction_target(directory, name))
        .collect::<Result<Vec<_>, _>>()?;
    let staging_directory = open_module_transaction_staging_directory(&module_root, &directories)?;
    let mut stages = std::iter::repeat_with(|| None)
        .take(names.len())
        .collect::<Vec<Option<ModuleTransactionStage>>>();
    let mut committed = std::iter::repeat_with(|| None)
        .take(names.len())
        .collect::<Vec<Option<ModuleTransactionCommit>>>();

    for index in 0..stages.len() {
        match create_module_transaction_stage(
            &staging_directory,
            index + 1,
            contents[index],
            &mut stage_writer,
        ) {
            Ok(stage) => stages[index] = Some(stage),
            Err(err) => {
                let cleanup = cleanup_module_transaction_stages(&staging_directory, &mut stages);
                return Err(module_transaction_error(err, cleanup));
            }
        }
    }

    for index in 0..stages.len() {
        let stage = stages[index]
            .take()
            .expect("each module transaction stage exists before commit");
        let commit = match commit_module_transaction_stage(
            &staging_directory,
            &directories[index],
            &names[index],
            &snapshots[index],
            stage,
            &mut rename,
        ) {
            Ok(commit) => commit,
            Err(failure) => {
                let mut recovery = Vec::new();
                if let Some(stage) = failure.cleanup_stage {
                    if let Err(err) =
                        remove_module_transaction_stage(&staging_directory, &stage.name)
                    {
                        recovery.push(err);
                    }
                }
                for rollback_index in (0..index).rev() {
                    if let Some(commit) = committed[rollback_index].take() {
                        if let Err(restore_err) = rollback_module_transaction_commit(
                            &staging_directory,
                            &directories[rollback_index],
                            &names[rollback_index],
                            commit,
                            rollback_index + 1,
                            &mut rename,
                        ) {
                            recovery.push(restore_err);
                        }
                    }
                }
                recovery.extend(cleanup_module_transaction_stages(
                    &staging_directory,
                    &mut stages,
                ));
                return Err(module_transaction_error(
                    format!("replace module transaction: {}", failure.message),
                    recovery,
                ));
            }
        };
        committed[index] = Some(commit);
    }

    let cleanup = cleanup_module_transaction_commits(&staging_directory, &mut committed);
    if cleanup.is_empty() {
        Ok(())
    } else {
        Err(module_transaction_error(
            "replace module transaction committed but private staging cleanup failed".to_string(),
            cleanup,
        ))
    }
}

fn split_module_relative_file(relative: &Path) -> Result<ModuleRelativeFile, String> {
    let mut components = module_relative_components(relative)?;
    let name = components
        .pop()
        .expect("nonempty module-relative path has a final component")
        .to_os_string();
    let mut directory = PathBuf::new();
    for component in components {
        directory.push(component);
    }
    Ok(ModuleRelativeFile { directory, name })
}

fn open_module_directory(app: &App, relative: &Path) -> Result<File, String> {
    open_module_directory_from_root(open_module_root(app)?, relative)
}

fn open_module_directory_from_root(mut directory: File, relative: &Path) -> Result<File, String> {
    for component in normal_module_components(relative)? {
        directory = ensure_module_directory_at(&directory, component)?;
    }
    Ok(directory)
}

fn snapshot_module_transaction_target(
    directory: &File,
    name: &OsStr,
) -> Result<ModuleFileSnapshot, String> {
    let Some(file) = open_existing_private_module_file(directory, name)? else {
        return Ok(ModuleFileSnapshot::Missing);
    };
    let identity = private_regular_module_file_identity(&file)?;
    Ok(ModuleFileSnapshot::Present { identity })
}

fn open_existing_private_module_file(
    directory: &File,
    name: &OsStr,
) -> Result<Option<File>, String> {
    let name = cstring_from_os_str(name, "module transaction file name")?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let err = io::Error::last_os_error();
        if err.kind() == ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(format!("open module transaction target: {err}"));
    }
    let file = unsafe { File::from_raw_fd(fd) };
    require_private_regular_module_file(&file)?;
    Ok(Some(file))
}

fn open_module_transaction_staging_directory(
    module_root: &File,
    target_directories: &[File],
) -> Result<File, String> {
    let temporary = ensure_private_module_directory_at(
        module_root,
        OsStr::new(MODULE_TRANSACTION_STAGING_PARENT),
    )?;
    let staging = ensure_private_module_directory_at(
        &temporary,
        OsStr::new(MODULE_TRANSACTION_STAGING_DIRECTORY),
    )?;
    let staging_device = staging
        .metadata()
        .map_err(|err| format!("inspect module transaction staging directory: {err}"))?
        .dev();
    for target_directory in target_directories {
        let target_device = target_directory
            .metadata()
            .map_err(|err| format!("inspect module transaction target directory: {err}"))?
            .dev();
        if target_device != staging_device {
            return Err(
                "module transaction staging directory is not on the target filesystem".to_string(),
            );
        }
    }
    Ok(staging)
}

fn ensure_private_module_directory_at(parent: &File, name: &OsStr) -> Result<File, String> {
    let name = cstring_from_os_str(name, "module transaction staging directory name")?;
    let created = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
    if created != 0 {
        let err = io::Error::last_os_error();
        if err.kind() != ErrorKind::AlreadyExists {
            return Err(format!(
                "create private module transaction directory: {err}"
            ));
        }
    }
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(format!(
            "open private module transaction directory: {}",
            io::Error::last_os_error()
        ));
    }
    let directory = unsafe { File::from_raw_fd(fd) };
    secure_private_module_transaction_directory(&directory)?;
    Ok(directory)
}

fn secure_private_module_transaction_directory(directory: &File) -> Result<(), String> {
    let metadata = directory
        .metadata()
        .map_err(|err| format!("inspect private module transaction directory: {err}"))?;
    if !metadata.file_type().is_dir() {
        return Err("refusing non-directory module transaction staging entry".to_string());
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(
            "refusing module transaction staging directory not owned by this user".to_string(),
        );
    }
    directory
        .set_permissions(fs::Permissions::from_mode(0o700))
        .map_err(|err| format!("secure module transaction staging directory: {err}"))?;
    let mode = directory
        .metadata()
        .map_err(|err| format!("inspect secured module transaction directory: {err}"))?
        .mode()
        & 0o7777;
    if mode != 0o700 {
        return Err("module transaction staging directory is not private".to_string());
    }
    Ok(())
}

fn create_module_transaction_stage<W>(
    staging_directory: &File,
    slot: usize,
    contents: &[u8],
    stage_writer: &mut W,
) -> Result<ModuleTransactionStage, String>
where
    W: FnMut(&mut File, &[u8]) -> Result<(), String>,
{
    let stage = module_transaction_stage_name(slot);
    let stage_c = cstring_from_os_str(&stage, "module transaction stage name")?;
    let fd = unsafe {
        libc::openat(
            staging_directory.as_raw_fd(),
            stage_c.as_ptr(),
            libc::O_WRONLY
                | libc::O_CREAT
                | libc::O_EXCL
                | libc::O_NOFOLLOW
                | libc::O_NONBLOCK
                | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(format!(
            "create module transaction stage: {}",
            io::Error::last_os_error()
        ));
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    let result = prepare_module_transaction_stage(&file)
        .and_then(|identity| stage_writer(&mut file, contents).map(|()| identity));
    drop(file);
    match result {
        Ok(identity) => Ok(ModuleTransactionStage {
            name: stage,
            identity,
        }),
        Err(err) => match remove_module_transaction_stage(staging_directory, &stage) {
            Ok(()) => Err(err),
            Err(cleanup_err) => Err(module_transaction_error(err, vec![cleanup_err])),
        },
    }
}

fn prepare_module_transaction_stage(file: &File) -> Result<ModuleFileIdentity, String> {
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("secure module transaction stage: {err}"))?;
    let identity = private_regular_module_file_identity(file)?;
    let mode = file
        .metadata()
        .map_err(|err| format!("inspect module transaction stage: {err}"))?
        .permissions()
        .mode()
        & 0o777;
    if mode != 0o600 {
        return Err("module transaction stage is not private".to_string());
    }
    Ok(identity)
}

fn write_and_sync_module_transaction_stage(file: &mut File, contents: &[u8]) -> Result<(), String> {
    file.write_all(contents)
        .map_err(|err| format!("write module transaction stage: {err}"))?;
    file.sync_all()
        .map_err(|err| format!("sync module transaction stage: {err}"))
}

fn module_transaction_stage_name(slot: usize) -> OsString {
    OsString::from(format!(".magicnet-app-{}-{slot}.tmp", std::process::id()))
}

fn module_transaction_recovery_stage_name(slot: usize) -> OsString {
    OsString::from(format!(
        ".magicnet-app-{}-{slot}-rollback.tmp",
        std::process::id()
    ))
}

fn module_transaction_stage_identity(
    staging_directory: &File,
    name: &OsStr,
) -> Result<ModuleFileIdentity, String> {
    let Some(file) = open_existing_private_module_file(staging_directory, name)? else {
        return Err("private module transaction stage disappeared".to_string());
    };
    private_regular_module_file_identity(&file)
}

fn commit_module_transaction_stage<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    snapshot: &ModuleFileSnapshot,
    stage: ModuleTransactionStage,
    rename: &mut F,
) -> Result<ModuleTransactionCommit, ModuleTransactionCommitFailure>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    match snapshot {
        ModuleFileSnapshot::Missing => match rename(
            ModuleTransactionRename::NoReplace,
            staging_directory,
            &stage.name,
            target_directory,
            target_name,
        ) {
            Ok(()) => Ok(ModuleTransactionCommit::Created {
                new_identity: stage.identity,
            }),
            Err(err) => Err(ModuleTransactionCommitFailure {
                message: err,
                cleanup_stage: Some(stage),
            }),
        },
        ModuleFileSnapshot::Present { identity, .. } => {
            let expected_identity = *identity;
            if let Err(err) = rename(
                ModuleTransactionRename::Exchange,
                staging_directory,
                &stage.name,
                target_directory,
                target_name,
            ) {
                return Err(ModuleTransactionCommitFailure {
                    message: err,
                    cleanup_stage: Some(stage),
                });
            }
            match module_transaction_stage_identity(staging_directory, &stage.name) {
                Ok(observed_identity) if observed_identity == expected_identity => {
                    Ok(ModuleTransactionCommit::Replaced {
                        backup: ModuleTransactionStage {
                            name: stage.name,
                            identity: expected_identity,
                        },
                        new_identity: stage.identity,
                    })
                }
                Ok(_) | Err(_) => {
                    let message = "module transaction target changed during commit".to_string();
                    match restore_failed_module_transaction_exchange(
                        staging_directory,
                        target_directory,
                        target_name,
                        &stage,
                        rename,
                    ) {
                        Ok(()) => Err(ModuleTransactionCommitFailure {
                            message,
                            cleanup_stage: Some(stage),
                        }),
                        Err(recovery_err) => Err(ModuleTransactionCommitFailure {
                            message: format!("{message}; {recovery_err}"),
                            cleanup_stage: None,
                        }),
                    }
                }
            }
        }
    }
}

fn restore_failed_module_transaction_exchange<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    stage: &ModuleTransactionStage,
    rename: &mut F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    rename(
        ModuleTransactionRename::Exchange,
        staging_directory,
        &stage.name,
        target_directory,
        target_name,
    )
    .map_err(|err| format!("restore changed module transaction target: {err}"))?;
    match module_transaction_stage_identity(staging_directory, &stage.name) {
        Ok(identity) if identity == stage.identity => Ok(()),
        Ok(_) | Err(_) => Err(
            "module transaction target changed while restoring; retained private staging entry"
                .to_string(),
        ),
    }
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn rename_module_transaction_entry(
    operation: ModuleTransactionRename,
    source_directory: &File,
    source: &OsStr,
    destination_directory: &File,
    destination: &OsStr,
) -> Result<(), String> {
    let source = cstring_from_os_str(source, "module transaction source name")?;
    let destination = cstring_from_os_str(destination, "module transaction destination name")?;
    let flags: libc::c_uint = match operation {
        ModuleTransactionRename::NoReplace => 1,
        ModuleTransactionRename::Exchange => 2,
    };
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            source_directory.as_raw_fd(),
            source.as_ptr(),
            destination_directory.as_raw_fd(),
            destination.as_ptr(),
            flags,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error().to_string())
    }
}

#[cfg(not(any(target_os = "android", target_os = "linux")))]
fn rename_module_transaction_entry(
    operation: ModuleTransactionRename,
    source_directory: &File,
    source: &OsStr,
    destination_directory: &File,
    destination: &OsStr,
) -> Result<(), String> {
    let _ = (
        operation,
        source_directory,
        source,
        destination_directory,
        destination,
    );
    Err("atomic module transaction rename is unavailable on this platform".to_string())
}

fn rollback_module_transaction_commit<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    commit: ModuleTransactionCommit,
    slot: usize,
    rename: &mut F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    match commit {
        ModuleTransactionCommit::Created { new_identity } => {
            rollback_created_module_transaction_target(
                staging_directory,
                target_directory,
                target_name,
                new_identity,
                slot,
                rename,
            )
        }
        ModuleTransactionCommit::Replaced {
            backup,
            new_identity,
        } => rollback_replaced_module_transaction_target(
            staging_directory,
            target_directory,
            target_name,
            &backup,
            new_identity,
            rename,
        ),
    }
}

fn rollback_created_module_transaction_target<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    new_identity: ModuleFileIdentity,
    slot: usize,
    rename: &mut F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    let recovery_name = module_transaction_recovery_stage_name(slot);
    rename(
        ModuleTransactionRename::NoReplace,
        target_directory,
        target_name,
        staging_directory,
        &recovery_name,
    )
    .map_err(|err| format!("capture module transaction target for rollback: {err}"))?;
    match module_transaction_stage_identity(staging_directory, &recovery_name) {
        Ok(identity) if identity == new_identity => {
            remove_module_transaction_stage(staging_directory, &recovery_name)
        }
        Ok(_) | Err(_) => {
            let message = "module transaction target changed during rollback".to_string();
            match rename(
                ModuleTransactionRename::NoReplace,
                staging_directory,
                &recovery_name,
                target_directory,
                target_name,
            ) {
                Ok(()) => Err(message),
                Err(recovery_err) => Err(format!(
                    "{message}; retained private staging entry: {recovery_err}"
                )),
            }
        }
    }
}

fn rollback_replaced_module_transaction_target<F>(
    staging_directory: &File,
    target_directory: &File,
    target_name: &OsStr,
    backup: &ModuleTransactionStage,
    new_identity: ModuleFileIdentity,
    rename: &mut F,
) -> Result<(), String>
where
    F: FnMut(ModuleTransactionRename, &File, &OsStr, &File, &OsStr) -> Result<(), String>,
{
    rename(
        ModuleTransactionRename::Exchange,
        staging_directory,
        &backup.name,
        target_directory,
        target_name,
    )
    .map_err(|err| format!("restore module transaction target: {err}"))?;
    match module_transaction_stage_identity(staging_directory, &backup.name) {
        Ok(identity) if identity == new_identity => {
            remove_module_transaction_stage(staging_directory, &backup.name)
        }
        Ok(_) | Err(_) => Err(
            "module transaction target changed during rollback; retained private staging entry"
                .to_string(),
        ),
    }
}

fn cleanup_module_transaction_stages(
    staging_directory: &File,
    stages: &mut [Option<ModuleTransactionStage>],
) -> Vec<String> {
    let mut errors = Vec::new();
    for stage in stages.iter_mut() {
        if let Some(stage) = stage.take() {
            if let Err(err) = remove_module_transaction_stage(staging_directory, &stage.name) {
                errors.push(err);
            }
        }
    }
    errors
}

fn cleanup_module_transaction_commits(
    staging_directory: &File,
    commits: &mut [Option<ModuleTransactionCommit>],
) -> Vec<String> {
    let mut errors = Vec::new();
    for commit in commits.iter_mut() {
        let Some(commit) = commit.take() else {
            continue;
        };
        if let ModuleTransactionCommit::Replaced { backup, .. } = commit {
            if let Err(err) = remove_module_transaction_stage(staging_directory, &backup.name) {
                errors.push(err);
            }
        }
    }
    errors
}

fn remove_module_transaction_stage(staging_directory: &File, name: &OsStr) -> Result<(), String> {
    let name = cstring_from_os_str(name, "module transaction stage name")?;
    let removed = unsafe { libc::unlinkat(staging_directory.as_raw_fd(), name.as_ptr(), 0) };
    if removed == 0 {
        Ok(())
    } else {
        let err = io::Error::last_os_error();
        if err.kind() == ErrorKind::NotFound {
            Ok(())
        } else {
            Err(format!("remove private module transaction stage: {err}"))
        }
    }
}

fn module_transaction_error(primary: String, recovery_errors: Vec<String>) -> String {
    if recovery_errors.is_empty() {
        primary
    } else {
        format!("{primary}; rollback failed: {}", recovery_errors.join("; "))
    }
}

fn merge_command_output(stdout: &[u8], stderr: &[u8]) -> String {
    let mut text = String::from_utf8_lossy(stdout).trim().to_string();
    let err = String::from_utf8_lossy(stderr).trim().to_string();
    if text.is_empty() {
        text = err;
    } else if !err.is_empty() {
        text.push_str("; ");
        text.push_str(&err);
    }
    text
}

fn compact_command_output(output: &str) -> String {
    output
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("no output")
        .trim()
        .to_string()
}

#[cfg(test)]
#[path = "../tests/internal/utils.rs"]
mod tests;
