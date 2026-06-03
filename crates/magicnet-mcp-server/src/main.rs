mod base64;
mod files;
mod tools;

use std::env;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use serde_json::{json, Value};

use base64::{decode_base64, encode_base64};
use files::{dir_make, file_chmod, file_list, file_read, file_write, webui_build};
use tools::TOOLS_JSON;

pub(crate) struct Server {
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
    let request: Value = match serde_json::from_str(payload) {
        Ok(value) => value,
        Err(err) => return rpc_error(&Value::Null, -32700, &format!("parse error: {err}")),
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    match method {
        "initialize" => rpc_result(
            &id,
            json!({"protocolVersion":"2025-03-26","serverInfo":{"name":"magicnet","version":"1.0.0"},"capabilities":{"tools":{}}}),
        ),
        "tools/list" => rpc_result(&id, serde_json::from_str(TOOLS_JSON).unwrap_or_else(|_| json!({"tools": []}))),
        "tools/call" => {
            let tool = request
                .pointer("/params/name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let args = request.pointer("/params/arguments").unwrap_or(&Value::Null);
            let result = call_tool(tool, args, server);
            rpc_result(&id, text_content(&result))
        }
        "notifications/initialized" => rpc_result(&id, json!({})),
        _ => rpc_error(&id, -32601, "method not found"),
    }
}

fn call_tool(tool: &str, args: &Value, server: &Server) -> String {
    match tool {
        "magicnet_status" => run_cli(server, &["service", "status"]),
        "magicnet_health" => run_cli(server, &["health"]),
        "magicnet_block_list" => run_cli(server, &["block", "list"]),
        "magicnet_block_update" => run_cli(server, &["block", "update"]),
        "magicnet_subscription_list" => run_cli(server, &["sub", "list"]),
        "magicnet_subscription_set" => subscription_set(server, args),
        "magicnet_subscription_set_singbox_lines" => {
            subscription_set_singbox_lines(server, args)
        }
        "magicnet_free_filter_status" => run_cli(server, &["sub", "filter-free", "status"]),
        "magicnet_free_filter_set" => free_filter_set(server, args),
        "magicnet_backup_export" => backup_export(server, args),
        "magicnet_pingtest" => run_cli(server, &["pingtest"]),
        "magicnet_topology" => run_cli(server, &["topology"]),
        "magicnet_file_list" => file_list(server, arg(args, "path").as_deref().unwrap_or(".")),
        "magicnet_file_read" => file_read(server, arg(args, "path").as_deref().unwrap_or("")),
        "magicnet_file_write" => file_write(
            server,
            arg(args, "path").as_deref().unwrap_or(""),
            arg(args, "content").unwrap_or_default().as_bytes(),
            "0644",
        ),
        "magicnet_file_write_base64" => {
            let decoded = match decode_base64(&arg(args, "content_base64").unwrap_or_default()) {
                Ok(bytes) => bytes,
                Err(err) => return format!("base64 decode failed: {err}"),
            };
            file_write(
                server,
                arg(args, "path").as_deref().unwrap_or(""),
                &decoded,
                arg(args, "mode").as_deref().unwrap_or("0644"),
            )
        }
        "magicnet_file_chmod" => file_chmod(
            server,
            arg(args, "path").as_deref().unwrap_or(""),
            arg(args, "mode").as_deref().unwrap_or("0644"),
        ),
        "magicnet_dir_make" => dir_make(server, arg(args, "path").as_deref().unwrap_or("")),
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

fn subscription_set(server: &Server, args: &Value) -> String {
    let target = arg(args, "target").unwrap_or_else(|| "sing-box".to_string());
    let url = arg(args, "url").unwrap_or_default();
    if url.trim().is_empty() {
        return "missing url".to_string();
    }
    match arg(args, "provider") {
        Some(provider)
            if !provider.trim().is_empty() && matches!(target.as_str(), "mihomo" | "clash") =>
        {
            run_cli_owned(
                server,
                vec!["sub".into(), "set".into(), target, provider, url],
            )
        }
        _ => run_cli_owned(server, vec!["sub".into(), "set".into(), target, url]),
    }
}

fn subscription_set_singbox_lines(server: &Server, args: &Value) -> String {
    let content = arg(args, "content").unwrap_or_default();
    let encoded = encode_base64(content.as_bytes());
    run_cli_owned(
        server,
        vec!["sub".into(), "set-file".into(), "sing-box".into(), encoded],
    )
}

fn backup_export(server: &Server, args: &Value) -> String {
    match arg(args, "password") {
        Some(password) if !password.is_empty() => {
            run_cli_owned(server, vec!["backup".into(), "export".into(), password])
        }
        _ => run_cli(server, &["backup", "export"]),
    }
}

fn free_filter_set(server: &Server, args: &Value) -> String {
    let mode = arg(args, "mode").unwrap_or_default();
    match mode.as_str() {
        "on" | "enable" | "1" => run_cli(server, &["sub", "filter-free", "on"]),
        "off" | "disable" | "0" => run_cli(server, &["sub", "filter-free", "off"]),
        _ => "invalid mode, expected on or off".to_string(),
    }
}

fn run_cli_owned(server: &Server, args: Vec<String>) -> String {
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    run_cli(server, &refs)
}

fn arg(args: &Value, key: &str) -> Option<String> {
    args.get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn rpc_result(id: &Value, result: Value) -> String {
    json!({"jsonrpc":"2.0","id":id,"result":result}).to_string()
}

fn rpc_error(id: &Value, code: i32, message: &str) -> String {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}}).to_string()
}

fn text_content(text: &str) -> Value {
    json!({"content":[{"type":"text","text":text}]})
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
