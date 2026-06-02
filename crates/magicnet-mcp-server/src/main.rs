use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::thread;

const TOOLS_JSON: &str = r#"{"tools":[
{"name":"magicnet_status","description":"Show MagicNet service status","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_health","description":"Run MagicNet health diagnostics","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_list","description":"Show MagicNet community and manual blocklist state","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_update","description":"Download and apply the community blocklist","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_pingtest","description":"Run MagicNet domestic and global connectivity checks","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_topology","description":"Show Android network interfaces, routes, forwarding and MagicNet topology","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_file_list","description":"List files under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_read","description":"Read a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_write","description":"Hot-update a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
{"name":"magicnet_file_write_base64","description":"Hot-update a file from base64 content under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content_base64":{"type":"string"},"mode":{"type":"string","enum":["0644","0755","0600","0640"]}},"required":["path","content_base64"]}},
{"name":"magicnet_file_chmod","description":"Change permissions for a file or directory under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"mode":{"type":"string","enum":["0644","0755","0600","0640"]}},"required":["path","mode"]}},
{"name":"magicnet_dir_make","description":"Create a directory under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},
{"name":"magicnet_webui_build","description":"Run MagicNet WebUI build hook to rebuild webroot after hot-updating frontend files","inputSchema":{"type":"object","properties":{}}}
]}"#;

struct Server {
    moddir: PathBuf,
    cli: PathBuf,
}

fn main() {
    let moddir = env::var("MODDIR").unwrap_or_else(|_| "/data/adb/modules/MagicNet".to_string());
    let bind = env::var("MAGICNET_MCP_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = env::var("MAGICNET_MCP_PORT").unwrap_or_else(|_| "8765".to_string());
    let addr = format!("{bind}:{port}");
    let listener = TcpListener::bind(&addr).unwrap_or_else(|err| panic!("listen {addr}: {err}"));
    let cli = env::var("MAGICNET_CLI")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(&moddir).join(".local/bin/magicnet-cli"));
    let server = Server {
        cli,
        moddir: PathBuf::from(moddir),
    };
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let server = server.clone_ref();
                thread::spawn(move || {
                    let _ = handle_connection(stream, &server);
                });
            }
            Err(err) => eprintln!("accept failed: {err}"),
        }
    }
}

impl Server {
    fn clone_ref(&self) -> Self {
        Self {
            moddir: self.moddir.clone(),
            cli: self.cli.clone(),
        }
    }
}

fn handle_connection(mut stream: TcpStream, server: &Server) -> std::io::Result<()> {
    let mut buffer = Vec::with_capacity(8192);
    let mut temp = [0_u8; 4096];
    loop {
        let read = stream.read(&mut temp)?;
        if read == 0 {
            return Ok(());
        }
        buffer.extend_from_slice(&temp[..read]);
        if buffer.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buffer.len() > 128 * 1024 {
            return write_http_error(&mut stream, "413 Payload Too Large", "headers too large");
        }
    }
    let header_end = find_header_end(&buffer).unwrap_or(buffer.len());
    let headers = String::from_utf8_lossy(&buffer[..header_end]);
    let request_line = headers.lines().next().unwrap_or_default();
    let method = request_line.split_whitespace().next().unwrap_or_default();
    let content_length = content_length(&headers);
    if method != "POST" {
        return write_http_error(
            &mut stream,
            "405 Method Not Allowed",
            "MagicNet MCP uses Streamable HTTP JSON-RPC POST at /mcp.",
        );
    }
    let mut body = buffer[(header_end + 4).min(buffer.len())..].to_vec();
    while body.len() < content_length {
        let read = stream.read(&mut temp)?;
        if read == 0 {
            break;
        }
        body.extend_from_slice(&temp[..read]);
    }
    let payload = String::from_utf8_lossy(&body).to_string();
    let response = handle_jsonrpc(&payload, server);
    write_json(&mut stream, &response)
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|w| w == b"\r\n\r\n")
}

fn content_length(headers: &str) -> usize {
    for line in headers.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if key.eq_ignore_ascii_case("content-length") {
            return value.trim().parse().unwrap_or(0);
        }
    }
    0
}

