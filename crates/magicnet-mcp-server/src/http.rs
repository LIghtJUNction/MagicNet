use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use crate::rpc::handle_jsonrpc;
use crate::Server;

/// A deliberately small header budget. This endpoint accepts one JSON-RPC
/// request per connection, so it has no need to buffer arbitrary HTTP fields.
const MAX_HEADER_BYTES: usize = 16 * 1024;
/// Upper bound on a request body. The length is parsed before allocating.
const MAX_BODY_BYTES: usize = 1024 * 1024;
const HEADER_TERMINATOR_BYTES: usize = 4;
const READ_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RequestError {
    BadRequest(&'static str),
    MethodNotAllowed,
    NotFound,
    PayloadTooLarge(&'static str),
}

pub(crate) fn handle_connection(mut stream: TcpStream, server: &Server) -> io::Result<()> {
    set_read_timeout(&stream, READ_TIMEOUT)?;
    stream.set_write_timeout(Some(READ_TIMEOUT))?;

    let mut buffer = Vec::with_capacity(4096);
    let header_end = match read_headers(&mut stream, &mut buffer) {
        Ok(header_end) => header_end,
        Err(error) => return write_request_error(&mut stream, error),
    };
    let headers = match std::str::from_utf8(&buffer[..header_end]) {
        Ok(headers) => headers,
        Err(_) => {
            return write_request_error(
                &mut stream,
                RequestError::BadRequest("request headers must be UTF-8"),
            )
        }
    };
    let content_length = match parse_request_head(headers) {
        Ok(content_length) => content_length,
        Err(error) => return write_request_error(&mut stream, error),
    };
    if !authorized(headers, &server.secret) {
        return write_http_error(&mut stream, "401 Unauthorized", "MCP secret required");
    }

    let body_start = header_end + HEADER_TERMINATOR_BYTES;
    let mut body = match body_from_prefix(&buffer[body_start..], content_length) {
        Ok(body) => body,
        Err(error) => return write_request_error(&mut stream, error),
    };
    read_remaining_body(&mut stream, &mut body, content_length)?;
    let payload = match String::from_utf8(body) {
        Ok(payload) => payload,
        Err(_) => {
            return write_request_error(
                &mut stream,
                RequestError::BadRequest("request body must be UTF-8"),
            )
        }
    };
    let response = handle_jsonrpc(&payload, server);
    write_json(&mut stream, &response)
}

fn set_read_timeout(stream: &TcpStream, timeout: Duration) -> io::Result<()> {
    stream.set_read_timeout(Some(timeout))
}

fn read_headers(stream: &mut TcpStream, buffer: &mut Vec<u8>) -> Result<usize, RequestError> {
    let mut temp = [0_u8; 4096];
    loop {
        if let Some(header_end) = header_end_or_error(buffer)? {
            return Ok(header_end);
        }

        // Limit each read to the remaining header budget. This prevents a
        // single read from making the buffer exceed the cap before checking it.
        let remaining = MAX_HEADER_BYTES
            .saturating_add(HEADER_TERMINATOR_BYTES)
            .saturating_sub(buffer.len());
        if remaining == 0 {
            return Err(RequestError::PayloadTooLarge("headers too large"));
        }
        let chunk_len = remaining.min(temp.len());
        let read = stream
            .read(&mut temp[..chunk_len])
            .map_err(|_| RequestError::BadRequest("failed to read request headers"))?;
        if read == 0 {
            return Err(RequestError::BadRequest("incomplete request headers"));
        }
        buffer.extend_from_slice(&temp[..read]);
    }
}

fn header_end_or_error(buffer: &[u8]) -> Result<Option<usize>, RequestError> {
    match find_header_end(buffer) {
        Some(header_end) if header_end > MAX_HEADER_BYTES => {
            Err(RequestError::PayloadTooLarge("headers too large"))
        }
        Some(header_end) => Ok(Some(header_end)),
        None if buffer.len() >= MAX_HEADER_BYTES + HEADER_TERMINATOR_BYTES => {
            Err(RequestError::PayloadTooLarge("headers too large"))
        }
        None => Ok(None),
    }
}

fn parse_request_head(headers: &str) -> Result<usize, RequestError> {
    if !headers.is_ascii() {
        return Err(RequestError::BadRequest("request headers must be ASCII"));
    }

    let mut lines = headers.split("\r\n");
    let request_line = lines
        .next()
        .ok_or(RequestError::BadRequest("missing request line"))?;
    let (method, path, version) = parse_request_line(request_line)?;
    if method != "POST" {
        return Err(RequestError::MethodNotAllowed);
    }
    if path != "/mcp" {
        return Err(RequestError::NotFound);
    }
    if version != "HTTP/1.1" {
        return Err(RequestError::BadRequest("unsupported HTTP version"));
    }

    let mut content_length = None;
    for line in lines {
        if line.is_empty() || line.contains('\r') || line.contains('\n') {
            return Err(RequestError::BadRequest("malformed request header"));
        }
        let (name, value) = line
            .split_once(':')
            .ok_or(RequestError::BadRequest("malformed request header"))?;
        if !valid_header_name(name) {
            return Err(RequestError::BadRequest("invalid request header name"));
        }
        if name.eq_ignore_ascii_case("transfer-encoding") {
            return Err(RequestError::BadRequest("transfer encoding is unsupported"));
        }
        if name.eq_ignore_ascii_case("content-length") {
            if content_length.is_some() {
                return Err(RequestError::BadRequest("duplicate Content-Length"));
            }
            let value = value.trim();
            if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(RequestError::BadRequest("invalid Content-Length"));
            }
            let length = value
                .parse::<usize>()
                .map_err(|_| RequestError::BadRequest("invalid Content-Length"))?;
            if length > MAX_BODY_BYTES {
                return Err(RequestError::PayloadTooLarge("request body too large"));
            }
            content_length = Some(length);
        }
    }

    content_length.ok_or(RequestError::BadRequest("missing Content-Length"))
}

fn parse_request_line(line: &str) -> Result<(&str, &str, &str), RequestError> {
    if line.contains('\r') || line.contains('\n') {
        return Err(RequestError::BadRequest("malformed request line"));
    }
    let mut fields = line.split(' ');
    let method = fields
        .next()
        .filter(|field| !field.is_empty())
        .ok_or(RequestError::BadRequest("malformed request line"))?;
    let path = fields
        .next()
        .filter(|field| !field.is_empty())
        .ok_or(RequestError::BadRequest("malformed request line"))?;
    let version = fields
        .next()
        .filter(|field| !field.is_empty())
        .ok_or(RequestError::BadRequest("malformed request line"))?;
    if fields.next().is_some() {
        return Err(RequestError::BadRequest("malformed request line"));
    }
    Ok((method, path, version))
}

fn valid_header_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn body_from_prefix(prefix: &[u8], content_length: usize) -> Result<Vec<u8>, RequestError> {
    if prefix.len() > content_length {
        return Err(RequestError::BadRequest(
            "request body exceeds Content-Length",
        ));
    }
    let mut body = Vec::with_capacity(content_length);
    body.extend_from_slice(prefix);
    Ok(body)
}

fn read_remaining_body(
    stream: &mut TcpStream,
    body: &mut Vec<u8>,
    content_length: usize,
) -> io::Result<()> {
    let mut temp = [0_u8; 4096];
    while body.len() < content_length {
        let remaining = content_length - body.len();
        let chunk_len = remaining.min(temp.len());
        let read = stream.read(&mut temp[..chunk_len])?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "incomplete request body",
            ));
        }
        body.extend_from_slice(&temp[..read]);
    }
    Ok(())
}

