//! A persistent parent owns each networking child. Requests use a private Unix
//! socket whose peer credentials are checked, never a PID/name based signal.
//! This also works on pre-pidfd Android kernels. The parent does not reap a
//! child before its final signal, so PID reuse cannot target another process.
use crate::process::{Identity, Observation};
use crate::run::Spec;
use crate::{Error, Guard, LockMode, Result, Root, Store};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub schema: u32,
    pub generation: String,
    pub supervisor: Identity,
    pub child: Option<Identity>,
    pub phase: String,
    pub exit_code: Option<i32>,
}

fn paths(root: &Root, id: &str) -> Result<(String, std::path::PathBuf)> {
    if !crate::fs::valid_id(id) {
        return Err(Error::new(
            "invalid_generation",
            "The worker generation is invalid",
        ));
    }
    let socket = root.path().join(format!(".state/control/{id}.sock"));
    use std::os::unix::ffi::OsStrExt;
    if socket.as_os_str().as_bytes().len() >= 104 {
        return Err(Error::new(
            "root_too_long",
            "The private control socket path is too long",
        ));
    }
    Ok((format!(".state/workers/{id}.json"), socket))
}

pub fn record(root: &Root, id: &str) -> Result<Option<Record>> {
    let (path, _) = paths(root, id)?;
    let value: Option<Record> = root.read_json(&path)?;
    if let Some(value) = &value {
        if value.schema != 1 || value.generation != id {
            return Err(Error::new(
                "invalid_owner",
                "The worker ownership record is invalid",
            ));
        }
    }
    Ok(value)
}

/// Prepare ownership before permitting the worker to spawn a dataplane. If the
/// launcher dies before publication, pipe EOF makes the worker exit without
/// spawning a child. The caller must already have written its switch journal.
pub fn launch(root: &Root, id: &str, executable: &std::path::Path) -> Result<Identity> {
    let (path, _) = paths(root, id)?;
    let lease = Guard::acquire(
        root,
        &format!(".state/leases/{id}"),
        LockMode::Exclusive,
        Duration::from_secs(1),
        true,
    )?
    .ok_or_else(|| Error::new("missing_lease", "The worker lease is unavailable"))?;
    if record(root, id)?.is_some() && observation(root, id) != Observation::Absent {
        return Err(Error::new(
            "worker_exists",
            "The generation still has an owned worker or child",
        ));
    }
    // A prior supervisor can die before unlinking its socket. Its generation
    // lease and complete child identity have been checked above.
    root.remove_socket(&format!(".state/control/{id}.sock"))?;
    let mut command = Command::new(executable);
    command
        .args([
            "--root",
            root.path()
                .to_str()
                .ok_or_else(|| Error::new("unsafe_root", "The root is not UTF-8"))?,
            "--worker",
            id,
        ])
        .env_clear()
        .env("PATH", "/system/bin:/system/xbin:/usr/bin:/bin")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
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
        .map_err(|e| Error::io("Launch private worker", e))?;
    let identity = Identity::capture(child.id())?;
    let entry = Record {
        schema: 1,
        generation: id.into(),
        supervisor: identity.clone(),
        child: None,
        phase: "prepared".into(),
        exit_code: None,
    };
    root.write_json(&path, &entry)?;
    let mut input = child
        .stdin
        .take()
        .ok_or_else(|| Error::new("pipe_unavailable", "The worker start gate is unavailable"))?;
    drop(lease);
    input
        .write_all(id.as_bytes())
        .map_err(|e| Error::io("Open worker start gate", e).changed())?;
    drop(input);
    Ok(identity)
}

fn peer(stream: &UnixStream) -> Result<libc::ucred> {
    let mut cred = std::mem::MaybeUninit::<libc::ucred>::uninit();
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            cred.as_mut_ptr().cast(),
            &mut len,
        )
    };
    if result != 0 || len as usize != std::mem::size_of::<libc::ucred>() {
        return Err(Error::os("Verify private control peer"));
    }
    Ok(unsafe { cred.assume_init() })
}

pub fn inspect(root: &Root, id: &str) -> Result<Record> {
    exchange(root, id, false)
}

fn exchange(root: &Root, id: &str, stop: bool) -> Result<Record> {
    let (_, path) = paths(root, id)?;
    let expected = record(root, id)?
        .ok_or_else(|| Error::new("missing_owner", "The worker ownership record is missing"))?;
    let mut stream =
        UnixStream::connect(path).map_err(|e| Error::io("Connect private control socket", e))?;
    let cred = peer(&stream)?;
    if cred.pid as u32 != expected.supervisor.pid
        || cred.uid != unsafe { libc::geteuid() }
        || expected.supervisor.observe() != Observation::Running
    {
        return Err(Error::new(
            "ownership_changed",
            "The control peer does not match the recorded worker",
        ));
    }
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .map_err(|e| Error::io("Bound control read", e))?;
    stream
        .set_write_timeout(Some(Duration::from_millis(500)))
        .map_err(|e| Error::io("Bound control write", e))?;
    stream
        .write_all(if stop { b"STOP\n" } else { b"STATUS\n" })
        .map_err(|e| Error::io("Send control request", e))?;
    let mut bytes = Vec::new();
    stream
        .take(8193)
        .read_to_end(&mut bytes)
        .map_err(|e| Error::io("Read worker response", e))?;
    if bytes.len() > 8192 {
        return Err(Error::new(
            "invalid_response",
            "The worker response exceeded its bound",
        ));
    }
    let reply: Record = serde_json::from_slice(&bytes)?;
    if reply.supervisor != expected.supervisor || reply.generation != id || reply.schema != 1 {
        return Err(Error::new(
            "invalid_response",
            "The worker response did not bind its owner",
        ));
    }
    Ok(reply)
}