fn handle_jsonrpc(payload: &str, server: &Server) -> String {
    let id = json_id(payload).unwrap_or_else(|| "null".to_string());
    let method = json_string_field(payload, "method").unwrap_or_default();
    match method.as_str() {
        "initialize" => rpc_result(
            &id,
            r#"{"protocolVersion":"2025-03-26","serverInfo":{"name":"magicnet","version":"1.0.0"},"capabilities":{"tools":{}}}"#,
        ),
        "tools/list" => rpc_result(&id, TOOLS_JSON),
        "tools/call" => {
            let tool = json_string_field(payload, "name").unwrap_or_default();
            let result = call_tool(&tool, payload, server);
            rpc_result(&id, &text_content(&result))
        }
        "notifications/initialized" => rpc_result(&id, "{}"),
        _ => rpc_error(&id, -32601, "method not found"),
    }
}

fn call_tool(tool: &str, payload: &str, server: &Server) -> String {
    match tool {
        "magicnet_status" => run_cli(server, &["service", "status"]),
        "magicnet_health" => run_cli(server, &["health"]),
        "magicnet_block_list" => run_cli(server, &["block", "list"]),
        "magicnet_block_update" => run_cli(server, &["block", "update"]),
        "magicnet_pingtest" => run_cli(server, &["pingtest"]),
        "magicnet_topology" => run_cli(server, &["topology"]),
        "magicnet_file_list" => file_list(server, arg(payload, "path").as_deref().unwrap_or(".")),
        "magicnet_file_read" => file_read(server, arg(payload, "path").as_deref().unwrap_or("")),
        "magicnet_file_write" => file_write(
            server,
            arg(payload, "path").as_deref().unwrap_or(""),
            arg(payload, "content").unwrap_or_default().as_bytes(),
            "0644",
        ),
        "magicnet_file_write_base64" => {
            let decoded = match decode_base64(&arg(payload, "content_base64").unwrap_or_default()) {
                Ok(bytes) => bytes,
                Err(err) => return format!("base64 decode failed: {err}"),
            };
            file_write(
                server,
                arg(payload, "path").as_deref().unwrap_or(""),
                &decoded,
                arg(payload, "mode").as_deref().unwrap_or("0644"),
            )
        }
        "magicnet_file_chmod" => file_chmod(
            server,
            arg(payload, "path").as_deref().unwrap_or(""),
            arg(payload, "mode").as_deref().unwrap_or("0644"),
        ),
        "magicnet_dir_make" => dir_make(server, arg(payload, "path").as_deref().unwrap_or("")),
        "magicnet_webui_build" => webui_build(server),
        _ => "unknown tool".to_string(),
    }
}

fn run_cli(server: &Server, args: &[&str]) -> String {
    let output = Command::new(&server.cli).args(args).output();
    match output {
        Ok(output) => {
            let mut text = String::new();
            text.push_str(&String::from_utf8_lossy(&output.stdout));
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            text.push_str(&format!("\nrc={}", output.status.code().unwrap_or(-1)));
            text
        }
        Err(err) => format!("failed to run cli: {err}"),
    }
}

