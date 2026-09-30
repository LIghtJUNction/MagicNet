//! Bounded Clash API transport for Android images without a curl executable.
//! HTTP/1.0 requests make Go's local API close the response without chunked framing.
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::{Duration, Instant};

const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_HEAD: usize = 16 * 1024;

pub(crate) fn request(api: &str, method: &str, path: &str, body: &str) -> Result<Vec<u8>, String> {
    request_with_timeout(api, method, path, body, Duration::from_secs(3))
}

fn request_with_timeout(
    api: &str,
    method: &str,
    path: &str,
    body: &str,
    timeout: Duration,
) -> Result<Vec<u8>, String> {
    let authority = api
        .strip_prefix("http://")
        .ok_or("local API requires loopback HTTP")?
        .trim_end_matches('/');
    let address: SocketAddr = authority.parse().map_err(|_| "invalid local API address")?;
    if !address.ip().is_loopback() || address.port() == 0 {
        return Err("local API requires a loopback address and nonzero port".into());
    }
    if !matches!(method, "GET" | "PUT" | "PATCH" | "DELETE")
        || !path.starts_with('/')
        || path.bytes().any(|b| !b.is_ascii_graphic())
        || body.len() > MAX_BODY
    {
        return Err("invalid local API request".into());
    }
    let deadline = Instant::now() + timeout;
    let mut stream =
        TcpStream::connect_timeout(&address, timeout).map_err(|_| "local API connection failed")?;
    let head = format!(
        "{method} {path} HTTP/1.0\r\nHost: {authority}\r\nConnection: close\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    let mut outgoing = head.into_bytes();
    outgoing.extend_from_slice(body.as_bytes());
    let mut sent = 0;
    while sent < outgoing.len() {
        stream
            .set_write_timeout(Some(remaining(deadline)?))
            .map_err(|_| "local API timeout failed")?;
        let count = stream
            .write(&outgoing[sent..])
            .map_err(|_| "local API write failed")?;
        if count == 0 {
            return Err("local API write failed".into());
        }
        sent += count;
    }
    let mut response = Vec::new();
    let mut framing = None;
    loop {
        stream
            .set_read_timeout(Some(remaining(deadline)?))
            .map_err(|_| "local API timeout failed")?;
        let mut buffer = [0u8; 8192];
        let count = stream
            .read(&mut buffer)
            .map_err(|_| "local API read failed")?;
        if count == 0 {
            break;
        }
        response.extend_from_slice(&buffer[..count]);
        if framing.is_none() {
            if let Some(end) = response.windows(4).position(|w| w == b"\r\n\r\n") {
                if end + 4 > MAX_HEAD {
                    return Err("local API headers too large".into());
                }
                framing = Some((end + 4, parse_head(&response[..end])?));
            } else if response.len() > MAX_HEAD {
                return Err("local API headers too large".into());
            }
        }
        if let Some((start, length)) = framing {
            let size = response.len() - start;
            if size > MAX_BODY || length.is_some_and(|length| size > length) {
                return Err("local API response too large or incorrectly framed".into());
            }
            if length == Some(size) {
                break;
            }
        }
    }
    let (start, length) = framing.ok_or("incomplete local API headers")?;
    let body = response.split_off(start);
    if length.is_some_and(|length| length != body.len()) {
        return Err("incomplete local API response".into());
    }
    Ok(body)
}

fn remaining(deadline: Instant) -> Result<Duration, String> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or_else(|| "local API deadline exceeded".into())
}

