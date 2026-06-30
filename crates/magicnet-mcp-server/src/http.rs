use std::io::{Read, Write};
use std::net::TcpStream;

use crate::rpc::handle_jsonrpc;
use crate::Server;

pub(crate) fn handle_connection(mut stream: TcpStream, server: &Server) -> std::io::Result<()> {
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
    if !authorized(&headers, &server.secret) {
        return write_http_error(&mut stream, "401 Unauthorized", "MCP secret required");
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

fn authorized(headers: &str, secret: &str) -> bool {
    if secret.is_empty() {
        return true;
    }
    headers.lines().any(|line| {
        let Some((key, value)) = line.split_once(':') else {
            return false;
        };
        let key = key.trim();
        let value = value.trim();
        (key.eq_ignore_ascii_case("authorization")
            && value
                .strip_prefix("Bearer ")
                .is_some_and(|token| constant_time_eq(token.trim(), secret)))
            || (key.eq_ignore_ascii_case("x-magicnet-mcp-secret")
                && constant_time_eq(value, secret))
    })
}

fn constant_time_eq(left: &str, right: &str) -> bool {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let mut diff = left.len() ^ right.len();
    let max = left.len().max(right.len());
    for index in 0..max {
        let a = left.get(index).copied().unwrap_or_default();
        let b = right.get(index).copied().unwrap_or_default();
        diff |= (a ^ b) as usize;
    }
    diff == 0
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