fn module_path(server: &Server, rel: &str) -> Result<PathBuf, String> {
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

fn file_list(server: &Server, rel: &str) -> String {
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

fn file_read(server: &Server, rel: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(err) => return format!("not a file: {rel}: {err}"),
    };
    let text = String::from_utf8_lossy(&bytes);
    text.lines().take(240).collect::<Vec<_>>().join("\n")
}

fn file_write(server: &Server, rel: &str, content: &[u8], mode: &str) -> String {
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

fn dir_make(server: &Server, rel: &str) -> String {
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    match fs::create_dir_all(&path) {
        Ok(()) => format!("created {rel}"),
        Err(err) => format!("mkdir failed: {rel}: {err}"),
    }
}

fn file_chmod(server: &Server, rel: &str, mode: &str) -> String {
    if !matches!(mode, "0644" | "0755" | "0600" | "0640") {
        return format!("invalid mode: {mode}");
    }
    let path = match module_path(server, rel) {
        Ok(path) => path,
        Err(err) => return err,
    };
    let status = Command::new("chmod").arg(mode).arg(&path).status();
    match status {
        Ok(status) if status.success() => format!("chmod {mode} {rel}"),
        Ok(status) => format!("chmod failed: {rel}: rc={}", status.code().unwrap_or(-1)),
        Err(err) => format!("chmod failed: {rel}: {err}"),
    }
}

fn webui_build(server: &Server) -> String {
    let Some(project) = server.moddir.parent().and_then(Path::parent) else {
        return "cannot derive project root".to_string();
    };
    let script = project.join("hooks/pre-build/2000.BUILD_WEBUI.sh");
    if !script.exists() {
        return format!("build hook not found: {}", script.display());
    }
    let output = Command::new(&script)
        .env("KAM_PROJECT_ROOT", project)
        .env("KAM_MODULE_ROOT", &server.moddir)
        .env("KAM_HOOKS_ROOT", project.join("hooks"))
        .output();
    match output {
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

fn json_string_field(payload: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let start = payload.find(&needle)?;
    let after_key = &payload[start + needle.len()..];
    let colon = after_key.find(':')?;
    parse_json_string(&after_key[colon + 1..]).map(|(value, _)| value)
}

fn arg(payload: &str, key: &str) -> Option<String> {
    let args_pos = payload.find("\"arguments\"")?;
    json_string_field(&payload[args_pos..], key)
}

fn parse_json_string(input: &str) -> Option<(String, usize)> {
    let bytes = input.as_bytes();
    let mut pos = 0;
    while pos < bytes.len() && bytes[pos].is_ascii_whitespace() {
        pos += 1;
    }
    if bytes.get(pos) != Some(&b'"') {
        return None;
    }
    pos += 1;
    let mut out = String::new();
    while pos < bytes.len() {
        match bytes[pos] {
            b'"' => return Some((out, pos + 1)),
            b'\\' => {
                pos += 1;
                match bytes.get(pos).copied()? {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{0008}'),
                    b'f' => out.push('\u{000c}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        if pos + 4 >= bytes.len() {
                            return None;
                        }
                        let hex = &input[pos + 1..pos + 5];
                        let code = u16::from_str_radix(hex, 16).ok()?;
                        out.push(char::from_u32(code as u32)?);
                        pos += 4;
                    }
                    _ => return None,
                }
            }
            byte => out.push(byte as char),
        }
        pos += 1;
    }
    None
}

fn json_id(payload: &str) -> Option<String> {
    let start = payload.find("\"id\"")?;
    let after_key = &payload[start + 4..];
    let colon = after_key.find(':')?;
    let value = after_key[colon + 1..].trim_start();
    if value.starts_with('"') {
        parse_json_string(value).map(|(text, _)| format!("\"{}\"", json_escape(&text)))
    } else {
        let end = value
            .find(|c: char| c == ',' || c == '}' || c.is_whitespace())
            .unwrap_or(value.len());
        Some(value[..end].to_string())
    }
}

fn rpc_result(id: &str, result: &str) -> String {
    format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{result}}}"#)
}

fn rpc_error(id: &str, code: i32, message: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":{id},"error":{{"code":{code},"message":"{}"}}}}"#,
        json_escape(message)
    )
}

fn text_content(text: &str) -> String {
    format!(
        r#"{{"content":[{{"type":"text","text":"{}"}}]}}"#,
        json_escape(text)
    )
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

fn write_json(stream: &mut TcpStream, body: &str) -> std::io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
}

fn write_http_error(stream: &mut TcpStream, status: &str, body: &str) -> std::io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
}

fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(input.len() * 3 / 4);
    let mut buf = 0_u32;
    let mut bits = 0_u8;
    for byte in input.bytes().filter(|b| !b.is_ascii_whitespace()) {
        if byte == b'=' {
            break;
        }
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return Err(format!("invalid byte {byte}")),
        } as u32;
        buf = (buf << 6) | value;
        bits += 6;
        while bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xff) as u8);
        }
    }
    Ok(out)
}