fn parse_head(bytes: &[u8]) -> Result<Option<usize>, String> {
    let head = std::str::from_utf8(bytes).map_err(|_| "invalid local API headers")?;
    let mut lines = head.split("\r\n");
    let mut status = lines.next().unwrap_or_default().split_whitespace();
    if !matches!(status.next(), Some("HTTP/1.0" | "HTTP/1.1")) {
        return Err("invalid local API HTTP version".into());
    }
    let code = status
        .next()
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or("invalid local API HTTP status")?;
    if !(200..300).contains(&code) {
        return Err(format!("local API HTTP status {code}"));
    }
    let mut length = None;
    for line in lines {
        let (name, value) = line.split_once(':').ok_or("invalid local API header")?;
        if name.eq_ignore_ascii_case("transfer-encoding") {
            return Err("unexpected local API transfer encoding".into());
        }
        if name.eq_ignore_ascii_case("content-length") {
            if length.is_some() {
                return Err("duplicate local API content length".into());
            }
            let value = value.trim();
            if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
                return Err("invalid local API content length".into());
            }
            let value = value
                .parse::<usize>()
                .map_err(|_| "invalid local API content length")?;
            if value > MAX_BODY {
                return Err("local API response too large".into());
            }
            length = Some(value);
        }
    }
    Ok(length)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    fn exchange(response: &[u8], method: &str, body: &str) -> Result<Vec<u8>, String> {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let api = format!("http://{}", listener.local_addr().unwrap());
        let response = response.to_vec();
        let expected_method = method.to_owned();
        let expected_body = body.to_owned();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .unwrap();
            let mut received = Vec::new();
            loop {
                let mut buffer = [0; 4096];
                let count = stream.read(&mut buffer).unwrap();
                assert!(count > 0);
                received.extend_from_slice(&buffer[..count]);
                if let Some(end) = received.windows(4).position(|w| w == b"\r\n\r\n") {
                    if received.len() >= end + 4 + expected_body.len() {
                        break;
                    }
                }
            }
            let received = String::from_utf8(received).unwrap();
            assert!(received.starts_with(&format!("{expected_method} /configs HTTP/1.0\r\n")));
            assert!(received.contains("Connection: close\r\n"));
            assert!(received.ends_with(&expected_body));
            let _ = stream.write_all(&response);
        });
        let result = request(&api, method, "/configs", body);
        server.join().unwrap();
        result
    }

    #[test]
    fn reads_json_and_handles_mode_writes_and_empty_deletes() {
        assert_eq!(
            exchange(
                b"HTTP/1.0 200 OK\r\nContent-Length: 15\r\n\r\n{\"mode\":\"Rule\"}",
                "GET",
                ""
            )
            .unwrap(),
            b"{\"mode\":\"Rule\"}"
        );
        assert_eq!(
            exchange(
                b"HTTP/1.0 200 OK\r\n\r\n{}",
                "PATCH",
                "{\"mode\":\"direct\"}"
            )
            .unwrap(),
            b"{}"
        );
        assert!(exchange(b"HTTP/1.0 204 No Content\r\n\r\n", "DELETE", "")
            .unwrap()
            .is_empty());
    }

    #[test]
    fn rejects_redirects_errors_oversize_and_ambiguous_or_incomplete_framing() {
        for response in [
            b"HTTP/1.0 302 Found\r\nLocation: http://example.com\r\n\r\n".as_slice(),
            b"HTTP/1.0 401 Unauthorized\r\n\r\n{}",
            b"HTTP/1.0 200 OK\r\nContent-Length: 8388609\r\n\r\n",
            b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            b"HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\n{}",
            b"HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\n{}",
            b"HTTP/1.0 200 OK\r\nContent-Length: +2\r\n\r\n{}",
            b"HTTP/1.0 200 OK\r\n",
        ] {
            assert!(
                exchange(response, "GET", "").is_err(),
                "accepted {response:?}"
            );
        }
    }

    #[test]
    fn rejects_nonlocal_endpoints_and_request_injection_before_connecting() {
        for api in [
            "http://192.0.2.1:9090",
            "https://127.0.0.1:9090",
            "http://localhost:9090",
            "http://127.0.0.1:0",
            "http://127.0.0.1:9090/path",
        ] {
            assert!(request(api, "GET", "/configs", "").is_err());
        }
        for path in ["configs", "/configs\r\nInjected: yes", "/with space"] {
            assert!(request("http://127.0.0.1:1", "GET", path, "").is_err());
        }
    }

    #[test]
    fn rejects_unbounded_headers_and_close_delimited_bodies() {
        let head = format!(
            "HTTP/1.0 200 OK\r\nX-Large: {}\r\n\r\n",
            "x".repeat(MAX_HEAD)
        );
        assert!(exchange(head.as_bytes(), "GET", "").is_err());
        let mut response = b"HTTP/1.0 200 OK\r\n\r\n".to_vec();
        response.resize(response.len() + MAX_BODY + 1, b'x');
        assert!(exchange(&response, "GET", "").is_err());
    }

    #[test]
    fn slow_response_cannot_extend_total_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let api = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            for byte in b"HTTP/1.0 200 OK\r\n\r\n{}" {
                if stream.write_all(&[*byte]).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        let start = Instant::now();
        assert!(
            request_with_timeout(&api, "GET", "/configs", "", Duration::from_millis(80)).is_err()
        );
        assert!(start.elapsed() < Duration::from_secs(1));
        server.join().unwrap();
    }
}
