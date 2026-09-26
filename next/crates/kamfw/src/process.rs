//! Process ownership is a boot-bound PID/start-time/executable identity, not a
//! process name, a grep match, or a stale pidfile. Unknown is never stopped.

use crate::{sha256, Error, Result};
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    pub pid: u32,
    pub boot_id: String,
    pub start_ticks: u64,
    pub executable_device: u64,
    pub executable_inode: u64,
    pub arguments_digest: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Observation {
    Running,
    Absent,
    Foreign,
    Unknown,
}

fn bounded(path: impl AsRef<Path>, limit: usize) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    File::open(path)?
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
    }
    Ok(bytes)
}

pub fn boot_id() -> Result<String> {
    let bytes = bounded("/proc/sys/kernel/random/boot_id", 64)
        .map_err(|e| Error::io("Read boot identity", e))?;
    let value = std::str::from_utf8(&bytes)
        .map_err(|_| Error::new("unknown_process", "The boot identity is invalid"))?
        .trim();
    if value.len() != 36 || !value.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return Err(Error::new(
            "unknown_process",
            "The boot identity is invalid",
        ));
    }
    Ok(value.into())
}

pub fn parse_stat(bytes: &[u8]) -> Result<(u64, bool)> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| Error::new("unknown_process", "Process stat is not UTF-8"))?;
    let end = text
        .rfind(')')
        .ok_or_else(|| Error::new("unknown_process", "Process stat is incomplete"))?;
    let fields: Vec<&str> = text[end + 1..].split_whitespace().collect();
    let start = fields
        .get(19)
        .and_then(|value| value.parse::<u64>().ok())
        .ok_or_else(|| Error::new("unknown_process", "Process start identity is missing"))?;
    let state = fields.first().copied().unwrap_or("");
    if state.len() != 1 {
        return Err(Error::new("unknown_process", "Process state is invalid"));
    }
    Ok((start, !matches!(state, "Z" | "X" | "x")))
}

pub fn normalize_arguments(bytes: &[u8]) -> Result<Vec<Vec<u8>>> {
    let trimmed = bytes
        .iter()
        .rposition(|&b| b != 0)
        .map_or(&[][..], |end| &bytes[..=end]);
    if trimmed.is_empty() {
        return Err(Error::new("unknown_process", "Process arguments are empty"));
    }
    let result: Vec<Vec<u8>> = trimmed.split(|&b| b == 0).map(Vec::from).collect();
    if result.iter().any(Vec::is_empty) {
        return Err(Error::new(
            "unknown_process",
            "Process arguments contain an interior empty value",
        ));
    }
    Ok(result)
}

fn argument_digest(bytes: &[u8]) -> Result<String> {
    let arguments = normalize_arguments(bytes)?;
    let mut canonical = Vec::new();
    for argument in arguments {
        canonical.extend_from_slice(&(argument.len() as u32).to_be_bytes());
        canonical.extend_from_slice(&argument);
    }
    Ok(sha256(&canonical))
}

impl Identity {
    pub fn capture(pid: u32) -> Result<Self> {
        if pid <= 1 || pid > i32::MAX as u32 {
            return Err(Error::new(
                "invalid_pid",
                "A protected or invalid PID cannot be owned",
            ));
        }
        let prefix = format!("/proc/{pid}");
        let stat_before = bounded(format!("{prefix}/stat"), 4096)
            .map_err(|e| Error::io("Read process identity", e))?;
        let (start_ticks, live) = parse_stat(&stat_before)?;
        if !live {
            return Err(Error::new("not_found", "The process has exited"));
        }
        let metadata = fs::metadata(format!("{prefix}/exe"))
            .map_err(|e| Error::io("Read process executable identity", e))?;
        let arguments = bounded(format!("{prefix}/cmdline"), 16 * 1024)
            .map_err(|e| Error::io("Read process arguments", e))?;
        let stat_after = bounded(format!("{prefix}/stat"), 4096)
            .map_err(|e| Error::io("Recheck process identity", e))?;
        let (after_ticks, live) = parse_stat(&stat_after)?;
        if start_ticks != after_ticks || !live {
            return Err(Error::new(
                "identity_changed",
                "The process changed while it was inspected",
            ));
        }
        Ok(Self {
            pid,
            boot_id: boot_id()?,
            start_ticks,
            executable_device: metadata.dev(),
            executable_inode: metadata.ino(),
            arguments_digest: argument_digest(&arguments)?,
        })
    }

