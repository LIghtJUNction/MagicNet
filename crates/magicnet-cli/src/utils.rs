use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::App;

pub(crate) fn command_text_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    let mut child = match Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(err) => return format!("{program} not available: {err}"),
    };
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(40)),
            Ok(None) => {
                let _ = child.kill();
                return format!("timeout after {}ms", timeout.as_millis());
            }
            Err(err) => return format!("wait failed: {err}"),
        }
    }
    match child.wait_with_output() {
        Ok(output) => compact_output(output),
        Err(err) => format!("read failed: {err}"),
    }
}

pub(crate) fn clean_lines(path: PathBuf) -> Vec<String> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(ToOwned::to_owned)
        .collect()
}

pub(crate) fn first_clean_line(path: PathBuf) -> String {
    clean_lines(path).into_iter().next().unwrap_or_default()
}

pub(crate) fn write_text_file(path: PathBuf, text: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    fs::write(&path, text).map_err(|err| format!("write {}: {err}", path.display()))
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
        let value = value.trim().trim_matches('"').trim_matches('\'').to_string();
        map.insert(key.trim().to_string(), value);
    }
    map
}

pub(crate) fn write_kv(path: PathBuf, values: &[(&str, String)]) -> Result<(), String> {
    let text = values.iter().map(|(key, value)| format!("{key}={value}\n")).collect::<String>();
    write_text_file(path, &text)
}

fn compact_output(output: std::process::Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let err = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if text.is_empty() {
        text = err;
    } else if !err.is_empty() {
        text.push_str("; ");
        text.push_str(&err);
    }
    text.lines().last().unwrap_or("no output").trim().to_string()
}
