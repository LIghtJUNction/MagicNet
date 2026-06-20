use std::fs;
use std::path::PathBuf;
use std::process::Command;

use crate::{run_cli, Server};

pub(crate) fn log_list(server: &Server) -> String {
    let mut rows = Vec::new();
    rows.push(format!("log_dir={}", log_dir(server).display()));
    rows.push("known=sing-box,mcp,fswatch,kernel,service".to_string());

    match fs::read_dir(log_dir(server)) {
        Ok(entries) => {
            for entry in entries.flatten().take(200) {
                let path = entry.path();
                let Ok(meta) = entry.metadata() else {
                    continue;
                };
                if !meta.is_file() {
                    continue;
                }
                rows.push(format!(
                    "{} bytes={}",
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or("unknown"),
                    meta.len()
                ));
            }
        }
        Err(err) => rows.push(format!("read log dir failed: {err}")),
    }

    rows.join("\n")
}

pub(crate) fn log_read(server: &Server, source: &str, lines: usize, redact: bool) -> String {
    let path = match log_path(server, source) {
        Ok(path) => path,
        Err(err) => return err,
    };
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) => return format!("log not found {}: {err}", path.display()),
    };
    let lines = lines.clamp(1, 1000);
    let all = text.lines().collect::<Vec<_>>();
    let start = all.len().saturating_sub(lines);
    let body = all[start..].join("\n");
    if redact {
        redact_text(&body)
    } else {
        body
    }
}

pub(crate) fn debug_snapshot(server: &Server, lines: usize) -> String {
    let lines = lines.clamp(20, 300);
    let sections = [
        section("mcp status", &run_cli(server, &["mcp", "status"])),
        section("service status", &run_cli(server, &["service", "status"])),
        section("health", &run_cli(server, &["health"])),
        section("listeners", &command_text("ss", &["-lntp"])),
        section("routes", &run_cli(server, &["sysroute", "snapshot"])),
        section("log list", &log_list(server)),
        section("mcp log", &log_read(server, "mcp", lines, true)),
        section("sing-box log", &log_read(server, "sing-box", lines, true)),
    ];
    sections.join("\n\n")
}

fn log_dir(server: &Server) -> PathBuf {
    server.moddir.join(".log")
}

fn log_path(server: &Server, source: &str) -> Result<PathBuf, String> {
    let source = if source.trim().is_empty() {
        "mcp"
    } else {
        source.trim()
    };
    let name = match source {
        "sing-box" | "singbox" | "core" => "sing-box.log".to_string(),
        "mcp" | "mcp-server" => "mcp-server.log".to_string(),
        "fswatch" => "fswatch.log".to_string(),
        "kernel" => "magicnet-kernel.log".to_string(),
        "service" => "service.log".to_string(),
        other if !other.contains('/') && !other.contains("..") => {
            if other.ends_with(".log") {
                other.to_string()
            } else {
                format!("{other}.log")
            }
        }
        _ => return Err("invalid log source".to_string()),
    };
    Ok(log_dir(server).join(name))
}

fn section(name: &str, body: &str) -> String {
    format!("## {name}\n{body}")
}

fn command_text(program: &str, args: &[&str]) -> String {
    match Command::new(program).args(args).output() {
        Ok(output) => {
            let mut text = String::new();
            text.push_str(&String::from_utf8_lossy(&output.stdout));
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            text
        }
        Err(err) => format!("{program} failed: {err}"),
    }
}

fn redact_text(text: &str) -> String {
    text.lines()
        .map(|line| {
            line.split_whitespace()
                .map(redact_token)
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn redact_token(token: &str) -> String {
    let lower = token.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        return "<redacted-url>".to_string();
    }
    if lower.contains("token=")
        || lower.contains("secret=")
        || lower.contains("password=")
        || lower.contains("passwd=")
        || lower.contains("authorization:")
    {
        return "<redacted-secret>".to_string();
    }
    token.to_string()
}