    pub fn observe(&self) -> Observation {
        match boot_id() {
            Ok(current) if current != self.boot_id => return Observation::Absent,
            Err(_) => return Observation::Unknown,
            _ => (),
        }
        match Self::capture(self.pid) {
            Ok(current) if current == *self => Observation::Running,
            Ok(_) => Observation::Foreign,
            Err(error) if error.code == "not_found" => Observation::Absent,
            Err(_) => Observation::Unknown,
        }
    }

    /// Graceful, bounded stop. A timeout preserves ownership evidence and does
    /// not SIGKILL a networking process that may still own kernel rules.
    pub fn stop(&self, timeout: Duration) -> Result<()> {
        if self.pid == std::process::id() || timeout.is_zero() || timeout > Duration::from_secs(60)
        {
            return Err(Error::new("invalid_stop", "The stop request is not safe"));
        }
        match self.observe() {
            Observation::Absent => return Ok(()),
            Observation::Foreign => {
                return Err(Error::new(
                    "ownership_changed",
                    "The PID no longer belongs to this runtime",
                ))
            }
            Observation::Unknown => {
                return Err(Error::new(
                    "ownership_unknown",
                    "Process ownership could not be verified",
                ))
            }
            Observation::Running => (),
        }
        let handle = unsafe { libc::syscall(libc::SYS_pidfd_open, self.pid as libc::pid_t, 0) };
        let pidfd = if handle >= 0 {
            Some(unsafe { File::from_raw_fd(handle as i32) })
        } else {
            let error = std::io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::ESRCH) => return Ok(()),
                Some(libc::ENOSYS) | Some(libc::EINVAL) => None,
                _ => return Err(Error::io("Bind process signal handle", error)),
            }
        };
        // Check again after opening pidfd. Reuse between the first observation
        // and pidfd_open must not bind a replacement process.
        if self.observe() != Observation::Running {
            return match self.observe() {
                Observation::Absent => Ok(()),
                _ => Err(Error::new(
                    "ownership_changed",
                    "Process identity changed before signalling",
                )),
            };
        }
        let result = if let Some(fd) = &pidfd {
            unsafe {
                libc::syscall(
                    libc::SYS_pidfd_send_signal,
                    fd.as_raw_fd(),
                    libc::SIGTERM,
                    std::ptr::null::<libc::siginfo_t>(),
                    0,
                )
            }
        } else {
            // Pre-pidfd kernels use the checked identity and only SIGTERM;
            // they never receive an automatic forced kill.
            unsafe { libc::kill(self.pid as i32, libc::SIGTERM) as libc::c_long }
        };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(Error::io("Signal owned process", error));
            }
        }
        let deadline = Instant::now() + timeout;
        loop {
            match self.observe() {
                Observation::Absent | Observation::Foreign => return Ok(()),
                Observation::Unknown => {
                    return Err(Error::new(
                        "ownership_unknown",
                        "Stop was requested but exit could not be verified",
                    )
                    .changed())
                }
                Observation::Running => (),
            }
            if Instant::now() >= deadline {
                return Err(Error::new(
                    "stop_timeout",
                    "The process has not finished graceful cleanup; it was not force-killed",
                )
                .retry()
                .changed());
            }
            std::thread::sleep(
                Duration::from_millis(25).min(deadline.saturating_duration_since(Instant::now())),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trailing_nuls_are_padding_but_interior_empty_arguments_are_invalid() {
        assert_eq!(
            normalize_arguments(b"/bin/core\0run\0\0\0").unwrap(),
            vec![b"/bin/core".to_vec(), b"run".to_vec()]
        );
        assert!(normalize_arguments(b"core\0\0run\0").is_err());
        assert_eq!(
            argument_digest(b"core\0run\0").unwrap(),
            argument_digest(b"core\0run\0\0\0").unwrap()
        );
    }

    #[test]
    fn current_identity_is_live_and_wrong_start_time_is_foreign() {
        let identity = Identity::capture(std::process::id()).unwrap();
        assert_eq!(identity.observe(), Observation::Running);
        let mut stale = identity.clone();
        stale.start_ticks += 1;
        assert_eq!(stale.observe(), Observation::Foreign);
        assert_eq!(
            identity.stop(Duration::from_secs(1)).unwrap_err().code,
            "invalid_stop"
        );
    }
}
