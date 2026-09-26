use crate::{Error, Result};
use sha2::{Digest, Sha256};
use std::ffi::{CStr, CString, OsStr};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};

pub const MAX_DOCUMENT: usize = 8 * 1024 * 1024;
const MAX_COMPONENTS: usize = 24;
const MAX_PATH: usize = 2048;

pub fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub fn random_id() -> Result<String> {
    let mut bytes = [0_u8; 16];
    getrandom::getrandom(&mut bytes).map_err(|_| {
        Error::new(
            "random_unavailable",
            "The system random source is unavailable",
        )
    })?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

pub fn valid_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn cstring(value: &OsStr) -> Result<CString> {
    CString::new(value.as_bytes())
        .map_err(|_| Error::new("unsafe_path", "A path contains a NUL byte"))
}

fn parts(path: &str) -> Result<Vec<&OsStr>> {
    if path.is_empty() || path.len() > MAX_PATH || path.bytes().any(|c| c < 0x20 || c == 0x7f) {
        return Err(Error::new(
            "unsafe_path",
            "A private path is empty or invalid",
        ));
    }
    let mut result = Vec::new();
    for component in Path::new(path).components() {
        match component {
            Component::Normal(name) if name.as_bytes().len() <= 255 => result.push(name),
            _ => {
                return Err(Error::new(
                    "unsafe_path",
                    "Only relative, ordinary path components are permitted",
                ))
            }
        }
    }
    // Path::components normalizes repeated separators and an internal `.`.
    // Reject those spellings too, so one path has one canonical representation.
    if result.is_empty()
        || result.len() > MAX_COMPONENTS
        || path
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
    {
        return Err(Error::new("unsafe_path", "A private path is not canonical"));
    }
    Ok(result)
}

fn stat_fd(fd: RawFd) -> Result<libc::stat> {
    let mut value = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: fstat initializes value on success; fd is borrowed from a File.
    if unsafe { libc::fstat(fd, value.as_mut_ptr()) } != 0 {
        return Err(Error::os("Inspect opened file"));
    }
    Ok(unsafe { value.assume_init() })
}

fn ensure_owned(stat: &libc::stat, directory: bool) -> Result<()> {
    let expected = if directory {
        libc::S_IFDIR
    } else {
        libc::S_IFREG
    };
    if stat.st_mode & libc::S_IFMT != expected {
        return Err(Error::new(
            "unsafe_file",
            "A private path is not an ordinary file or directory",
        ));
    }
    if stat.st_uid != unsafe { libc::geteuid() } || stat.st_mode & 0o022 != 0 {
        return Err(Error::new(
            "unsafe_permissions",
            "A private path has an unexpected owner or writable permissions",
        ));
    }
    if !directory && stat.st_nlink != 1 {
        return Err(Error::new(
            "unsafe_file",
            "Hard-linked private files are not accepted",
        ));
    }
    Ok(())
}

fn open_dir_at(parent: RawFd, name: &OsStr, create: bool) -> Result<File> {
    let name = cstring(name)?;
    if create {
        let result = unsafe { libc::mkdirat(parent, name.as_ptr(), 0o700) };
        if result == 0 && unsafe { libc::fsync(parent) } != 0 {
            return Err(Error::os("Synchronize created directory entry").changed());
        }
        if result != 0
            && std::io::Error::last_os_error().kind() != std::io::ErrorKind::AlreadyExists
        {
            return Err(Error::os("Create private directory"));
        }
    }
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(Error::os("Open private directory"));
    }
    let file = unsafe { File::from_raw_fd(fd) };
    ensure_owned(&stat_fd(file.as_raw_fd())?, true)?;
    Ok(file)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EntryKind {
    File,
    Directory,
    Symlink,
    Other,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Entry {
    pub name: String,
    pub kind: EntryKind,
}

/// The mutation interface is deliberately small, so tests can inject crashes
/// before *and after* a visible rename, not just mock an expected error string.
pub trait Store {
    fn read(&self, path: &str, limit: usize) -> Result<Option<Vec<u8>>>;
    fn write(&self, path: &str, value: &[u8]) -> Result<()>;
    fn remove(&self, path: &str) -> Result<()>;
    fn list(&self, path: &str, limit: usize) -> Result<Vec<Entry>>;
    fn remove_dir(&self, path: &str) -> Result<()>;
}

pub struct Root {
    directory: File,
    path: PathBuf,
}

impl Root {
    /// Opens, but never creates, the module directory. Every ancestor is walked
    /// without following symlinks. Ancestor permissions can differ (e.g. /tmp
    /// in tests); the pinned module root itself must be owned and not writable
    /// by another user.
    pub fn open(path: &Path) -> Result<Self> {
        if !path.is_absolute() {
            return Err(Error::new(
                "unsafe_root",
                "The module root must be absolute",
            ));
        }
        let slash = CString::new("/").map_err(|_| Error::new("internal", "Invalid root"))?;
        let fd = unsafe {
            libc::open(
                slash.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(Error::os("Open filesystem root"));
        }
        let mut directory = unsafe { File::from_raw_fd(fd) };
        let mut depth = 0;
        for component in path.components() {
            match component {
                Component::RootDir => (),
                Component::Normal(name) => {
                    depth += 1;
                    if depth > MAX_COMPONENTS {
                        return Err(Error::new("unsafe_root", "Module path is too deep"));
                    }
                    let name = cstring(name)?;
                    let child = unsafe {
                        libc::openat(
                            directory.as_raw_fd(),
                            name.as_ptr(),
                            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                        )
                    };
                    if child < 0 {
                        return Err(Error::os("Open module root"));
                    }
                    directory = unsafe { File::from_raw_fd(child) };
                }
                _ => return Err(Error::new("unsafe_root", "Module path must be canonical")),
            }
        }
        ensure_owned(&stat_fd(directory.as_raw_fd())?, true)?;
        Ok(Self {
            directory,
            path: path.to_owned(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn try_clone(&self) -> Result<Self> {
        Ok(Self {
            directory: self
                .directory
                .try_clone()
                .map_err(|e| Error::io("Duplicate module directory", e))?,
            path: self.path.clone(),
        })
    }

    pub(crate) fn directory(&self, path: &str, create: bool) -> Result<File> {
        let mut current = self
            .directory
            .try_clone()
            .map_err(|e| Error::io("Duplicate module directory", e))?;
        for part in parts(path)? {
            current = open_dir_at(current.as_raw_fd(), part, create)?;
        }
        Ok(current)
    }

    fn parent(&self, path: &str, create: bool) -> Result<(File, CString)> {
        let components = parts(path)?;
        let mut current = self
            .directory
            .try_clone()
            .map_err(|e| Error::io("Duplicate module directory", e))?;
        for component in &components[..components.len() - 1] {
            current = open_dir_at(current.as_raw_fd(), component, create)?;
        }
        Ok((current, cstring(components[components.len() - 1])?))
    }

    pub fn ensure_dir(&self, path: &str) -> Result<()> {
        let dir = self.directory(path, true)?;
        dir.sync_all()
            .map_err(|e| Error::io("Synchronize private directory", e))
    }

    pub fn open_file(&self, path: &str) -> Result<Option<File>> {
        let (parent, name) = match self.parent(path, false) {
            Err(error) if error.code == "not_found" => return Ok(None),
            result => result?,
        };
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            let error = Error::os("Open private file");
            return if error.code == "not_found" {
                Ok(None)
            } else {
                Err(error)
            };
        }
        let file = unsafe { File::from_raw_fd(fd) };
        ensure_owned(&stat_fd(file.as_raw_fd())?, false)?;
        Ok(Some(file))
    }

    pub(crate) fn open_lock(&self, path: &str, create: bool) -> Result<Option<File>> {
        let (parent, name) = match self.parent(path, create) {
            Err(error) if error.code == "not_found" && !create => return Ok(None),
            result => result?,
        };
        let flags = libc::O_RDWR
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK
            | if create { libc::O_CREAT } else { 0 };
        let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags, 0o600) };
        if fd < 0 {
            let error = Error::os("Open runtime lock");
            return if error.code == "not_found" && !create {
                Ok(None)
            } else {
                Err(error)
            };
        }
        let file = unsafe { File::from_raw_fd(fd) };
        ensure_owned(&stat_fd(file.as_raw_fd())?, false)?;
        Ok(Some(file))
    }

    pub(crate) fn same_file(&self, path: &str, file: &File) -> Result<bool> {
        let Some(current) = self.open_file(path)? else {
            return Ok(false);
        };
        let old = stat_fd(file.as_raw_fd())?;
        let new = stat_fd(current.as_raw_fd())?;
        Ok(old.st_dev == new.st_dev && old.st_ino == new.st_ino && old.st_nlink == 1)
    }

    /// Opens a private append-only log. Callers own rotation and size bounds.
    pub fn append_file(&self, path: &str) -> Result<File> {
        let (parent, name) = self.parent(path, true)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY
                    | libc::O_APPEND
                    | libc::O_CREAT
                    | libc::O_NOFOLLOW
                    | libc::O_CLOEXEC
                    | libc::O_NONBLOCK,
                0o600,
            )
        };
        if fd < 0 {
            return Err(Error::os("Open private log"));
        }
        let file = unsafe { File::from_raw_fd(fd) };
        ensure_owned(&stat_fd(file.as_raw_fd())?, false)?;
        Ok(file)
    }

    pub fn read_json<T: serde::de::DeserializeOwned>(&self, path: &str) -> Result<Option<T>> {
        self.read(path, MAX_DOCUMENT)?
            .map(|bytes| serde_json::from_slice(&bytes).map_err(Into::into))
            .transpose()
    }

    pub fn write_json<T: serde::Serialize>(&self, path: &str, value: &T) -> Result<()> {
        let mut bytes = serde_json::to_vec(value)?;
        bytes.push(b'\n');
        self.write(path, &bytes)
    }
}

impl Store for Root {
    fn read(&self, path: &str, limit: usize) -> Result<Option<Vec<u8>>> {
        if limit > MAX_DOCUMENT {
            return Err(Error::new("limit", "Document read limit is too large"));
        }
        let Some(file) = self.open_file(path)? else {
            return Ok(None);
        };
        let metadata = file
            .metadata()
            .map_err(|e| Error::io("Inspect private document", e))?;
        if metadata.len() > limit as u64 {
            return Err(Error::new(
                "too_large",
                "The private document exceeds its limit",
            ));
        }
        let mut bytes = Vec::with_capacity((metadata.len() as usize).min(limit));
        file.take(limit as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| Error::io("Read private document", e))?;
        if bytes.len() > limit {
            return Err(Error::new(
                "too_large",
                "The private document grew beyond its limit",
            ));
        }
        Ok(Some(bytes))
    }

    fn write(&self, path: &str, value: &[u8]) -> Result<()> {
        if value.len() > MAX_DOCUMENT {
            return Err(Error::new(
                "too_large",
                "The private document exceeds its limit",
            ));
        }
        let (parent, name) = self.parent(path, true)?;
        // Refuse non-regular existing destinations. Replacement itself never
        // follows a symlink, including one installed after this check.
        if let Some(existing) = self.open_file(path)? {
            drop(existing);
        }
        let temporary = CString::new(format!(".tmp-{}", random_id()?))
            .map_err(|_| Error::new("internal", "Invalid temporary filename"))?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(Error::os("Create staged document"));
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        let staged = file.write_all(value).and_then(|_| file.sync_all());
        if let Err(error) = staged {
            unsafe {
                libc::unlinkat(parent.as_raw_fd(), temporary.as_ptr(), 0);
            }
            return Err(Error::io("Write staged document", error));
        }
        if unsafe {
            libc::renameat(
                parent.as_raw_fd(),
                temporary.as_ptr(),
                parent.as_raw_fd(),
                name.as_ptr(),
            )
        } != 0
        {
            let error = Error::os("Activate staged document");
            unsafe {
                libc::unlinkat(parent.as_raw_fd(), temporary.as_ptr(), 0);
            }
            return Err(error);
        }
        parent
            .sync_all()
            .map_err(|e| Error::io("Synchronize activated document", e).changed())
    }

    fn remove(&self, path: &str) -> Result<()> {
        let (parent, name) = match self.parent(path, false) {
            Err(error) if error.code == "not_found" => return Ok(()),
            result => result?,
        };
        // Validate ownership and type even though unlinkat would not follow a
        // symlink. A suspicious destination is evidence, not disposable data.
        if self.open_file(path)?.is_none() {
            return Ok(());
        }
        if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } != 0 {
            let error = Error::os("Remove private document");
            if error.code != "not_found" {
                return Err(error);
            }
        }
        parent
            .sync_all()
            .map_err(|e| Error::io("Synchronize document removal", e).changed())
    }

    fn list(&self, path: &str, limit: usize) -> Result<Vec<Entry>> {
        let directory = match self.directory(path, false) {
            Err(error) if error.code == "not_found" => return Ok(Vec::new()),
            result => result?,
        };
        let fd = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 3) };
        if fd < 0 {
            return Err(Error::os("Duplicate listing directory"));
        }
        let stream = unsafe { libc::fdopendir(fd) };
        if stream.is_null() {
            unsafe {
                libc::close(fd);
            }
            return Err(Error::os("List private directory"));
        }
        struct DirStream(*mut libc::DIR);
        impl Drop for DirStream {
            fn drop(&mut self) {
                unsafe {
                    libc::closedir(self.0);
                }
            }
        }
        let stream = DirStream(stream);
        let mut entries = Vec::new();
        loop {
            // readdir's buffer is owned by this stream and copied before the
            // next call. It is never shared between threads.
            #[cfg(target_os = "android")]
            let errno = unsafe { libc::__errno() };
            #[cfg(not(target_os = "android"))]
            let errno = unsafe { libc::__errno_location() };
            unsafe {
                *errno = 0;
            }
            let entry = unsafe { libc::readdir(stream.0) };
            if entry.is_null() {
                if unsafe { *errno } != 0 {
                    return Err(Error::os("Read private directory"));
                }
                break;
            }
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
            if name.to_bytes() == b"." || name.to_bytes() == b".." {
                continue;
            }
            let name = name.to_str().map_err(|_| {
                Error::new(
                    "unsafe_path",
                    "A private directory contains a non-UTF-8 name",
                )
            })?;
            if entries.len() >= limit {
                return Err(Error::new(
                    "too_many_files",
                    "The private directory exceeds its entry limit",
                ));
            }
            let cname = CString::new(name)
                .map_err(|_| Error::new("unsafe_path", "Invalid directory entry"))?;
            let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
            if unsafe {
                libc::fstatat(
                    directory.as_raw_fd(),
                    cname.as_ptr(),
                    stat.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } != 0
            {
                return Err(Error::os("Inspect private directory entry"));
            }
            let stat = unsafe { stat.assume_init() };
            let kind = match stat.st_mode & libc::S_IFMT {
                libc::S_IFREG => EntryKind::File,
                libc::S_IFDIR => EntryKind::Directory,
                libc::S_IFLNK => EntryKind::Symlink,
                _ => EntryKind::Other,
            };
            entries.push(Entry {
                name: name.into(),
                kind,
            });
        }
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(entries)
    }

    fn remove_dir(&self, path: &str) -> Result<()> {
        let (parent, name) = match self.parent(path, false) {
            Err(error) if error.code == "not_found" => return Ok(()),
            result => result?,
        };
        // rmdir is intentionally non-recursive. Unknown contents cannot be
        // removed by a journal-cleanup typo.
        if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
            let error = Error::os("Remove empty private directory");
            if error.code != "not_found" {
                return Err(error);
            }
        }
        parent
            .sync_all()
            .map_err(|e| Error::io("Synchronize directory removal", e).changed())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn root() -> (PathBuf, Root) {
        let path = std::env::temp_dir().join(format!("kamfw-fs-{}", random_id().unwrap()));
        std::fs::create_dir(&path).unwrap();
        let root = Root::open(&path).unwrap();
        (path, root)
    }

    #[test]
    fn atomic_private_files_are_bounded_and_exact() {
        let (path, root) = root();
        root.write(".config/value", b"first\n").unwrap();
        root.write(".config/value", b"second\0byte").unwrap();
        assert_eq!(
            root.read(".config/value", 32).unwrap().unwrap(),
            b"second\0byte"
        );
        assert_eq!(
            std::fs::metadata(path.join(".config/value"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(root.read(".config/value", 2).unwrap_err().code, "too_large");
        assert!(root.read("missing/file", 8).unwrap().is_none());
        root.remove(".config/value").unwrap();
        root.remove(".config/value").unwrap();
        std::fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn rejects_path_aliases_symlinks_and_hard_links_without_touching_targets() {
        let (path, root) = root();
        for bad in [
            "",
            "/etc/passwd",
            "../x",
            "a/../x",
            "a/./x",
            "a//x",
            "a/",
            "a\0b",
            "a\nb",
        ] {
            assert!(root.write(bad, b"x").is_err(), "{bad:?}");
        }
        std::fs::write(path.join("outside"), b"safe").unwrap();
        symlink(path.join("outside"), path.join("link")).unwrap();
        assert!(root.read("link", 10).is_err());
        assert!(root.write("link", b"changed").is_err());
        std::fs::hard_link(path.join("outside"), path.join("hard")).unwrap();
        assert!(root.read("hard", 10).is_err());
        symlink("/tmp", path.join("parent-link")).unwrap();
        assert!(root.write("parent-link/escape", b"x").is_err());
        assert_eq!(std::fs::read(path.join("outside")).unwrap(), b"safe");
        std::fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn rejects_fifo_without_waiting_for_a_writer() {
        let (path, root) = root();
        let pipe = CString::new(path.join("fifo").as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(pipe.as_ptr(), 0o600) }, 0);
        assert_eq!(root.read("fifo", 20).unwrap_err().code, "unsafe_file");
        std::fs::remove_dir_all(path).unwrap();
    }
}
