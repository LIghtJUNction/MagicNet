use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::process::Command;

use serde_json::{json, Map, Value};

use crate::service::restart_current_core;
use crate::{run_magicnet_function, write_secret_file, write_text_file, App};

const WARP_CONF: &str = ".config/magicnet/warp.conf";
const WARP_ENDPOINT: &str = ".config/magicnet/warp-endpoint.json";

pub(crate) fn warp_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            warp_status(app);
            Ok(())
        }
        "import-file" => import_file(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "enable" => set_enabled(app, true),
        "disable" => set_enabled(app, false),
        "global" => select_final(app, "warp"),
        "rule" => select_final(app, "proxy"),
        "apply" => apply_and_restart(app),
        "test" => test_warp(app),
        _ => Err(warp_usage()),
    }
}

fn warp_status(app: &App) {
    let enabled = warp_enabled(app);
    let endpoint = read_endpoint(app);
    println!("enabled={}", enabled as u8);
    println!("configured={}", endpoint.is_some() as u8);
    if let Some(endpoint) = endpoint {
        println!(
            "tag={}",
            endpoint
                .get("tag")
                .and_then(Value::as_str)
                .unwrap_or("warp")
        );
        println!(
            "type={}",
            endpoint
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("wireguard")
        );
        if let Some(addresses) = endpoint.get("address").and_then(Value::as_array) {
            println!("addresses={}", addresses.len());
        }
        if let Some(peer) = endpoint
            .get("peers")
            .and_then(Value::as_array)
            .and_then(|peers| peers.first())
        {
            println!(
                "endpoint={}:{}",
                peer.get("address").and_then(Value::as_str).unwrap_or(""),
                peer.get("port").and_then(Value::as_u64).unwrap_or(0)
            );
            if let Some(allowed) = peer.get("allowed_ips").and_then(Value::as_array) {
                println!("allowed_ips={}", allowed.len());
            }
        }
    }
}

fn import_file(app: &App, path: &str) -> Result<(), String> {
    if path.is_empty() {
        return Err(warp_usage());
    }
    let text =
        fs::read_to_string(Path::new(path)).map_err(|err| format!("read WARP config: {err}"))?;
    let endpoint = parse_wireguard_config(&text)?;
    let pretty = serde_json::to_string_pretty(&endpoint).map_err(|err| err.to_string())?;
    // Holds the WireGuard private key + PSK — keep it 0600, not umask-default.
    write_secret_file(app, Path::new(WARP_ENDPOINT), &format!("{pretty}\n"))?;
    write_enabled(app, true)?;
    apply_and_restart(app)?;
    println!("[info] WARP WireGuard config imported");
    Ok(())
}

fn set_enabled(app: &App, enabled: bool) -> Result<(), String> {
    if enabled && read_endpoint(app).is_none() {
        return Err("WARP is not configured. Import a WireGuard config first.".to_string());
    }
    write_enabled(app, enabled)?;
    apply_and_restart(app)?;
    println!(
        "[info] WARP {}",
        if enabled { "enabled" } else { "disabled" }
    );
    Ok(())
}

fn apply_and_restart(app: &App) -> Result<(), String> {
    run_magicnet_function(app, "magicnet_warp_apply")?;
    restart_current_core(app)
}

fn test_warp(app: &App) -> Result<(), String> {
    if !warp_enabled(app) || read_endpoint(app).is_none() {
        return Err("WARP is not enabled and configured.".to_string());
    }
    let output = Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            "20",
            "--max-filesize",
            "1048576",
            "-x",
            "http://127.0.0.1:7892",
            "https://www.cloudflare.com/cdn-cgi/trace",
        ])
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        return Err(format!("WARP test failed: {}", stderr.trim()));
    }
    let filtered = stdout
        .lines()
        .filter(|line| {
            line.starts_with("warp=")
                || line.starts_with("colo=")
                || line.starts_with("loc=")
                || line.starts_with("ip=")
        })
        .collect::<Vec<_>>()
        .join("\n");
    println!("{}", filtered.trim());
    Ok(())
}

fn select_final(app: &App, outbound: &str) -> Result<(), String> {
    let payload = format!(r#"{{"name":"{outbound}"}}"#);
    let endpoint = format!("{}/proxies/final", app.api);
    let output = Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            "5",
            "--max-filesize",
            "1048576",
            "-X",
            "PUT",
            "-H",
            "Content-Type: application/json",
            "--data",
            &payload,
            &endpoint,
        ])
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    if output.status.success() {
        println!("[info] final selector set to {outbound}");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!("select final outbound failed: {}", stderr.trim()))
    }
}

fn warp_enabled(app: &App) -> bool {
    fs::read_to_string(app.moddir.join(WARP_CONF))
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let (_, value) = line.split_once('=')?;
                (line.trim_start().starts_with("MAGICNET_WARP_ENABLED=")).then(|| {
                    matches!(
                        value.trim().trim_matches('"').trim_matches('\''),
                        "1" | "true" | "yes" | "on"
                    )
                })
            })
        })
        .unwrap_or(false)
}

