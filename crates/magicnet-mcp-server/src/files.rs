use std::fs;
use std::path::{Component, Path};
use std::process::Command;

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

pub(crate) fn file_write(server: &Server, rel: &str, content: &[u8], mode: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    if let Some(parent) = path.parent() {
        if let Err(err) = fs::create_dir_all(parent) {
            return format!("mkdir failed: {err}");
        }
    }
    if let Err(err) = fs::write(&path, content) {
        return format!("write failed: {rel}: {err}");
    }
    file_chmod(server, rel, mode);
    format!("wrote {rel} mode={mode}")
}

pub(crate) fn dir_make(server: &Server, rel: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    match fs::create_dir_all(&path) {
        Ok(()) => format!("created {rel}"),
        Err(err) => format!("mkdir failed: {rel}: {err}"),
    }
}

pub(crate) fn file_chmod(server: &Server, rel: &str, mode: &str) -> String {
    if !matches!(mode, "0644" | "0755" | "0600" | "0640") {
        return format!("invalid mode: {mode}");
    }
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    match Command::new("chmod").arg(mode).arg(&path).status() {
        Ok(status) if status.success() => format!("chmod {mode} {rel}"),
        Ok(status) => format!("chmod failed: {rel}: rc={}", status.code().unwrap_or(-1)),
        Err(err) => format!("chmod failed: {rel}: {err}"),
    }
}

pub(crate) fn download_to_downloads(url: &str, filename: &str) -> String {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return "invalid download url".to_string();
    }
    if filename.is_empty()
        || filename.contains('/')
        || filename.contains("..")
        || filename.contains('\0')
    {
        return "invalid filename".to_string();
    }
    let dir = Path::new("/sdcard/Download");
    if let Err(err) = fs::create_dir_all(dir) {
        return format!("mkdir failed: {err}");
    }
    let target = dir.join(filename);
    let curl = Command::new("curl")
        .args(["-L", "--fail", "--max-time", "25", "-o"])
        .arg(&target)
        .arg(url)
        .status();
    let status = match curl {
        Ok(status) if status.success() => status,
        _ => match Command::new("wget")
            .args(["-T", "25", "-O"])
            .arg(&target)
            .arg(url)
            .status()
        {
            Ok(status) => status,
            Err(err) => return format!("download failed: {err}"),
        },
    };
    if !status.success() {
        return format!("download failed: rc={}", status.code().unwrap_or(-1));
    }
    let _ = Command::new("chmod").arg("0644").arg(&target).status();
    format!("saved {}", target.display())
}

pub(crate) fn webui_build(server: &Server) -> String {
    let Some(project) = server.moddir.parent().and_then(Path::parent) else {
        return "cannot derive project root".to_string();
    };
    let script = project.join("hooks/pre-build/2000.BUILD_WEBUI.sh");
    if !script.exists() {
        return format!("build hook not found: {}", script.display());
    }
    match Command::new(&script)
        .env("KAM_PROJECT_ROOT", project)
        .env("KAM_MODULE_ROOT", &server.moddir)
        .env("KAM_HOOKS_ROOT", project.join("hooks"))
        .output()
    {
        Ok(output) => {
            let mut text = String::new();
            text.push_str(&String::from_utf8_lossy(&output.stdout));
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            text.push_str(&format!("\nrc={}", output.status.code().unwrap_or(-1)));
            text
        }
        Err(err) => format!("webui build failed: {err}"),
    }
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
