//! Bounded share-link import. Unknown security/transport options are rejected,
//! not silently discarded. Provider labels never become executable strings.
use base64::{engine::general_purpose as b64, Engine as _};
use kamfw::{Error, Result};
use serde_json::{json, Value};
use std::collections::BTreeMap;

const MAX_LINK: usize = 32 * 1024;
fn bad() -> Error {
    Error::new(
        "invalid_share_link",
        "The share link has invalid or unsupported fields",
    )
}
fn base64(value: &str) -> Result<Vec<u8>> {
    for engine in [
        b64::STANDARD,
        b64::STANDARD_NO_PAD,
        b64::URL_SAFE,
        b64::URL_SAFE_NO_PAD,
    ] {
        if let Ok(bytes) = engine.decode(value) {
            return Ok(bytes);
        }
    }
    Err(bad())
}
fn text(bytes: Vec<u8>) -> Result<String> {
    String::from_utf8(bytes).map_err(|_| bad())
}
fn percent(value: &str) -> Result<String> {
    let mut bytes = Vec::with_capacity(value.len());
    let mut input = value.as_bytes().iter();
    while let Some(&byte) = input.next() {
        if byte == b'%' {
            let hi = (*input.next().ok_or_else(bad)? as char)
                .to_digit(16)
                .ok_or_else(bad)?;
            let lo = (*input.next().ok_or_else(bad)? as char)
                .to_digit(16)
                .ok_or_else(bad)?;
            bytes.push((hi * 16 + lo) as u8);
        } else {
            bytes.push(byte);
        }
    }
    let value = text(bytes)?;
    if value.chars().any(char::is_control) {
        return Err(bad());
    }
    Ok(value)
}
fn address(value: &str, default_port: Option<u16>) -> Result<(String, u16)> {
    let (host, port) = if let Some(rest) = value.strip_prefix('[') {
        let (ip, suffix) = rest.split_once(']').ok_or_else(bad)?;
        ip.parse::<std::net::Ipv6Addr>().map_err(|_| bad())?;
        (
            ip,
            if suffix.is_empty() {
                None
            } else {
                Some(suffix.strip_prefix(':').ok_or_else(bad)?)
            },
        )
    } else {
        match value.rsplit_once(':') {
            Some((host, port)) if !host.contains(':') => (host, Some(port)),
            None => (value, None),
            _ => return Err(bad()),
        }
    };
    if host.is_empty()
        || host.len() > 253
        || host
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || "@/?#\\%".contains(c))
    {
        return Err(bad());
    }
    let port = match port {
        Some(port) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => {
            port.parse::<u16>().map_err(|_| bad())?
        }
        Some(_) => return Err(bad()),
        None => default_port.ok_or_else(bad)?,
    };
    if port == 0 {
        return Err(bad());
    }
    Ok((host.into(), port))
}
fn params(query: &str) -> Result<BTreeMap<String, String>> {
    let mut out = BTreeMap::new();
    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        let key = percent(key)?;
        if key.is_empty() || out.insert(key, percent(value)?).is_some() {
            return Err(bad());
        }
    }
    Ok(out)
}
fn take(map: &mut BTreeMap<String, String>, key: &str) -> Option<String> {
    map.remove(key).filter(|v| !v.is_empty())
}
fn flag(value: &str) -> Result<bool> {
    match value {
        "1" | "true" => Ok(true),
        "0" | "false" => Ok(false),
        _ => Err(bad()),
    }
}
fn tls(out: &mut Value, query: &mut BTreeMap<String, String>, default: bool) -> Result<()> {
    let security =
        take(query, "security")
            .unwrap_or_else(|| if default { "tls".into() } else { "none".into() });
    if !matches!(security.as_str(), "none" | "tls" | "reality") {
        return Err(bad());
    }
    if security == "none" {
        return Ok(());
    }
    let mut value = json!({"enabled":true});
    let server_name = take(query, "sni").or_else(|| take(query, "peer"));
    if let Some(name) = server_name {
        value["server_name"] = json!(name);
    }
    if let Some(alpn) = take(query, "alpn") {
        value["alpn"] = json!(alpn.split(',').collect::<Vec<_>>());
    }
    if let Some(insecure) = take(query, "allowInsecure").or_else(|| take(query, "insecure")) {
        value["insecure"] = json!(flag(&insecure)?);
    }
    if let Some(fingerprint) = take(query, "fp") {
        value["utls"] = json!({"enabled":true,"fingerprint":fingerprint});
    }
    if security == "reality" {
        let public = take(query, "pbk").ok_or_else(bad)?;
        let short = take(query, "sid").unwrap_or_default();
        value["reality"] = json!({"enabled":true,"public_key":public,"short_id":short});
        if value.get("utls").is_none() {
            value["utls"] = json!({"enabled":true,"fingerprint":"chrome"});
        }
        if let Some(spider) = take(query, "spx") {
            if spider != "/" {
                return Err(bad());
            }
        }
    }
    out["tls"] = value;
    Ok(())
}
fn transport(out: &mut Value, query: &mut BTreeMap<String, String>) -> Result<()> {
    let kind = take(query, "type").unwrap_or_else(|| "tcp".into());
    if let Some(header) = take(query, "headerType") {
        if header != "none" {
            return Err(bad());
        }
    }
    match kind.as_str() {
        "tcp" => (),
        "ws" | "httpupgrade" => {
            let path = take(query, "path").unwrap_or_else(|| "/".into());
            let mut value = json!({"type":kind,"path":path});
            if let Some(host) = take(query, "host") {
                if kind == "ws" {
                    value["headers"] = json!({"Host":host});
                } else {
                    value["host"] = json!(host);
                }
            }
            out["transport"] = value;
        }
        "grpc" => {
            if let Some(mode) = take(query, "mode") {
                if mode != "gun" {
                    return Err(bad());
                }
            }
            out["transport"] =
                json!({"type":"grpc","service_name":take(query,"serviceName").unwrap_or_default()});
        }
        _ => return Err(bad()),
    }
    Ok(())
}
fn vmess(raw: &str) -> Result<Value> {
    let data: Value = serde_json::from_slice(&base64(raw)?).map_err(|_| bad())?;
    let field = |name: &str| -> Result<String> {
        match data.get(name) {
            Some(Value::String(v)) => Ok(v.clone()),
            Some(Value::Number(v)) => Ok(v.to_string()),
            _ => Err(bad()),
        }
    };
    let host = field("add")?;
    let port = field("port")?.parse::<u16>().map_err(|_| bad())?;
    if port == 0 || host.is_empty() {
        return Err(bad());
    }
    let mut out = json!({"type":"vmess","server":host,"server_port":port,"uuid":field("id")?,"security":field("scy").unwrap_or_else(|_| "auto".into())});
    if data.get("aid").is_some() {
        out["alter_id"] = json!(field("aid")?.parse::<u32>().map_err(|_| bad())?);
    }
    if field("type").is_ok_and(|v| !v.is_empty() && v != "none") {
        return Err(bad());
    }
    let mut query = BTreeMap::new();
    for (from, to) in [
        ("net", "type"),
        ("path", "path"),
        ("host", "host"),
        ("sni", "sni"),
        ("alpn", "alpn"),
        ("fp", "fp"),
    ] {
        if let Ok(value) = field(from) {
            if !value.is_empty() {
                query.insert(to.into(), value);
            }
        }
    }
    // v2rayN uses path for the gRPC service name.
    if query.get("type").is_some_and(|v| v == "grpc") {
        if let Some(path) = query.remove("path") {
            query.insert("serviceName".into(), path);
        }
    }
    match field("tls").unwrap_or_default().as_str() {
        "" | "none" => (),
        "tls" => {
            query.insert("security".into(), "tls".into());
        }
        _ => return Err(bad()),
    }
    tls(&mut out, &mut query, false)?;
    transport(&mut out, &mut query)?;
    if !query.is_empty() {
        return Err(bad());
    }
    Ok(out)
}
pub fn link(value: &str) -> Result<Value> {
    if value.len() > MAX_LINK || value.chars().any(char::is_control) {
        return Err(bad());
    }
    let (scheme, tail) = value.split_once("://").ok_or_else(bad)?;
    let tail = tail.split('#').next().ok_or_else(bad)?;
    if scheme == "vmess" {
        return vmess(tail);
    }
    let (authority, query) = tail.split_once('?').unwrap_or((tail, ""));
    let authority = authority.trim_end_matches('/');
    let mut query = params(query)?;
    let (credentials, endpoint) = if scheme == "ss" && !authority.contains('@') {
        let decoded = text(base64(authority)?)?;
        let (user, server) = decoded.rsplit_once('@').ok_or_else(bad)?;
        (user.to_owned(), server.to_owned())
    } else {
        let (user, server) = authority.rsplit_once('@').ok_or_else(bad)?;
        let user = if scheme == "ss" && !user.contains(':') {
            text(base64(&percent(user)?)?)?
        } else {
            percent(user)?
        };
        (user, server.into())
    };
    if credentials.is_empty() {
        return Err(bad());
    }
    let (server, port) = address(
        &endpoint,
        matches!(scheme, "trojan" | "hy2" | "hysteria2" | "anytls").then_some(443),
    )?;
    let protocol = match scheme {
        "ss" => "shadowsocks",
        "hy2" => "hysteria2",
        "vless" | "trojan" | "hysteria2" | "tuic" | "anytls" => scheme,
        _ => return Err(bad()),
    };
    let mut out = json!({"type":protocol,"server":server,"server_port":port});
    match scheme {
        "ss" => {
            let (method, password) = credentials.split_once(':').ok_or_else(bad)?;
            out["method"] = json!(method);
            out["password"] = json!(password);
            if let Some(plugin) = take(&mut query, "plugin") {
                let (name, options) = plugin.split_once(';').unwrap_or((&plugin, ""));
                super::plugin::validate(name, options)?;
                out["plugin"] = json!(name);
                out["plugin_opts"] = json!(options);
            }
        }
        "vless" => {
            out["uuid"] = json!(credentials);
            if let Some(encryption) = take(&mut query, "encryption") {
                if encryption != "none" {
                    return Err(bad());
                }
            }
            if let Some(flow) = take(&mut query, "flow") {
                out["flow"] = json!(flow);
            }
            tls(&mut out, &mut query, false)?;
            transport(&mut out, &mut query)?;
        }
        "tuic" => {
            let (uuid, password) = credentials.split_once(':').ok_or_else(bad)?;
            out["uuid"] = json!(uuid);
            out["password"] = json!(password);
            for key in ["congestion_control", "udp_relay_mode"] {
                if let Some(value) = take(&mut query, key) {
                    out[key] = json!(value);
                }
            }
            tls(&mut out, &mut query, true)?;
        }
        _ => {
            out["password"] = json!(credentials);
            tls(&mut out, &mut query, true)?;
            if matches!(scheme, "hy2" | "hysteria2") {
                if let Some(obfs) = take(&mut query, "obfs") {
                    if obfs != "salamander" {
                        return Err(bad());
                    }
                    out["obfs"] = json!({"type":obfs,"password":take(&mut query,"obfs-password").ok_or_else(bad)?});
                }
            } else if scheme == "trojan" {
                transport(&mut out, &mut query)?;
            }
        }
    }
    if !query.is_empty() {
        return Err(bad());
    }
    Ok(out)
}
/// Normalize JSON, share-link lists and one layer of Base64. Other content is
/// returned for the caller's bounded YAML decoder, including Base64-wrapped YAML.
pub fn document(bytes: &[u8]) -> Result<Vec<u8>> {
    if bytes.len() > 8 * 1024 * 1024 {
        return Err(Error::new(
            "too_large",
            "The subscription exceeds its document limit",
        ));
    }
    let value = std::str::from_utf8(bytes)
        .map_err(|_| bad())?
        .trim_start_matches('\u{feff}')
        .trim();
    if serde_json::from_str::<Value>(value).is_ok() {
        return Ok(value.as_bytes().to_vec());
    }
    let compact: String = value.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    let decoded = if !compact.is_empty()
        && compact
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"+/=_-".contains(&b))
    {
        Some(text(base64(&compact)?)?)
    } else {
        None
    };
    let value = decoded.as_deref().unwrap_or(value).trim();
    if serde_json::from_str::<Value>(value).is_ok() {
        return Ok(value.as_bytes().to_vec());
    }
    if !value.lines().any(|line| {
        [
            "ss://",
            "vmess://",
            "vless://",
            "trojan://",
            "hysteria2://",
            "hy2://",
            "tuic://",
            "anytls://",
        ]
        .iter()
        .any(|prefix| line.trim().starts_with(prefix))
    }) {
        return Ok(value.as_bytes().to_vec());
    }
    let lines: Vec<_> = value
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect();
    if lines.len() > 4096 {
        return Err(Error::new(
            "too_many_nodes",
            "The subscription exceeds 4096 share links",
        ));
    }
    // A bad row is a rejected node, never an invented direct proxy.
    let nodes: Vec<_> = lines
        .into_iter()
        .map(|line| link(line).unwrap_or(Value::Null))
        .collect();
    Ok(serde_json::to_vec(&nodes)?)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn percent_credentials_ipv6_and_unicode_do_not_change_payload() {
        let out =
            link("trojan://p%40ss%2B%3A%E6%97%A5@[2001:db8::1]:443?sni=edge.test#日本😀").unwrap();
        assert_eq!(out["password"], "p@ss+:日");
        assert_eq!(out["server"], "2001:db8::1");
    }
    #[test]
    fn both_shadowsocks_encodings_and_plugin_are_understood() {
        for value in [
            format!(
                "ss://{}@example.test:443",
                b64::STANDARD_NO_PAD.encode("aes-128-gcm:p@ss")
            ),
            format!(
                "ss://{}",
                b64::STANDARD.encode("aes-128-gcm:p@ss@example.test:443")
            ),
        ] {
            assert_eq!(link(&value).unwrap()["password"], "p@ss");
        }
        assert_eq!(
            link("ss://aes-128-gcm:password@example.test:443/?plugin=obfs-local%3Bobfs%3Dhttp")
                .unwrap()["plugin_opts"],
            "obfs=http"
        );
    }
    #[test]
    fn vless_reality_grpc_and_hysteria_salamander_are_explicit() {
        let out=link("vless://id@example.test:443?security=reality&pbk=key&sid=abcd&fp=chrome&type=grpc&serviceName=svc&encryption=none").unwrap();
        assert_eq!(out["tls"]["reality"]["public_key"], "key");
        assert_eq!(out["transport"]["service_name"], "svc");
        assert_eq!(
            link("hy2://p@example.test?obfs=salamander&obfs-password=s").unwrap()["obfs"]
                ["password"],
            "s"
        );
    }
    #[test]
    fn vmess_string_numbers_and_websocket_convert_without_name_identity() {
        let body = json!({"v":"2","ps":"日本","add":"example.test","port":"443","id":"id","aid":"0","net":"ws","type":"none","host":"edge.test","path":"/ws","tls":"tls","sni":"edge.test"});
        let out = link(&format!(
            "vmess://{}",
            b64::STANDARD.encode(serde_json::to_vec(&body).unwrap())
        ))
        .unwrap();
        assert_eq!(out["server_port"], 443);
        assert_eq!(out["transport"]["headers"]["Host"], "edge.test");
        assert!(out.get("ps").is_none());
    }
    #[test]
    fn base64_feed_accepts_crlf_and_records_bad_rows() {
        let encoded =
            b64::URL_SAFE_NO_PAD.encode("trojan://p@example.test:443\r\nvless://broken\r\n");
        let normalized = document(encoded.as_bytes()).unwrap();
        let result =
            super::super::parse_json(&normalized, "0123456789abcdef0123456789abcdef").unwrap();
        assert_eq!(result.nodes.len(), 1);
        assert_eq!(result.rejected, 1);
        let yaml = b"proxies:\n  - type: trojan";
        assert_eq!(document(yaml).unwrap(), yaml);
        assert_eq!(
            document(b64::STANDARD.encode(yaml).as_bytes()).unwrap(),
            yaml
        );
    }
    #[test]
    fn corrupt_ports_escapes_duplicate_parameters_and_unknown_transports_fail() {
        for url in [
            "trojan://p@x:0",
            "trojan://p@x:65536",
            "trojan://p%ZZ@x:443",
            "trojan://p%0A@x:443",
            "vless://id@x:443?type=ws&type=tcp",
            "vless://id@x:443?type=xhttp",
            "vless://id@x:443?security=none&pbk=key",
            "ss://aes:p@x:443?plugin=/bin/sh",
        ] {
            assert!(link(url).is_err(), "{url}");
        }
    }
}
