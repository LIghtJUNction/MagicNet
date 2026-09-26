//! Structural node-only import. A provider can never replace listeners,
//! routing, local file paths, or authentication settings through a refresh.
use kamfw::{Error, Result};
use serde_json::{json, Value};
use std::collections::BTreeSet;

mod clash;
mod plugin;
pub mod share;

const ALLOWED: &[&str] = &[
    "shadowsocks",
    "vmess",
    "vless",
    "trojan",
    "hysteria",
    "hysteria2",
    "tuic",
    "anytls",
    "socks",
    "http",
    "ssh",
    "wireguard",
];
#[derive(Debug)]
pub struct Parsed {
    pub nodes: Vec<Value>,
    pub rejected: usize,
}

fn private_field(value: &Value, depth: usize) -> bool {
    if depth > 16 {
        return true;
    }
    match value {
        Value::Object(object) => object.iter().any(|(key, value)| {
            matches!(
                key.as_str(),
                "certificate_path"
                    | "key_path"
                    | "private_key_path"
                    | "known_hosts_path"
                    | "client_certificate_path"
                    | "client_key_path"
                    | "bind_interface"
                    | "routing_mark"
                    | "detour"
            ) || key.ends_with("_path")
                || private_field(value, depth + 1)
        }),
        Value::Array(values) => values.iter().any(|value| private_field(value, depth + 1)),
        _ => false,
    }
}

pub fn parse_json(bytes: &[u8], source_id: &str) -> Result<Parsed> {
    if !kamfw::fs::valid_id(source_id) || bytes.len() > 8 * 1024 * 1024 {
        return Err(Error::new(
            "invalid_source",
            "The source identity or size is invalid",
        ));
    }
    let value: Value = serde_json::from_slice(bytes).map_err(|_| {
        Error::new(
            "invalid_subscription",
            "The subscription is not a valid JSON document",
        )
    })?;
    let (nodes, clash) = if let Some(list) = value.as_array() {
        (list, false)
    } else if let Some(list) = value.get("outbounds").and_then(Value::as_array) {
        (list, false)
    } else if let Some(list) = value.get("proxies").and_then(Value::as_array) {
        (list, true)
    } else {
        return Err(Error::new(
            "invalid_subscription",
            "The subscription must contain an outbounds or proxies array",
        ));
    };
    if nodes.len() > 4096 {
        return Err(Error::new(
            "too_many_nodes",
            "The subscription exceeds the node limit",
        ));
    }
    let mut result = Parsed {
        nodes: Vec::new(),
        rejected: 0,
    };
    let mut seen = BTreeSet::new();
    for node in nodes {
        let candidate = if clash {
            clash::convert(node)
        } else {
            Ok(node.clone())
        };
        let Ok(mut candidate) = candidate else {
            result.rejected += 1;
            continue;
        };
        let protocol = candidate.get("type").and_then(Value::as_str).unwrap_or("");
        if !ALLOWED.contains(&protocol)
            || private_field(&candidate, 0)
            || candidate.get("plugin").is_some_and(|name| {
                !name.as_str().is_some_and(|name| {
                    candidate
                        .get("plugin_opts")
                        .map_or(Some(""), Value::as_str)
                        .is_some_and(|opts| plugin::validate(name, opts).is_ok())
                })
            })
            || (candidate.get("plugin_opts").is_some() && candidate.get("plugin").is_none())
            || !candidate
                .get("server")
                .and_then(Value::as_str)
                .is_some_and(|s| {
                    !s.is_empty() && s.len() <= 253 && !s.chars().any(char::is_control)
                })
            || !candidate
                .get("server_port")
                .and_then(Value::as_u64)
                .is_some_and(|p| p > 0 && p <= 65535)
        {
            result.rejected += 1;
            continue;
        }
        let object = candidate
            .as_object_mut()
            .ok_or_else(|| Error::new("invalid_node", "A node is not an object"))?;
        object.remove("tag");
        object.remove("name");
        // Identity is derived from semantic transport data, not a provider's
        // translated display label. Duplicate names cannot collide with tags.
        let digest = kamfw::sha256(&serde_json::to_vec(&candidate)?);
        if !seen.insert(digest.clone()) {
            continue;
        }
        candidate["tag"] = json!(format!("mn-{}-{}", source_id, &digest[..16]));
        result.nodes.push(candidate);
    }
    if result.nodes.is_empty() {
        return Err(Error::new(
            "no_supported_nodes",
            "No safe, supported nodes were found; the active configuration was not replaced",
        ));
    }
    Ok(result)
}

