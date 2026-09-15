use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path};

use crate::Server;

const MAX_FILE_READ_BYTES: u64 = 1024 * 1024;

pub(crate) fn file_list(server: &Server, rel: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    let mut rows = Vec::new();
    let entries = match fs::read_dir(&path) {
        Ok(entries) => entries,
        Err(err) => return format!("not a directory: {rel}: {err}"),
    };
    for entry in entries.flatten().take(1001) {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        let suffix = if file_type.is_dir() { "/" } else { "" };
        let entry_path = entry.path();
        let display = entry_path
            .strip_prefix(&server.moddir)
            .unwrap_or(entry_path.as_path())
            .display()
            .to_string();
        rows.push(format!("{display}{suffix}"));
    }
    rows.sort_unstable();
    if rows.len() > 200 {
        rows.truncate(200);
        rows.push("[listing truncated]".to_string());
    }
    rows.join("\n")
}

pub(crate) fn file_read(server: &Server, rel: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    let file = match open_regular_file(&path) {
        Ok(file) => file,
        Err(err) => return format!("not a file: {rel}: {err}"),
    };
    let mut bytes = Vec::new();
    if let Err(err) = file.take(MAX_FILE_READ_BYTES + 1).read_to_end(&mut bytes) {
        return format!("read file failed: {rel}: {err}");
    }
    if bytes.len() as u64 > MAX_FILE_READ_BYTES {
        return format!("file too large: {rel} (max {MAX_FILE_READ_BYTES} bytes)");
    };
    String::from_utf8_lossy(&bytes)
        .lines()
        .take(240)
        .collect::<Vec<_>>()
        .join("\n")
}

pub(crate) fn open_regular_file(path: &Path) -> io::Result<fs::File> {
    let invalid_type = || io::Error::new(io::ErrorKind::InvalidInput, "not a regular file");
    if !fs::symlink_metadata(path)?.is_file() {
        return Err(invalid_type());
    }
    // A FIFO substituted after the metadata check must not block a worker in open().
    // Both callers have already resolved in-module symlinks to their target paths.
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(invalid_type());
    }
    Ok(file)
}

fn module_path(server: &Server, rel: &str) -> Result<std::path::PathBuf, String> {
    let root = fs::canonicalize(&server.moddir)
        .map_err(|err| format!("module root unavailable: {err}"))?;
    let rel = rel.trim_start_matches('/');
    if rel.is_empty() {
        return Ok(root);
    }
    let path = Path::new(rel);
    for component in path.components() {
        match component {
            Component::Normal(_) => {}
            _ => return Err("invalid path".to_string()),
        }
    }
    let resolved = fs::canonicalize(server.moddir.join(path))
        .map_err(|err| format!("path not found: {rel}: {err}"))?;
    if !resolved.starts_with(&root) {
        return Err("path escapes module directory".to_string());
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use std::ffi::CString;
    use std::fs;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{symlink, OpenOptionsExt};
    use std::path::PathBuf;
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use super::*;

    fn test_server(name: &str) -> (Server, PathBuf) {
        let root =
            std::env::temp_dir().join(format!("magicnet-mcp-files-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let server = Server {
            moddir: root.clone(),
            cli: PathBuf::from("/bin/echo"),
            secret: String::new(),
        };
        (server, root)
    }

    #[test]
    fn file_read_rejects_symlink_escape() {
        let (server, root) = test_server("symlink");
        let outside = root
            .parent()
            .unwrap()
            .join(format!("magicnet-mcp-outside-{}", std::process::id()));
        fs::write(&outside, "outside").unwrap();
        symlink(&outside, root.join("escape")).unwrap();

        assert_eq!(
            file_read(&server, "escape"),
            "path escapes module directory"
        );

        let _ = fs::remove_file(outside);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn file_read_rejects_unbounded_files() {
        let (server, root) = test_server("size");
        fs::write(
            root.join("large"),
            vec![b'x'; (MAX_FILE_READ_BYTES + 1) as usize],
        )
        .unwrap();

        let result = file_read(&server, "large");
        assert!(result.starts_with("file too large: large"));

        let _ = fs::remove_dir_all(root);
    }

    fn assert_fifo_rejected(name: &str, read: fn(&Server) -> String) {
        let (server, root) = test_server(name);
        fs::create_dir_all(root.join(".log")).unwrap();
        let fifo = root.join(".log/pipe.log");
        let fifo_name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
        let (sender, receiver) = mpsc::channel();
        let worker = thread::spawn(move || {
            let _ = sender.send(read(&server));
        });
        let result = receiver.recv_timeout(Duration::from_secs(2));
        if result.is_err() {
            // Unblock the old blocking open/read so a regression cannot hang the suite.
            let _ = fs::OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(&fifo);
        }
        fs::remove_dir_all(root).unwrap();
        let result = result.expect("FIFO reads must finish without a writer");
        worker.join().unwrap();
        assert!(result.contains("not a regular file"), "{result}");
    }

    #[test]
    fn file_read_rejects_fifo_without_waiting_for_a_writer() {
        assert_fifo_rejected("file-fifo", |server| file_read(server, ".log/pipe.log"));
    }

    #[test]
    fn log_read_rejects_fifo_without_waiting_for_a_writer() {
        assert_fifo_rejected("log-fifo", |server| {
            crate::logs::log_read(server, "pipe", 10, false)
        });
    }

    #[test]
    fn file_and_log_reads_preserve_regular_file_contents() {
        let (server, root) = test_server("regular");
        fs::create_dir_all(root.join(".log")).unwrap();
        fs::write(root.join(".log/example.log"), "first\nsecond\nthird\n").unwrap();
        symlink(root.join(".log/example.log"), root.join("internal-link")).unwrap();
        assert_eq!(file_read(&server, "internal-link"), "first\nsecond\nthird");
        assert_eq!(
            crate::logs::log_read(&server, "example", 2, false),
            "second\nthird"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
