use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

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
    RequestTimeout,
    PayloadTooLarge(&'static str),
}

pub(crate) fn handle_connection(stream: TcpStream, server: &Server) -> io::Result<()> {
    handle_connection_with_timeout(stream, server, READ_TIMEOUT)
}

fn handle_connection_with_timeout(
    mut stream: TcpStream,
    server: &Server,
    timeout: Duration,
) -> io::Result<()> {
    // One budget covers headers and body; receiving a byte must not renew it.
    let deadline = Instant::now() + timeout;
    stream.set_write_timeout(Some(READ_TIMEOUT))?;

    let mut buffer = Vec::with_capacity(4096);
    let header_end = match read_headers(&mut stream, &mut buffer, deadline) {
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
    if let Err(error) = read_remaining_body(&mut stream, &mut body, content_length, deadline) {
        return write_request_error(&mut stream, error);
    }
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

fn read_request_chunk(
    stream: &mut TcpStream,
    buffer: &mut [u8],
    deadline: Instant,
) -> Result<usize, RequestError> {
    loop {
        // Interrupted reads consume the same budget as successful partial reads.
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|timeout| !timeout.is_zero())
            .ok_or(RequestError::RequestTimeout)?;
        match stream
            .set_read_timeout(Some(remaining))
            .and_then(|()| stream.read(buffer))
        {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => {
                return result.map_err(|error| match error.kind() {
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => {
                        RequestError::RequestTimeout
                    }
                    _ => RequestError::BadRequest("failed to read request"),
                });
            }
        }
    }
}

fn read_headers(
    stream: &mut TcpStream,
    buffer: &mut Vec<u8>,
    deadline: Instant,
) -> Result<usize, RequestError> {
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
        let read = read_request_chunk(stream, &mut temp[..chunk_len], deadline)?;
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
    deadline: Instant,
) -> Result<(), RequestError> {
    let mut temp = [0_u8; 4096];
    while body.len() < content_length {
        let remaining = content_length - body.len();
        let chunk_len = remaining.min(temp.len());
        let read = read_request_chunk(stream, &mut temp[..chunk_len], deadline)?;
        if read == 0 {
            return Err(RequestError::BadRequest("incomplete request body"));
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
        RequestError::RequestTimeout => {
            write_http_error(stream, "408 Request Timeout", "request read timed out")
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
    use std::io::{Read, Write};
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
        let deadline = Instant::now() + Duration::from_millis(50);

        let mut byte = [0_u8; 1];
        assert_eq!(
            read_request_chunk(&mut server, &mut byte, deadline),
            Err(RequestError::RequestTimeout)
        );
        let _ = client.write_all(b"x");
    }

    #[test]
    fn dripping_headers_cannot_extend_the_request_deadline() {
        let (client, mut server) = tcp_pair();
        let sender = drip_bytes(client);
        let started = std::time::Instant::now();
        assert_eq!(
            read_headers(
                &mut server,
                &mut Vec::new(),
                started + Duration::from_millis(80)
            ),
            Err(RequestError::RequestTimeout)
        );
        assert!(started.elapsed() < Duration::from_millis(300));
        drop(server);
        sender.join().unwrap();
    }

    #[test]
    fn dripping_body_cannot_extend_the_request_deadline() {
        let (client, mut server) = tcp_pair();
        let sender = drip_bytes(client);
        let started = std::time::Instant::now();
        assert_eq!(
            read_remaining_body(
                &mut server,
                &mut Vec::new(),
                100,
                started + Duration::from_millis(80)
            ),
            Err(RequestError::RequestTimeout)
        );
        assert!(started.elapsed() < Duration::from_millis(300));
        drop(server);
        sender.join().unwrap();
    }

    fn drip_bytes(mut stream: TcpStream) -> thread::JoinHandle<()> {
        thread::spawn(move || {
            for _ in 0..25 {
                if stream.write_all(b"x").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
        })
    }

    #[test]
    fn expired_deadline_rejects_even_ready_bytes() {
        let (mut client, mut server) = tcp_pair();
        client.write_all(b"x").unwrap();
        assert_eq!(
            read_request_chunk(&mut server, &mut [0_u8; 1], Instant::now()),
            Err(RequestError::RequestTimeout)
        );
    }

    #[test]
    fn trickling_headers_cannot_renew_the_request_deadline() {
        assert_trickling_request_times_out(b"POST /mcp HTTP/1.1\r\nX-Slow: ");
    }

    #[test]
    fn trickling_body_cannot_renew_the_request_deadline() {
        assert_trickling_request_times_out(
            b"POST /mcp HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nContent-Length: 1024\r\n\r\n",
        );
    }

    fn assert_trickling_request_times_out(prefix: &[u8]) {
        let (mut client, server_stream) = tcp_pair();
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        client.write_all(prefix).unwrap();
        let server = Server {
            moddir: std::path::PathBuf::from("/unused"),
            cli: std::path::PathBuf::from("/unused/cli"),
            secret: "test-secret".into(),
        };
        let handler = thread::spawn(move || {
            let started = Instant::now();
            handle_connection_with_timeout(server_stream, &server, Duration::from_millis(300))
                .unwrap();
            started.elapsed()
        });
        let mut sender = client.try_clone().unwrap();
        let producer = thread::spawn(move || {
            for _ in 0..200 {
                if sender.write_all(b"x").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        });
        let mut response = String::new();
        client.read_to_string(&mut response).unwrap();
        let elapsed = handler.join().unwrap();
        producer.join().unwrap();
        assert!(
            response.starts_with("HTTP/1.1 408 Request Timeout\r\n"),
            "{response}"
        );
        assert!(
            elapsed < Duration::from_millis(1500),
            "read budget was renewed: {elapsed:?}"
        );
    }

    #[test]
    fn complete_authorized_request_still_reaches_jsonrpc() {
        let (mut client, server_stream) = tcp_pair();
        let payload = r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#;
        write!(client, "POST /mcp HTTP/1.1\r\nAuthorization: Bearer test-secret\r\nContent-Length: {}\r\n\r\n{payload}", payload.len()).unwrap();
        let server = Server {
            moddir: std::path::PathBuf::from("/unused"),
            cli: std::path::PathBuf::from("/unused/cli"),
            secret: "test-secret".into(),
        };
        let handler = thread::spawn(move || handle_connection(server_stream, &server).unwrap());
        let mut response = String::new();
        client.read_to_string(&mut response).unwrap();
        handler.join().unwrap();
        let (head, body) = response.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("HTTP/1.1 200 OK\r\n"));
        let response: serde_json::Value = serde_json::from_str(body).unwrap();
        assert_eq!(response["id"], 1);
        assert!(response["result"]["tools"]
            .as_array()
            .is_some_and(|tools| !tools.is_empty()));
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
