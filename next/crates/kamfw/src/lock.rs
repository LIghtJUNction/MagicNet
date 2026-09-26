use crate::{Error, Result, Root};
use std::fs::File;
use std::os::fd::AsRawFd;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LockMode {
    Shared,
    Exclusive,
}

/// No stale-lock deletion. A kernel descriptor lock disappears when its owner
/// exits, including SIGKILL, and the stable on-disk inode is kept for reuse.
pub struct Guard {
    file: File,
    path: String,
    mode: LockMode,
}

impl Guard {
    pub fn acquire(
        root: &Root,
        path: &str,
        mode: LockMode,
        timeout: Duration,
        create: bool,
    ) -> Result<Option<Self>> {
        if create && mode != LockMode::Exclusive {
            return Err(Error::new(
                "invalid_lock",
                "Read-only callers cannot create lock files",
            ));
        }
        let Some(file) = root.open_lock(path, create)? else {
            return Ok(None);
        };
        let operation = match mode {
            LockMode::Shared => libc::LOCK_SH,
            LockMode::Exclusive => libc::LOCK_EX,
        };
        let deadline = Instant::now() + timeout;
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), operation | libc::LOCK_NB) } == 0 {
                let guard = Self {
                    file,
                    path: path.into(),
                    mode,
                };
                guard.validate(root)?;
                return Ok(Some(guard));
            }
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() != std::io::ErrorKind::WouldBlock {
                return Err(Error::io("Acquire runtime lock", error));
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(Error::new("busy", "Another operation owns the runtime lock").retry());
            }
            std::thread::sleep(
                Duration::from_millis(10).min(deadline.saturating_duration_since(now)),
            );
        }
    }

    pub fn validate(&self, root: &Root) -> Result<()> {
        if !root.same_file(&self.path, &self.file)? {
            return Err(Error::new(
                "lock_replaced",
                "The runtime lock inode changed; refusing concurrent mutation",
            ));
        }
        Ok(())
    }

    pub fn require_writer(&self, root: &Root) -> Result<()> {
        if self.mode != LockMode::Exclusive {
            return Err(Error::new(
                "read_only",
                "An exclusive runtime lock is required",
            ));
        }
        self.validate(root)
    }
}

impl Drop for Guard {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{random_id, Store};

    #[test]
    fn lock_is_bounded_and_never_broken_by_unlinking() {
        let path = std::env::temp_dir().join(format!("kamfw-lock-{}", random_id().unwrap()));
        std::fs::create_dir(&path).unwrap();
        let root = Root::open(&path).unwrap();
        assert!(Guard::acquire(
            &root,
            ".state/lock",
            LockMode::Shared,
            Duration::ZERO,
            false
        )
        .unwrap()
        .is_none());
        assert!(!path.join(".state").exists());
        let guard = Guard::acquire(
            &root,
            ".state/lock",
            LockMode::Exclusive,
            Duration::ZERO,
            true,
        )
        .unwrap()
        .unwrap();
        let another = Guard::acquire(
            &root,
            ".state/lock",
            LockMode::Exclusive,
            Duration::from_millis(10),
            false,
        );
        assert!(matches!(another, Err(Error { ref code, .. }) if code == "busy"));
        root.remove(".state/lock").unwrap();
        root.write(".state/lock", b"").unwrap();
        assert_eq!(guard.validate(&root).unwrap_err().code, "lock_replaced");
        drop(guard);
        let next = Guard::acquire(
            &root,
            ".state/lock",
            LockMode::Exclusive,
            Duration::ZERO,
            false,
        )
        .unwrap()
        .unwrap();
        drop(next);
        assert!(path.join(".state/lock").exists());
        std::fs::remove_dir_all(path).unwrap();
    }
}
