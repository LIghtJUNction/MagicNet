use std::fs;
use std::path::{Component, Path};

use crate::Server;

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
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(err) => return format!("not a file: {rel}: {err}"),
    };
    String::from_utf8_lossy(&bytes)
        .lines()
        .take(240)
        .collect::<Vec<_>>()
        .join("\n")
}

fn module_path(server: &Server, rel: &str) -> Result<std::path::PathBuf, String> {
    let rel = rel.trim_start_matches('/');
    if rel.is_empty() {
        return Ok(server.moddir.clone());
    }
    let path = Path::new(rel);
    for component in path.components() {
        match component {
            Component::Normal(_) => {}
            _ => return Err("invalid path".to_string()),
        }
    }
    Ok(server.moddir.join(path))
}