pub fn attach(template: &Value, node_sets: &[Value]) -> Result<Value> {
    let mut config = template.clone();
    let outbounds = config
        .get_mut("outbounds")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| {
            Error::new(
                "invalid_config",
                "The template must have an outbounds array",
            )
        })?;
    // Only the namespace generated by this importer is replaced. User-owned
    // static nodes and selectors remain byte-equivalent as JSON values.
    outbounds.retain(|node| {
        !node
            .get("tag")
            .and_then(Value::as_str)
            .is_some_and(|s| s.starts_with("mn-"))
    });
    let mut tags: BTreeSet<String> = outbounds
        .iter()
        .filter_map(|node| node.get("tag").and_then(Value::as_str).map(String::from))
        .collect();
    let mut imported = Vec::new();
    for nodes in node_sets {
        let nodes = nodes
            .as_array()
            .ok_or_else(|| Error::new("invalid_cache", "The node cache is not an array"))?;
        for node in nodes {
            let tag = node
                .get("tag")
                .and_then(Value::as_str)
                .ok_or_else(|| Error::new("invalid_cache", "A node is missing its identity"))?;
            if !tag.starts_with("mn-") || !tags.insert(tag.into()) {
                continue;
            }
            imported.push(Value::String(tag.into()));
            outbounds.push(node.clone());
        }
    }
    if let Some(selector) = outbounds.iter_mut().find(|node| {
        node.get("tag").and_then(Value::as_str) == Some("proxy")
            && node.get("type").and_then(Value::as_str) == Some("selector")
    }) {
        let choices = selector
            .get_mut("outbounds")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| {
                Error::new(
                    "invalid_config",
                    "The proxy selector needs an outbounds array",
                )
            })?;
        choices.retain(|tag| !tag.as_str().is_some_and(|tag| tag.starts_with("mn-")));
        choices.extend(imported);
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "0123456789abcdef0123456789abcdef";
    #[test]
    fn provider_cannot_replace_routes_or_supply_private_files() {
        let parsed = parse_json(br#"{"route":{"final":"evil"},"inbounds":[{"type":"tun"}],"outbounds":[{"type":"trojan","server":"example.test","server_port":443,"password":"p"},{"type":"ssh","server":"example.test","server_port":22,"private_key_path":"/etc/key"}]}"#, ID).unwrap();
        assert_eq!(parsed.nodes.len(), 1);
        assert_eq!(parsed.rejected, 1);
        assert!(parsed.nodes[0].get("route").is_none());
    }
    #[test]
    fn clash_websocket_unicode_and_stable_identity() {
        let data = r#"{"proxies":[{"name":"日本😀","type":"vmess","server":"example.test","port":443,"uuid":"x","cipher":"auto","tls":true,"network":"ws","ws-opts":{"path":"/p","headers":{"Host":"example.test"}}}]}"#;
        let first = parse_json(data.as_bytes(), ID).unwrap();
        let second = parse_json(data.replace("日本😀", "renamed").as_bytes(), ID).unwrap();
        assert_eq!(first.nodes, second.nodes);
        assert_eq!(first.nodes[0]["transport"]["path"], "/p");
    }
    #[test]
    fn unsafe_empty_and_unsupported_documents_fail() {
        for data in [
            b"null".as_slice(),
            br#"{"proxies":[]}"#,
            br#"{"outbounds":[{"type":"direct"}]}"#,
        ] {
            assert!(parse_json(data, ID).is_err());
        }
    }
    #[test]
    fn replacement_drops_old_managed_nodes_not_user_nodes() {
        let template = json!({"outbounds":[{"type":"selector","tag":"proxy","outbounds":["static","mn-old"]},{"tag":"static","type":"direct"},{"tag":"mn-old","type":"trojan"}]});
        let config = attach(&template, &[json!([{"tag":"mn-new","type":"trojan"}])]).unwrap();
        assert_eq!(
            config["outbounds"][0]["outbounds"],
            json!(["static", "mn-new"])
        );
        assert_eq!(config["outbounds"].as_array().unwrap().len(), 3);
    }
}
