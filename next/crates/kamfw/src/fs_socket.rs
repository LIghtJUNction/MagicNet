//! Control-socket cleanup is intentionally narrower than arbitrary unlink.
use crate::{Error, Result, Root};
use std::ffi::CString;
use std::os::fd::AsRawFd;

impl Root {
    /// Remove one known private control socket after its owner has exited.
    /// A symlink or a regular file at that name is evidence, not disposable data.
    pub fn remove_socket(&self, path: &str) -> Result<()> {
        let name = path.strip_prefix(".state/control/").ok_or_else(|| {
            Error::new(
                "unsafe_path",
                "Only private generation control sockets may be removed",
            )
        })?;
        if !name.strip_suffix(".sock").is_some_and(crate::fs::valid_id) {
            return Err(Error::new(
                "unsafe_path",
                "The control socket identity is invalid",
            ));
        }
        let parent = match self.directory(".state/control", false) {
            Err(error) if error.code == "not_found" => return Ok(()),
            result => result?,
        };
        let name = CString::new(name)
            .map_err(|_| Error::new("unsafe_path", "The control socket name is invalid"))?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            let error = Error::os("Inspect control socket");
            return if error.code == "not_found" {
                Ok(())
            } else {
                Err(error)
            };
        }
        let stat = unsafe { stat.assume_init() };
        if stat.st_mode & libc::S_IFMT != libc::S_IFSOCK
            || stat.st_uid != unsafe { libc::geteuid() }
        {
            return Err(Error::new(
                "unsafe_file",
                "A control socket path has an unexpected type or owner",
            ));
        }
        if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } != 0 {
            return Err(Error::os("Remove inactive control socket"));
        }
        parent
            .sync_all()
            .map_err(|e| Error::io("Synchronize socket removal", e).changed())
    }
}
