//! Node-only Clash conversion against the pinned core's option structures.
//! Unsupported security/transport fields reject the node instead of downgrading it.
use kamfw::{Error, Result};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

fn bad() -> Error {
    Error::new(
        "unsupported_node",
        "The Clash node has unsupported or invalid fields",
    )
}
fn string(value: Value) -> Result<String> {
    value.as_str().map(String::from).ok_or_else(bad)
}
fn boolean(value: Value) -> Result<bool> {
    value.as_bool().ok_or_else(bad)
}
fn rename(source: &mut Map<String, Value>, out: &mut Value, fields: &[(&str, &str)]) {
    for &(from, to) in fields {
        if let Some(value) = source.remove(from) {
            out[to] = value;
        }
    }
}
fn finished(source: &Map<String, Value>) -> Result<()> {
    if source.is_empty() {
        Ok(())
    } else {
        Err(bad())
    }
}

pub(super) fn convert(node: &Value) -> Result<Value> {
    let mut fields = node.as_object().ok_or_else(bad)?.clone();
    let kind = string(fields.remove("type").ok_or_else(bad)?)?;
    let protocol = match kind.as_str() {
        "ss" => "shadowsocks",
        "socks5" => "socks",
        "http" | "vmess" | "vless" | "trojan" | "hysteria2" | "tuic" | "anytls" => &kind,
        _ => return Err(bad()),
    };
    let mut out = json!({"type":protocol, "server":fields.remove("server").ok_or_else(bad)?, "server_port":fields.remove("port").ok_or_else(bad)?});
    fields.remove("name");
    rename(
        &mut fields,
        &mut out,
        &[("tfo", "tcp_fast_open"), ("mptcp", "tcp_multi_path")],
    );
    if let Some(udp) = fields.remove("udp") {
        if !boolean(udp)? {
            out["network"] = json!("tcp");
        }
    }
    match kind.as_str() {
        "ss" => {
            rename(
                &mut fields,
                &mut out,
                &[
                    ("cipher", "method"),
                    ("password", "password"),
                    ("udp-over-tcp", "udp_over_tcp"),
                ],
            );
            if let Some(name) = fields.remove("plugin") {
                plugin(string(name)?, &mut fields, &mut out)?;
            }
        }
        "vmess" | "vless" => {
            rename(
                &mut fields,
                &mut out,
                &[("uuid", "uuid"), ("packet-encoding", "packet_encoding")],
            );
            if kind == "vmess" {
                out["security"] = fields.remove("cipher").unwrap_or(json!("auto"));
                rename(
                    &mut fields,
                    &mut out,
                    &[
                        ("alterId", "alter_id"),
                        ("global-padding", "global_padding"),
                        ("authenticated-length", "authenticated_length"),
                    ],
                );
            } else {
                rename(&mut fields, &mut out, &[("flow", "flow")]);
                if let Some(encryption) = fields.remove("encryption") {
                    if !matches!(string(encryption)?.as_str(), "" | "none") {
                        return Err(bad());
                    }
                }
            }
        }
        "tuic" => rename(
            &mut fields,
            &mut out,
            &[
                ("uuid", "uuid"),
                ("password", "password"),
                ("congestion-controller", "congestion_control"),
                ("udp-relay-mode", "udp_relay_mode"),
                ("reduce-rtt", "zero_rtt_handshake"),
            ],
        ),
        "http" | "socks5" => {
            rename(
                &mut fields,
                &mut out,
                &[("username", "username"), ("password", "password")],
            );
            if kind == "socks5" {
                out["version"] = json!("5");
            }
        }
        _ => rename(&mut fields, &mut out, &[("password", "password")]),
    }
    if kind == "hysteria2" {
        for (from, to) in [("up", "up_mbps"), ("down", "down_mbps")] {
            if let Some(value) = fields.remove(from) {
                let number = value
                    .as_u64()
                    .or_else(|| value.as_str().and_then(|s| s.parse::<u64>().ok()))
                    .ok_or_else(bad)?;
                if number > u32::MAX as u64 {
                    return Err(bad());
                }
                out[to] = json!(number);
            }
        }
        if let Some(value) = fields.remove("obfs") {
            if string(value)? != "salamander" {
                return Err(bad());
            }
            out["obfs"] = json!({"type":"salamander", "password":fields.remove("obfs-password").ok_or_else(bad)?});
        }
    }
    tls(
        &mut fields,
        &mut out,
        matches!(kind.as_str(), "trojan" | "hysteria2" | "tuic" | "anytls"),
    )?;
    transport(&mut fields, &mut out)?;
    if let Some(smux) = fields.remove("smux") {
        let mut smux = smux.as_object().ok_or_else(bad)?.clone();
        let mut multiplex = json!({});
        rename(
            &mut smux,
            &mut multiplex,
            &[
                ("enabled", "enabled"),
                ("protocol", "protocol"),
                ("max-connections", "max_connections"),
                ("min-streams", "min_streams"),
                ("max-streams", "max_streams"),
                ("padding", "padding"),
            ],
        );
        finished(&smux)?;
        out["multiplex"] = multiplex;
    }
    finished(&fields)?;
    Ok(out)
}
fn tls(fields: &mut Map<String, Value>, out: &mut Value, default: bool) -> Result<()> {
    let enabled = fields
        .remove("tls")
        .map(boolean)
        .transpose()?
        .unwrap_or(default);
    if !enabled {
        return Ok(());
    }
    let mut value = json!({"enabled":true});
    let server = fields.remove("servername");
    let sni = fields.remove("sni");
    if server.is_some() && sni.is_some() && server != sni {
        return Err(bad());
    }
    if let Some(server) = server.or(sni) {
        value["server_name"] = server;
    }
    rename(
        fields,
        &mut value,
        &[("skip-cert-verify", "insecure"), ("alpn", "alpn")],
    );
    if let Some(fingerprint) = fields.remove("client-fingerprint") {
        value["utls"] = json!({"enabled":true,"fingerprint":string(fingerprint)?});
    }
    if let Some(reality) = fields.remove("reality-opts") {
        let mut reality = reality.as_object().ok_or_else(bad)?.clone();
        let public = string(reality.remove("public-key").ok_or_else(bad)?)?;
        let short = reality
            .remove("short-id")
            .map(string)
            .transpose()?
            .unwrap_or_default();
        finished(&reality)?;
        value["reality"] = json!({"enabled":true,"public_key":public,"short_id":short});
        if value.get("utls").is_none() {
            value["utls"] = json!({"enabled":true,"fingerprint":"chrome"});
        }
    }
    out["tls"] = value;
    Ok(())
}
fn transport(fields: &mut Map<String, Value>, out: &mut Value) -> Result<()> {
    let network = fields
        .remove("network")
        .map(string)
        .transpose()?
        .unwrap_or_else(|| "tcp".into());
    let (kind, key, names): (&str, &str, &[(&str, &str)]) = match network.as_str() {
        "tcp" => return Ok(()),
        "ws" => (
            "ws",
            "ws-opts",
            &[
                ("path", "path"),
                ("headers", "headers"),
                ("max-early-data", "max_early_data"),
                ("early-data-header-name", "early_data_header_name"),
            ],
        ),
        "grpc" => (
            "grpc",
            "grpc-opts",
            &[("grpc-service-name", "service_name")],
        ),
        "h2" => ("http", "h2-opts", &[("host", "host"), ("path", "path")]),
        _ => return Err(bad()),
    };
    let mut opts = fields
        .remove(key)
        .map(|v| v.as_object().cloned().ok_or_else(bad))
        .transpose()?
        .unwrap_or_default();
    let mut value = json!({"type":kind});
    rename(&mut opts, &mut value, names);
    finished(&opts)?;
    out["transport"] = value;
    Ok(())
}
fn plugin(name: String, fields: &mut Map<String, Value>, out: &mut Value) -> Result<()> {
    let name = if name == "obfs" { "obfs-local" } else { &name };
    let mut opts = fields
        .remove("plugin-opts")
        .map(|v| v.as_object().cloned().ok_or_else(bad))
        .transpose()?
        .unwrap_or_default();
    let mut pairs = BTreeMap::new();
    for (from, to) in if name == "obfs-local" {
        vec![("mode", "obfs"), ("host", "obfs-host")]
    } else {
        vec![("mode", "mode"), ("host", "host"), ("path", "path")]
    } {
        if let Some(value) = opts.remove(from) {
            pairs.insert(to.into(), string(value)?);
        }
    }
    if name == "v2ray-plugin" {
        if let Some(tls) = opts.remove("tls") {
            if boolean(tls)? {
                pairs.insert("tls".into(), "1".into());
            }
        }
        if let Some(mux) = opts.remove("mux") {
            pairs.insert("mux".into(), if boolean(mux)? { "1" } else { "0" }.into());
        }
    }
    finished(&opts)?;
    let encoded = super::plugin::encode(&pairs);
    super::plugin::validate(name, &encoded)?;
    out["plugin"] = json!(name);
    out["plugin_opts"] = json!(encoded);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(kind: &str) -> Value {
        json!({"type":kind,"server":"example.test","port":443})
    }
    #[test]
    fn reality_and_websocket_retain_tls_and_transport() {
        let mut n = node("vless");
        n["uuid"] = json!("id");
        n["tls"] = json!(true);
        n["reality-opts"] = json!({"public-key":"key","short-id":"abcd"});
        n["network"] = json!("ws");
        n["ws-opts"] = json!({"path":"/ws","headers":{"Host":"edge.test"}});
        let out = convert(&n).unwrap();
        assert_eq!(out["tls"]["reality"]["public_key"], "key");
        assert_eq!(out["transport"]["headers"]["Host"], "edge.test");
    }
    #[test]
    fn obfs_and_v2ray_plugin_fields_are_encoded_not_dropped() {
        for (plugin, options) in [
            ("obfs", json!({"mode":"tls","host":"edge.test"})),
            (
                "v2ray-plugin",
                json!({"mode":"websocket","path":"/ws;cert=/not-file","tls":true,"mux":false}),
            ),
        ] {
            let mut n = node("ss");
            n["cipher"] = json!("aes-128-gcm");
            n["password"] = json!("p");
            n["plugin"] = json!(plugin);
            n["plugin-opts"] = options;
            let out = convert(&n).unwrap();
            super::super::plugin::validate(
                out["plugin"].as_str().unwrap(),
                out["plugin_opts"].as_str().unwrap(),
            )
            .unwrap();
        }
    }
    #[test]
    fn unsupported_security_must_not_silently_become_plain_tcp() {
        for (key, value) in [
            ("network", json!("xhttp")),
            ("fingerprint", json!("certificate-hash")),
            ("reality-opts", json!({"public-key":"key"})),
            ("encryption", json!("mlkem")),
            ("dialer-proxy", json!("private-route")),
        ] {
            let mut n = node("vless");
            n[key] = value;
            assert!(convert(&n).is_err(), "{key}");
        }
    }
    #[test]
    fn quic_credentials_bandwidth_and_smux_are_structural() {
        let mut n = node("hysteria2");
        n["password"] = json!("p");
        n["obfs"] = json!("salamander");
        n["obfs-password"] = json!("s");
        n["up"] = json!("50");
        assert_eq!(convert(&n).unwrap()["up_mbps"], 50);
        let mut n = node("tuic");
        n["uuid"] = json!("id");
        n["password"] = json!("p");
        n["congestion-controller"] = json!("bbr");
        assert_eq!(convert(&n).unwrap()["congestion_control"], "bbr");
        let mut n = node("vmess");
        n["smux"] = json!({"enabled":true,"protocol":"h2mux","max-connections":2});
        assert_eq!(convert(&n).unwrap()["multiplex"]["max_connections"], 2);
    }
}