fn authorized(headers: &str, secret: &str) -> bool {
    if secret.is_empty() {
        // Fail closed: with no configured secret nothing is authorized. The
        // normal `mcp start` path always provisions a secret before serving, so
        // this only rejects a mis-provisioned/direct launch — never the happy path.
        return false;
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
    buffer
        .windows(HEADER_TERMINATOR_BYTES)
        .position(|window| window == b"\r\n\r\n")
}

fn write_request_error(stream: &mut TcpStream, error: RequestError) -> io::Result<()> {
    match error {
        RequestError::BadRequest(body) => write_http_error(stream, "400 Bad Request", body),
        RequestError::MethodNotAllowed => write_http_error(
            stream,
            "405 Method Not Allowed",
            "MagicNet MCP uses Streamable HTTP JSON-RPC POST at /mcp.",
        ),
        RequestError::NotFound => {
            write_http_error(stream, "404 Not Found", "MCP endpoint not found")
        }
        RequestError::PayloadTooLarge(body) => {
            write_http_error(stream, "413 Payload Too Large", body)
        }
    }
}

fn write_json(stream: &mut TcpStream, body: &str) -> io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
}

fn write_http_error(stream: &mut TcpStream, status: &str, body: &str) -> io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
}

#[cfg(test)]
mod tests {
    use std::io::{ErrorKind, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::thread;
    use std::time::Duration;

    use super::*;

    #[test]
    fn authorization_requires_a_matching_nonempty_secret() {
        let headers = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer right-secret\r\n";

        assert!(authorized(headers, "right-secret"));
        assert!(!authorized(headers, "wrong-secret"));
        assert!(!authorized(headers, ""));
    }

    #[test]
    fn request_head_requires_one_bounded_decimal_content_length() {
        assert_eq!(
            parse_request_head("POST /mcp HTTP/1.1\r\nContent-Length: 2"),
            Ok(2)
        );
        assert_eq!(
            parse_request_head("POST /mcp HTTP/1.1\r\nContent-Length: nope"),
            Err(RequestError::BadRequest("invalid Content-Length"))
        );
        assert_eq!(
            parse_request_head("POST /mcp HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1"),
            Err(RequestError::BadRequest("duplicate Content-Length"))
        );
        assert_eq!(
            parse_request_head(&format!(
                "POST /mcp HTTP/1.1\r\nContent-Length: {}",
                MAX_BODY_BYTES + 1
            )),
            Err(RequestError::PayloadTooLarge("request body too large"))
        );
    }

    #[test]
    fn header_and_body_limits_reject_excess_input_before_it_is_buffered() {
        assert_eq!(
            header_end_or_error(&vec![b'x'; MAX_HEADER_BYTES + HEADER_TERMINATOR_BYTES]),
            Err(RequestError::PayloadTooLarge("headers too large"))
        );
        assert_eq!(
            body_from_prefix(b"abc", 2),
            Err(RequestError::BadRequest(
                "request body exceeds Content-Length"
            ))
        );
        assert_eq!(body_from_prefix(b"ab", 2), Ok(b"ab".to_vec()));
    }

    #[test]
    fn slow_peer_reads_use_a_timeout() {
        let (mut client, mut server) = tcp_pair();
        set_read_timeout(&server, Duration::from_millis(50)).unwrap();

        let mut byte = [0_u8; 1];
        let error = server.read(&mut byte).unwrap_err();
        assert!(matches!(
            error.kind(),
            ErrorKind::TimedOut | ErrorKind::WouldBlock
        ));
        let _ = client.write_all(b"x");
    }

    fn tcp_pair() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let accept = thread::spawn(move || listener.accept().unwrap().0);
        let client = TcpStream::connect(address).unwrap();
        let server = accept.join().unwrap();
        (client, server)
    }
}