fn write_enabled(app: &App, enabled: bool) -> Result<(), String> {
    write_text_file(
        app,
        Path::new(WARP_CONF),
        &format!("MAGICNET_WARP_ENABLED={}\n", enabled as u8),
    )
}

fn read_endpoint(app: &App) -> Option<Value> {
    let text = fs::read_to_string(app.moddir.join(WARP_ENDPOINT)).ok()?;
    serde_json::from_str(&text).ok()
}

fn parse_wireguard_config(text: &str) -> Result<Value, String> {
    let mut current = "";
    let mut iface = HashMap::new();
    let mut peer = HashMap::new();
    for raw in text.lines() {
        let line = raw
            .split('#')
            .next()
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            current = line.trim_matches(&['[', ']'][..]).trim();
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim().to_string();
        match current {
            "Interface" => {
                iface.insert(key, value);
            }
            "Peer" => {
                peer.insert(key, value);
            }
            _ => {}
        }
    }

    let private_key = require_field(&iface, "privatekey")?;
    let addresses = split_csv(require_field(&iface, "address")?);
    let public_key = require_field(&peer, "publickey")?;
    let endpoint = require_field(&peer, "endpoint")?;
    let (server, port) = parse_endpoint(endpoint)?;
    let allowed_ips = split_csv(
        peer.get("allowedips")
            .map(String::as_str)
            .unwrap_or("0.0.0.0/0, ::/0"),
    );
    let mtu = iface
        .get("mtu")
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(1280);
    let keepalive = peer
        .get("persistentkeepalive")
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(30);

    let mut peer_obj = Map::new();
    peer_obj.insert("address".to_string(), json!(server));
    peer_obj.insert("port".to_string(), json!(port));
    peer_obj.insert("public_key".to_string(), json!(public_key));
    peer_obj.insert("allowed_ips".to_string(), json!(allowed_ips));
    peer_obj.insert(
        "persistent_keepalive_interval".to_string(),
        json!(keepalive),
    );
    if let Some(psk) = peer.get("presharedkey").filter(|value| !value.is_empty()) {
        peer_obj.insert("pre_shared_key".to_string(), json!(psk));
    }
    if let Some(reserved) = peer
        .get("reserved")
        .and_then(|value| parse_reserved(value).ok())
    {
        peer_obj.insert("reserved".to_string(), json!(reserved));
    }

    Ok(json!({
        "type": "wireguard",
        "tag": "warp",
        "system": false,
        "mtu": mtu,
        "address": addresses,
        "private_key": private_key,
        "peers": [Value::Object(peer_obj)]
    }))
}

fn require_field<'a>(map: &'a HashMap<String, String>, key: &str) -> Result<&'a str, String> {
    map.get(key)
        .map(String::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing WireGuard field: {key}"))
}

fn split_csv(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn parse_endpoint(value: &str) -> Result<(String, u16), String> {
    if let Some(rest) = value.strip_prefix('[') {
        let Some((host, port)) = rest.split_once("]:") else {
            return Err(format!("invalid endpoint: {value}"));
        };
        return Ok((host.to_string(), parse_port(port)?));
    }
    let Some((host, port)) = value.rsplit_once(':') else {
        return Err(format!("invalid endpoint: {value}"));
    };
    Ok((host.to_string(), parse_port(port)?))
}

fn parse_port(value: &str) -> Result<u16, String> {
    value
        .parse::<u16>()
        .map_err(|_| format!("invalid endpoint port: {value}"))
}

fn parse_reserved(value: &str) -> Result<Vec<u8>, String> {
    let values = split_csv(value)
        .into_iter()
        .map(|item| {
            item.parse::<u8>()
                .map_err(|_| format!("invalid reserved byte: {item}"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if values.len() == 3 {
        Ok(values)
    } else {
        Err("reserved must contain three bytes".to_string())
    }
}

fn warp_usage() -> String {
    "Usage: cli warp {status|import-file <wireguard-conf-path>|enable|disable|global|rule|apply|test}"
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wireguard_config_as_endpoint() {
        let endpoint = parse_wireguard_config(
            r#"
[Interface]
PrivateKey = private
Address = 172.16.0.2/32, 2606:4700:110:abcd::2/128
MTU = 1280

[Peer]
PublicKey = public
Endpoint = engage.cloudflareclient.com:2408
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
Reserved = 1, 2, 3
"#,
        )
        .unwrap();
        assert_eq!(endpoint["tag"], "warp");
        assert_eq!(
            endpoint["peers"][0]["address"],
            "engage.cloudflareclient.com"
        );
        assert_eq!(endpoint["peers"][0]["port"], 2408);
        assert_eq!(endpoint["peers"][0]["reserved"][2], 3);
    }
}
