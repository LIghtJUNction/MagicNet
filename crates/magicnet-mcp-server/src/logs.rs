use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::process::Command;

use crate::{run_cli, Server};

const MAX_LOG_READ_BYTES: u64 = 1024 * 1024;

pub(crate) fn log_list(server: &Server) -> String {
    let mut rows = Vec::new();
    rows.push("known=sing-box,mcp,fswatch,kernel,service".to_string());

    let root = match safe_log_dir(server) {
        Ok(root) => {
            rows.insert(0, format!("log_dir={}", root.display()));
            root
        }
        Err(err) => {
            rows.insert(0, format!("read log dir failed: {err}"));
            return rows.join("\n");
        }
    };
    match fs::read_dir(root) {
        Ok(entries) => {
            for entry in entries.flatten().take(200) {
                let path = entry.path();
                let Ok(file_type) = entry.file_type() else {
                    continue;
                };
                if file_type.is_symlink() {
                    continue;
                }
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
    let requested = match log_path(server, source) {
        Ok(path) => path,
        Err(err) => return err,
    };
    let path = match safe_log_path(server, &requested) {
        Ok(path) => path,
        Err(err) => return err,
    };
    let text = match read_bounded_tail(&path) {
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

fn read_bounded_tail(path: &PathBuf) -> std::io::Result<String> {
    let file = File::open(path)?;
    let len = file.metadata()?.len();
    read_log_snapshot(file, len)
}

fn read_log_snapshot(mut file: impl Read + Seek, len: u64) -> std::io::Result<String> {
    let start = len.saturating_sub(MAX_LOG_READ_BYTES);
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::with_capacity((len - start) as usize);
    file.take(len - start).read_to_end(&mut bytes)?;
    if start > 0 {
        if let Some(index) = bytes.iter().position(|byte| *byte == b'\n') {
            bytes.drain(..=index);
        }
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
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

fn safe_log_dir(server: &Server) -> Result<PathBuf, String> {
    let module_root = fs::canonicalize(&server.moddir)
        .map_err(|err| format!("module root unavailable: {err}"))?;
    let root = fs::canonicalize(log_dir(server))
        .map_err(|err| format!("log directory unavailable: {err}"))?;
    if !root.starts_with(&module_root) {
        return Err("log directory escapes module directory".to_string());
    }
    if !root.is_dir() {
        return Err("log path is not a directory".to_string());
    }
    Ok(root)
}

fn safe_log_path(server: &Server, requested: &PathBuf) -> Result<PathBuf, String> {
    let root = safe_log_dir(server)?;
    let resolved =
        fs::canonicalize(requested).map_err(|err| format!("log path unavailable: {err}"))?;
    if !resolved.starts_with(&root) {
        return Err("log path escapes module directory".to_string());
    }
    Ok(resolved)
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
            let lower = line.to_ascii_lowercase();
            let secret_header = ["authorization", "x-magicnet-mcp-secret"]
                .iter()
                .filter_map(|header| {
                    lower.match_indices(header).find_map(|(index, _)| {
                        lower[index + header.len()..]
                            .trim_start()
                            .starts_with(':')
                            .then_some(index)
                    })
                })
                .min();
            let prefix = secret_header.map_or(line, |index| &line[..index]);
            let mut tokens = prefix
                .split_whitespace()
                .map(redact_token)
                .collect::<Vec<_>>();
            // Header credentials may span several words; discard the rest of this line.
            if secret_header.is_some() {
                tokens.push("<redacted-secret>".to_string());
            }
            tokens.join(" ")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn redact_token(token: &str) -> String {
    let lower = token.to_ascii_lowercase();
    if lower.contains("http://") || lower.contains("https://") {
        return "<redacted-url>".to_string();
    }
    if lower.contains("token=")
        || lower.contains("secret=")
        || lower.contains("password=")
        || lower.contains("passwd=")
    {
        return "<redacted-secret>".to_string();
    }
    token.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn redacts_authorization_credentials_across_whitespace() {
        for header in [
            "Authorization: Bearer example-access-token",
            "authorization:\tBasic ZXhhbXBsZTpleGFtcGxl",
            "AUTHORIZATION: custom example-secret",
        ] {
            assert_eq!(
                redact_text(&format!("request failed {header}\nnext diagnostic")),
                "request failed <redacted-secret>\nnext diagnostic"
            );
        }
    }

    #[test]
    fn redacts_mcp_secret_from_the_first_sensitive_header() {
        for headers in [
            "X-MagicNet-MCP-Secret: example-mcp-secret",
            "x-magicnet-mcp-secret:\texample-mcp-secret",
            "X-MAGICNET-MCP-SECRET: example-mcp-secret Authorization: Bearer example-token",
            "Authorization: Bearer example-token X-MagicNet-MCP-Secret: example-mcp-secret",
        ] {
            assert_eq!(
                redact_text(&format!("请求 failed {headers}\nnext diagnostic")),
                "请求 failed <redacted-secret>\nnext diagnostic"
            );
        }
    }

    #[test]
    fn redacts_header_credentials_with_whitespace_before_the_colon() {
        for headers in [
            "Authorization : Bearer example-token",
            "X-MagicNet-MCP-Secret\t: example-secret",
            "AUTHORIZATION \t: Bearer example-token X-MagicNet-MCP-Secret : example-secret",
            "x-magicnet-mcp-secret\u{2003}: example-secret Authorization : Bearer example-token",
        ] {
            assert_eq!(
                redact_text(&format!(
                    "请求 12:34:56 request: {headers}\nnext diagnostic"
                )),
                "请求 12:34:56 request: <redacted-secret>\nnext diagnostic"
            );
        }
        assert_eq!(
            redact_text("authorization rejected; Authorization : Bearer example-token"),
            "authorization rejected; <redacted-secret>"
        );
        assert_eq!(redact_text("authorization failed"), "authorization failed");
    }

    #[test]
    fn redacts_urls_embedded_in_fields() {
        assert_eq!(
            redact_text("fetch failed source=https://example.invalid/private-value result=timeout"),
            "fetch failed <redacted-url> result=timeout"
        );
        assert_eq!(
            redact_text(r#"request {"url":"HTTP://example.invalid/private-value"}"#),
            "request <redacted-url>"
        );
    }

    #[test]
    fn bounded_log_tail_ignores_appends_after_metadata_snapshot() {
        let file = std::io::Cursor::new(b"old\nappended-after-stat\n");
        assert_eq!(read_log_snapshot(file, 4).unwrap(), "old\n");
    }

    #[test]
    fn bounded_log_tail_does_not_load_an_unbounded_prefix() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("magicnet-log-tail-{stamp}.log"));
        let mut file = File::create(&path).unwrap();
        file.write_all(&vec![b'x'; MAX_LOG_READ_BYTES as usize + 128])
            .unwrap();
        file.write_all(b"\nlast-line\n").unwrap();
        drop(file);

        let text = read_bounded_tail(&path).unwrap();
        assert!(text.len() <= MAX_LOG_READ_BYTES as usize);
        assert!(text.ends_with("last-line\n"));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn log_read_rejects_symlink_escape() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("magicnet-log-root-{stamp}"));
        let log_root = root.join(".log");
        let outside = std::env::temp_dir().join(format!("magicnet-log-outside-{stamp}.log"));
        fs::create_dir_all(&log_root).unwrap();
        fs::write(&outside, "outside\n").unwrap();
        symlink(&outside, log_root.join("mcp-server.log")).unwrap();
        let server = Server {
            moddir: PathBuf::from(&root),
            cli: PathBuf::from("/bin/echo"),
            secret: String::new(),
        };

        assert_eq!(
            log_read(&server, "mcp", 10, false),
            "log path escapes module directory"
        );

        let _ = fs::remove_file(outside);
        let _ = fs::remove_dir_all(root);
    }
}