pub fn observation(root: &Root, id: &str) -> Observation {
    let Ok(Some(value)) = record(root, id) else {
        return Observation::Unknown;
    };
    let worker = value.supervisor.observe();
    let child = value.child.as_ref().map(Identity::observe);
    match (worker, child) {
        (Observation::Running, Some(Observation::Running)) => Observation::Running,
        (Observation::Running, None) if value.phase == "prepared" => Observation::Running,
        (_, Some(Observation::Absent | Observation::Foreign)) => Observation::Absent,
        (Observation::Absent | Observation::Foreign, None)
            if value.phase == "prepared" || value.phase == "exited" =>
        {
            Observation::Absent
        }
        _ => Observation::Unknown,
    }
}

pub fn stop(root: &Root, id: &str, timeout: Duration) -> Result<()> {
    if timeout.is_zero() || timeout > Duration::from_secs(60) {
        return Err(Error::new(
            "invalid_stop",
            "The graceful-stop deadline is invalid",
        ));
    }
    let deadline = Instant::now() + timeout;
    let owner = record(root, id)?
        .ok_or_else(|| Error::new("missing_owner", "The worker ownership record is missing"))?;
    // A dead parent has already caused the kernel to send SIGTERM to its child.
    // Wait for cleanup; do not guess that parent exit means network cleanup.
    if owner.supervisor.observe() == Observation::Running {
        exchange(root, id, true)?;
    }
    loop {
        if observation(root, id) == Observation::Absent {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(Error::new(
                "stop_timeout",
                "Graceful cleanup has not completed; no process was force-killed",
            )
            .changed()
            .retry());
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn nonblocking(file: &impl AsRawFd) -> Result<()> {
    let fd = file.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(Error::os("Configure private log pipe"));
    }
    Ok(())
}

fn drain(input: &mut impl Read, log: &mut Option<File>, root: &Root, bytes: &mut usize) {
    let mut buffer = [0_u8; 4096];
    // A noisy child cannot starve STOP handling. At most 64 KiB per stream per
    // iteration; beyond the disk quota output is discarded, not accumulated.
    for _ in 0..16 {
        match input.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => {
                if bytes.saturating_add(n) > 512 * 1024 {
                    // Root::write replaces the inode atomically and never follows
                    // links. Existing readers may finish reading the old inode.
                    drop(log.take());
                    if root
                        .write_json(
                            ".state/log-rotation.json",
                            &serde_json::json!({"schema":1,"bounded":true}),
                        )
                        .is_err()
                    {
                        break;
                    }
                    if root.write(".log/core.log", b"").is_ok() {
                        *log = root.append_file(".log/core.log").ok();
                    }
                    *bytes = 0;
                }
                if let Some(file) = log.as_mut() {
                    let _ = file.write_all(&buffer[..n]);
                }
                *bytes = bytes.saturating_add(n);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
}

fn signal_owned(child: &Child) -> Result<()> {
    // Only the parent calls this, and never after reaping this Child. Its PID
    // therefore cannot be reused between an ownership check and the signal.
    if unsafe { libc::kill(child.id() as i32, libc::SIGTERM) } != 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::ESRCH) {
            return Err(Error::io("Request child cleanup", error));
        }
    }
    Ok(())
}

/// Internal CLI entrypoint. No program, arguments or environment are accepted
/// from the socket: the application supplies a previously validated Spec.
pub fn serve(root: &Root, id: &str, spec: &Spec) -> Result<()> {
    let (path, socket) = paths(root, id)?;
    let mut gate = Vec::new();
    std::io::stdin()
        .take(33)
        .read_to_end(&mut gate)
        .map_err(|e| Error::io("Read worker start gate", e))?;
    if gate != id.as_bytes() {
        return Err(Error::new(
            "start_cancelled",
            "Worker ownership was not published",
        ));
    }
    let mut value = record(root, id)?
        .ok_or_else(|| Error::new("missing_owner", "The worker owner was not published"))?;
    if value.supervisor != Identity::capture(std::process::id())? || value.child.is_some() {
        return Err(Error::new(
            "ownership_changed",
            "The worker does not own this generation",
        ));
    }
    let _lease = Guard::acquire(
        root,
        &format!(".state/leases/{id}"),
        LockMode::Exclusive,
        Duration::ZERO,
        true,
    )?
    .ok_or_else(|| Error::new("missing_lease", "The worker lease is unavailable"))?;
    root.ensure_dir(".state/control")?;
    let listener =
        UnixListener::bind(&socket).map_err(|e| Error::io("Bind private control socket", e))?;
    listener
        .set_nonblocking(true)
        .map_err(|e| Error::io("Configure private control socket", e))?;
    struct SocketCleanup(std::path::PathBuf);
    impl Drop for SocketCleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let _cleanup = SocketCleanup(socket);
    let parent = std::process::id() as libc::pid_t;
    let mut command = Command::new(&spec.program);
    command
        .args(&spec.args)
        .env_clear()
        .env("PATH", "/system/bin:/system/xbin:/usr/bin:/bin")
        .env("LANG", "C")
        .envs(&spec.env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(directory) = &spec.directory {
        command.current_dir(directory);
    }
    unsafe {
        command.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            // Parent can die before PR_SET_PDEATHSIG is installed.
            if libc::getppid() != parent {
                libc::_exit(125);
            }
            libc::umask(0o077);
            Ok(())
        });
    }
    value.phase = "spawning".into();
    root.write_json(&path, &value)?;
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            value.phase = "exited".into();
            value.exit_code = Some(127);
            root.write_json(&path, &value)?;
            return Err(Error::io("Spawn owned dataplane", error));
        }
    };
    let setup = (|| {
        value.child = Some(Identity::capture(child.id())?);
        value.phase = "running".into();
        root.write_json(&path, &value)?;
        nonblocking(
            child
                .stdout
                .as_ref()
                .ok_or_else(|| Error::new("pipe_unavailable", "Child stdout is unavailable"))?,
        )?;
        nonblocking(
            child
                .stderr
                .as_ref()
                .ok_or_else(|| Error::new("pipe_unavailable", "Child stderr is unavailable"))?,
        )?;
        Ok(())
    })();
    if let Err(error) = setup {
        let _ = signal_owned(&child);
        // Do not exit immediately: the kernel's parent-death signal is a
        // fallback, not a reason to discard ownership after an I/O failure.
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if let Some(status) = child.try_wait().ok().flatten() {
                value.phase = "exited".into();
                value.exit_code = Some(status.code().unwrap_or(128));
                root.write_json(&path, &value).map_err(|e| e.changed())?;
                return Err(error);
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        return Err(error.changed());
    }
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| Error::new("pipe_unavailable", "Child stdout is unavailable"))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| Error::new("pipe_unavailable", "Child stderr is unavailable"))?;
    let mut log = root.append_file(".log/core.log").ok();
    let mut log_bytes = log
        .as_ref()
        .and_then(|f| f.metadata().ok())
        .map_or(0, |m| m.len() as usize);
    loop {
        // No future signal occurs after this successful reap.
        if let Some(status) = child
            .try_wait()
            .map_err(|e| Error::io("Observe owned child exit", e))?
        {
            value.phase = "exited".into();
            value.exit_code = Some(status.code().unwrap_or(128));
            root.write_json(&path, &value)?;
            return Ok(());
        }
        for _ in 0..8 {
            let (mut stream, _) = match listener.accept() {
                Ok(v) => v,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(Error::io("Accept control request", e).changed()),
            };
            let Ok(cred) = peer(&stream) else {
                continue;
            };
            if cred.uid != unsafe { libc::geteuid() } {
                continue;
            }
            stream
                .set_read_timeout(Some(Duration::from_millis(100)))
                .map_err(|e| Error::io("Bound client request", e))?;
            stream
                .set_write_timeout(Some(Duration::from_millis(100)))
                .map_err(|e| Error::io("Bound client response", e))?;
            let mut input = [0_u8; 7];
            let mut count = 0;
            while count < input.len() && (count == 0 || input[count - 1] != b'\n') {
                match stream.read(&mut input[count..count + 1]) {
                    Ok(1) => count += 1,
                    _ => break,
                }
            }
            let request = &input[..count];
            if request == b"STOP\n" {
                if value.phase != "stopping" {
                    signal_owned(&child)?;
                    value.phase = "stopping".into();
                    root.write_json(&path, &value)?;
                }
            } else if request != b"STATUS\n" {
                continue;
            }
            let _ = serde_json::to_writer(&mut stream, &value);
        }
        drain(&mut stdout, &mut log, root, &mut log_bytes);
        drain(&mut stderr, &mut log, root, &mut log_bytes);
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Resolve only a complete recorded supervisor identity; PID reuse or a matching
/// executable name alone cannot authorize a STOP request.
pub fn generation(root: &Root, identity: &Identity) -> Result<String> {
    for entry in root.list(".state/workers", 128)? {
        let Some(id) = entry
            .name
            .strip_suffix(".json")
            .filter(|id| crate::fs::valid_id(id))
        else {
            continue;
        };
        if entry.kind != crate::EntryKind::File {
            return Err(Error::new("invalid_owner", "Unexpected worker evidence"));
        }
        if record(root, id)?.is_some_and(|record| record.supervisor == *identity) {
            return Ok(id.into());
        }
    }
    Err(Error::new(
        "missing_owner",
        "The complete worker identity was not found",
    ))
}
