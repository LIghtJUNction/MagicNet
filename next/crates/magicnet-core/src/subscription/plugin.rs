//! Only in-process SIP003 implementations are permitted in remote node data.
//! Validate decoded option keys too: `cert=/private/file` is not a JSON key.
use kamfw::{Error, Result};
use std::collections::BTreeMap;

fn bad() -> Error {
    Error::new(
        "unsupported_plugin",
        "The plugin or its options cannot be safely imported",
    )
}
fn options(value: &str) -> Result<BTreeMap<String, String>> {
    if value.len() > 8192 || value.chars().any(char::is_control) {
        return Err(bad());
    }
    let mut result = BTreeMap::new();
    let mut chars = value.chars().peekable();
    while chars.peek().is_some() {
        let (mut key, mut value, mut has_value) = (String::new(), String::new(), false);
        while let Some(c) = chars.next() {
            let literal = if c == '\\' {
                Some(chars.next().ok_or_else(bad)?)
            } else {
                None
            };
            if let Some(c) = literal {
                if has_value {
                    value.push(c);
                } else {
                    key.push(c);
                }
            } else if c == ';' {
                break;
            } else if c == '=' && !has_value {
                has_value = true;
            } else if has_value {
                value.push(c);
            } else {
                key.push(c);
            }
        }
        if !has_value {
            value = "1".into();
        }
        if key.is_empty() || result.len() >= 16 || result.insert(key, value).is_some() {
            return Err(bad());
        }
    }
    Ok(result)
}
pub(super) fn validate(name: &str, value: &str) -> Result<()> {
    let fields = options(value)?;
    for (key, value) in &fields {
        let valid = match (name, key.as_str()) {
            ("obfs-local", "obfs") => matches!(value.as_str(), "http" | "tls"),
            ("obfs-local", "obfs-host") | ("v2ray-plugin", "host") => {
                !value.is_empty() && value.len() <= 253
            }
            ("v2ray-plugin", "mode") => matches!(value.as_str(), "websocket" | "quic"),
            ("v2ray-plugin", "path") => value.starts_with('/'),
            ("v2ray-plugin", "tls") => value == "1" || value.is_empty(),
            ("v2ray-plugin", "mux") => value.parse::<u16>().is_ok(),
            _ => false,
        };
        if !valid {
            return Err(bad());
        }
    }
    if !matches!(name, "obfs-local" | "v2ray-plugin") {
        return Err(bad());
    }
    Ok(())
}
pub(super) fn encode(fields: &BTreeMap<String, String>) -> String {
    let escape = |s: &str| {
        s.replace('\\', "\\\\")
            .replace(';', "\\;")
            .replace('=', "\\=")
    };
    fields
        .iter()
        .map(|(key, value)| format!("{}={}", escape(key), escape(value)))
        .collect::<Vec<_>>()
        .join(";")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cert_paths_duplicates_and_unknown_plugins_are_rejected() {
        for (plugin, opts) in [
            ("/bin/sh", ""),
            ("v2ray-plugin", "cert=/private/key"),
            ("v2ray-plugin", "ce\\rt=/private/key"),
            ("v2ray-plugin", "tls=0"),
            ("obfs-local", "obfs=http;obfs=tls"),
            ("v2ray-plugin", "mode=unknown"),
        ] {
            assert!(validate(plugin, opts).is_err());
        }
    }
    #[test]
    fn escaped_values_roundtrip_without_becoming_options() {
        let input = BTreeMap::from([
            ("host".into(), "edge.test".into()),
            ("path".into(), "/ws;cert=/not-a-file".into()),
        ]);
        let encoded = encode(&input);
        assert_eq!(options(&encoded).unwrap(), input);
        validate("v2ray-plugin", &encoded).unwrap();
    }
}
