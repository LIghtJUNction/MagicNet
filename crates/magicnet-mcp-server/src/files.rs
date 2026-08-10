use std::fs;
use std::io::Read;
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
    for entry in entries.flatten().take(200) {
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
    rows.join("\n")
}

pub(crate) fn file_read(server: &Server, rel: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    let file = match fs::File::open(&path) {
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
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;

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
}
