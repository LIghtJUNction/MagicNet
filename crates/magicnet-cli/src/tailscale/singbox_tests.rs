use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value as JsonValue;

use super::singbox::apply_singbox;
use super::{TailscaleConfig, TS_DNS, TS_ENDPOINT, TS_TAG};

fn temp_app() -> crate::App {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("magicnet-cli-test-{stamp}"));
    crate::App::for_test(dir)
}

fn write_config(app: &crate::App, text: &str) -> PathBuf {
    let path = app.moddir.join(".config/sing-box/config.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, text).unwrap();
    path
}

fn cfg(enabled: bool) -> TailscaleConfig {
    TailscaleConfig {
        enabled,
        auth_key: "tskey-test".to_string(),
        hostname: "phone".to_string(),
        state_dir: "/state".to_string(),
        accept_routes: true,
        subnets: vec!["100.64.0.0/10".to_string(), "192.168.7.0/24".to_string()],
    }
}

fn read_json(path: PathBuf) -> JsonValue {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn enabled_config_adds_tailscale_sections_and_dedupes_existing_tags() {
    let app = temp_app();
    let path = write_config(
        &app,
        r#"{
          "outbounds": [
            {"type":"direct","tag":"direct"},
            {"type":"direct","tag":"MagicNet-Tailscale"},
            {"type":"direct","tag":"MagicNet-Tailscale"}
          ],
          "dns": {"servers": [{"tag":"MagicNet-Tailscale-DNS"}], "rules": []},
          "route": {"rules": [{"outbound":"MagicNet-Tailscale"}]}
        }"#,
    );

    apply_singbox(&app, &cfg(true)).unwrap();

    let root = read_json(path);
    assert_eq!(
        count_tag(root["endpoints"].as_array().unwrap(), TS_ENDPOINT),
        1
    );
    assert_eq!(count_tag(root["outbounds"].as_array().unwrap(), TS_TAG), 1);
    assert_eq!(
        count_tag(root["dns"]["servers"].as_array().unwrap(), TS_DNS),
        1
    );
    assert_eq!(
        root["route"]["rules"][0]["ip_cidr"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        root["route"]["rules"][1]["domain_suffix"][0].as_str(),
        Some("ts.net")
    );
}

#[test]
fn disabled_config_removes_tailscale_sections_without_requiring_arrays_to_exist() {
    let app = temp_app();
    let path = write_config(
        &app,
        r#"{
          "outbounds": [{"type":"direct","tag":"MagicNet-Tailscale"}],
          "endpoints": [{"tag":"magicnet-ts"}],
          "dns": {"servers": [{"tag":"magicnet-ts-dns"}], "rules": [{"server":"magicnet-ts-dns"}]},
          "route": {"rules": [{"outbound":"MagicNet-Tailscale"}]}
        }"#,
    );

    apply_singbox(&app, &cfg(false)).unwrap();

    let root = read_json(path);
    assert!(root["outbounds"].as_array().unwrap().is_empty());
    assert!(root["endpoints"].as_array().unwrap().is_empty());
    assert!(root["dns"]["servers"].as_array().unwrap().is_empty());
    assert!(root["dns"]["rules"].as_array().unwrap().is_empty());
    assert!(root["route"]["rules"].as_array().unwrap().is_empty());
}

#[test]
fn enabled_config_reports_invalid_structure_instead_of_panicking() {
    let app = temp_app();
    write_config(
        &app,
        r#"{"outbounds": {}, "dns": [], "route": {"rules": []}}"#,
    );

    let err = apply_singbox(&app, &cfg(true)).unwrap_err();

    assert!(err.contains("field must be an array: outbounds"), "{err}");
}

#[test]
fn enabled_config_rejects_non_object_root() {
    let app = temp_app();
    write_config(&app, "[]");

    let err = apply_singbox(&app, &cfg(true)).unwrap_err();

    assert!(err.contains("root must be a JSON object"), "{err}");
}

#[test]
fn enabled_config_can_create_missing_dns_and_route_objects() {
    let app = temp_app();
    let path = write_config(&app, r#"{"outbounds": []}"#);

    apply_singbox(&app, &cfg(true)).unwrap();

    let root = read_json(path);
    assert!(root["dns"]["servers"].is_array());
    assert!(root["route"]["rules"].is_array());
}

#[test]
fn missing_and_invalid_json_configs_return_errors() {
    let app = temp_app();

    let missing = apply_singbox(&app, &cfg(true)).unwrap_err();
    assert!(missing.contains("read sing-box config"), "{missing}");

    write_config(&app, "{");
    let invalid = apply_singbox(&app, &cfg(true)).unwrap_err();
    assert!(invalid.contains("parse sing-box config"), "{invalid}");
}

fn count_tag(items: &[JsonValue], tag: &str) -> usize {
    items
        .iter()
        .filter(|item| item.get("tag").and_then(JsonValue::as_str) == Some(tag))
        .count()
}
