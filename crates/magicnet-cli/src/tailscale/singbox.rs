use std::fs;

use serde_json::{json, Value as JsonValue};

use crate::tailscale::{TailscaleConfig, TS_DNS, TS_ENDPOINT, TS_TAG};
use crate::App;

pub(crate) fn apply_singbox(app: &App, cfg: &TailscaleConfig) -> Result<(), String> {
    let path = app.moddir.join(".config/sing-box/config.json");
    let text = fs::read_to_string(&path).map_err(|err| format!("read sing-box config: {err}"))?;
    let mut root: JsonValue =
        serde_json::from_str(&text).map_err(|err| format!("parse sing-box config: {err}"))?;

    if cfg.enabled {
        let root_object = root
            .as_object_mut()
            .ok_or_else(|| "sing-box config root must be a JSON object".to_string())?;
        ensure_json_array(root_object, "endpoints")?.push(json!({
            "type": "tailscale",
            "tag": TS_ENDPOINT,
            "auth_key": cfg.auth_key,
            "state_directory": cfg.state_dir,
            "hostname": cfg.hostname,
            "accept_routes": cfg.accept_routes
        }));
        dedupe_json_tag(json_array_mut(&mut root, "endpoints")?, TS_ENDPOINT);
        ensure_dns_server(&mut root, cfg)?;
        ensure_outbound(&mut root)?;
        ensure_routes(&mut root, &cfg.subnets)?;
    } else {
        remove_json_tag(&mut root, "endpoints", TS_ENDPOINT);
        remove_json_tag(&mut root["dns"], "servers", TS_DNS);
        remove_json_tag(&mut root, "outbounds", TS_TAG);
        remove_routes(&mut root);
    }

    let text = serde_json::to_string_pretty(&root).map_err(|err| format!("write JSON: {err}"))?;
    fs::write(path, format!("{text}\n")).map_err(|err| format!("save sing-box config: {err}"))
}

fn ensure_json_array<'a>(
    object: &'a mut serde_json::Map<String, JsonValue>,
    key: &str,
) -> Result<&'a mut Vec<JsonValue>, String> {
    object.entry(key).or_insert_with(|| json!([]));
    object
        .get_mut(key)
        .and_then(JsonValue::as_array_mut)
        .ok_or_else(|| format!("sing-box config field must be an array: {key}"))
}

fn ensure_dns_server(root: &mut JsonValue, cfg: &TailscaleConfig) -> Result<(), String> {
    if !root.get("dns").is_some_and(JsonValue::is_object) {
        root["dns"] = json!({});
    }
    let servers = ensure_json_array(json_object_mut(root, "dns")?, "servers")?;
    servers.push(json!({"type": "tailscale", "tag": TS_DNS, "endpoint": TS_ENDPOINT}));
    dedupe_json_tag(servers, TS_DNS);

    let rules = ensure_json_array(json_object_mut(root, "dns")?, "rules")?;
    rules.push(json!({"domain_suffix": ["ts.net", "tailscale.net"], "server": TS_DNS}));
    rules.push(json!({"ip_cidr": cfg.subnets, "server": TS_DNS}));
    Ok(())
}

fn ensure_outbound(root: &mut JsonValue) -> Result<(), String> {
    let outbounds = json_array_mut(root, "outbounds")?;
    outbounds.push(json!({"type": "direct", "tag": TS_TAG, "endpoint": TS_ENDPOINT}));
    dedupe_json_tag(outbounds, TS_TAG);
    Ok(())
}

fn ensure_routes(root: &mut JsonValue, subnets: &[String]) -> Result<(), String> {
    if !root.get("route").is_some_and(JsonValue::is_object) {
        root["route"] = json!({});
    }
    let rules = ensure_json_array(json_object_mut(root, "route")?, "rules")?;
    rules.retain(|rule| rule.get("outbound").and_then(JsonValue::as_str) != Some(TS_TAG));
    rules.insert(
        0,
        json!({"domain_suffix": ["ts.net", "tailscale.net"], "outbound": TS_TAG}),
    );
    rules.insert(0, json!({"ip_cidr": subnets, "outbound": TS_TAG}));
    Ok(())
}

fn remove_routes(root: &mut JsonValue) {
    if let Some(rules) = root["route"]["rules"].as_array_mut() {
        rules.retain(|rule| rule.get("outbound").and_then(JsonValue::as_str) != Some(TS_TAG));
    }
    if let Some(rules) = root["dns"]["rules"].as_array_mut() {
        rules.retain(|rule| rule.get("server").and_then(JsonValue::as_str) != Some(TS_DNS));
    }
}

fn remove_json_tag(root: &mut JsonValue, section: &str, tag: &str) {
    if let Some(items) = root.get_mut(section).and_then(JsonValue::as_array_mut) {
        items.retain(|item| item.get("tag").and_then(JsonValue::as_str) != Some(tag));
    }
}

fn dedupe_json_tag(items: &mut Vec<JsonValue>, tag: &str) {
    let mut seen = false;
    items.retain(|item| match item.get("tag").and_then(JsonValue::as_str) {
        Some(value) if value == tag && seen => false,
        Some(value) if value == tag => {
            seen = true;
            true
        }
        _ => true,
    });
}

fn json_object_mut<'a>(
    root: &'a mut JsonValue,
    key: &str,
) -> Result<&'a mut serde_json::Map<String, JsonValue>, String> {
    root.get_mut(key)
        .and_then(JsonValue::as_object_mut)
        .ok_or_else(|| format!("sing-box config field must be an object: {key}"))
}

fn json_array_mut<'a>(
    root: &'a mut JsonValue,
    key: &str,
) -> Result<&'a mut Vec<JsonValue>, String> {
    root.get_mut(key)
        .and_then(JsonValue::as_array_mut)
        .ok_or_else(|| format!("sing-box config field must be an array: {key}"))
}
