use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_yaml::Value as YamlValue;

use super::mihomo::{apply_mihomo, yaml_name};
use super::{TailscaleConfig, TS_TAG};

fn temp_app() -> crate::App {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("magicnet-cli-test-{stamp}"));
    crate::App::for_test(dir)
}

fn write_config(app: &crate::App, text: &str) -> PathBuf {
    let path = app.moddir.join(".config/mihomo/config.yaml");
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

fn read_yaml(path: PathBuf) -> YamlValue {
    serde_yaml::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn enabled_config_adds_proxy_group_entry_and_routes() {
    let app = temp_app();
    let path = write_config(
        &app,
        r#"
proxies:
  - name: DIRECT
    type: direct
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,DIRECT
"#,
    );

    apply_mihomo(&app, &cfg(true)).unwrap();

    let root = read_yaml(path);
    let proxies = root["proxies"].as_sequence().unwrap();
    assert!(proxies.iter().any(|proxy| yaml_name(proxy) == Some(TS_TAG)));
    assert_eq!(root["proxy-groups"][0]["proxies"][0].as_str(), Some(TS_TAG));
    let rules = root["rules"].as_sequence().unwrap();
    assert_eq!(
        rules[0].as_str(),
        Some("IP-CIDR,100.64.0.0/10,MagicNet-Tailscale,no-resolve")
    );
    assert_eq!(
        rules[2].as_str(),
        Some("DOMAIN-SUFFIX,ts.net,MagicNet-Tailscale")
    );
}

#[test]
fn disabled_config_removes_proxy_group_entry_and_routes() {
    let app = temp_app();
    let path = write_config(
        &app,
        r#"
proxies:
  - name: MagicNet-Tailscale
    type: tailscale
proxy-groups:
  - name: PROXY
    proxies:
      - MagicNet-Tailscale
      - DIRECT
rules:
  - IP-CIDR,100.64.0.0/10,MagicNet-Tailscale,no-resolve
  - MATCH,DIRECT
"#,
    );

    apply_mihomo(&app, &cfg(false)).unwrap();

    let root = read_yaml(path);
    assert!(root["proxies"].as_sequence().unwrap().is_empty());
    assert_eq!(
        root["proxy-groups"][0]["proxies"].as_sequence().unwrap()[0].as_str(),
        Some("DIRECT")
    );
    assert_eq!(root["rules"].as_sequence().unwrap().len(), 1);
}

#[test]
fn enabled_config_requires_core_sequences() {
    let app = temp_app();
    write_config(&app, "proxies: {}\nproxy-groups: []\nrules: []\n");

    let err = apply_mihomo(&app, &cfg(true)).unwrap_err();

    assert!(
        err.contains("mihomo config missing sequence: proxies"),
        "{err}"
    );
}

#[test]
fn enabled_config_reports_missing_proxy_groups() {
    let app = temp_app();
    write_config(&app, "proxies: []\nrules: []\n");

    let err = apply_mihomo(&app, &cfg(true)).unwrap_err();

    assert!(
        err.contains("mihomo config missing sequence: proxy-groups"),
        "{err}"
    );
}

#[test]
fn disabled_config_reports_missing_rules() {
    let app = temp_app();
    write_config(&app, "proxies: []\n");

    let err = apply_mihomo(&app, &cfg(false)).unwrap_err();

    assert!(
        err.contains("mihomo config missing sequence: rules"),
        "{err}"
    );
}

#[test]
fn missing_and_invalid_yaml_configs_return_errors() {
    let app = temp_app();

    let missing = apply_mihomo(&app, &cfg(true)).unwrap_err();
    assert!(missing.contains("read mihomo config"), "{missing}");

    write_config(&app, "proxy-groups: [");
    let invalid = apply_mihomo(&app, &cfg(true)).unwrap_err();
    assert!(invalid.contains("parse mihomo config"), "{invalid}");
}
