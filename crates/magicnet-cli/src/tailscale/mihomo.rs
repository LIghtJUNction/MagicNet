use std::fs;

use serde_yaml::{Mapping, Value as YamlValue};

use crate::tailscale::{TailscaleConfig, TS_TAG};
use crate::App;

pub(crate) fn apply_mihomo(app: &App, cfg: &TailscaleConfig) -> Result<(), String> {
    let path = app.moddir.join(".config/mihomo/config.yaml");
    let text = fs::read_to_string(&path).map_err(|err| format!("read mihomo config: {err}"))?;
    let mut root: YamlValue =
        serde_yaml::from_str(&text).map_err(|err| format!("parse mihomo config: {err}"))?;
    if cfg.enabled {
        ensure_proxy(&mut root, cfg)?;
        ensure_routes(&mut root, &cfg.subnets)?;
    } else {
        remove_proxy(&mut root)?;
        remove_routes(&mut root)?;
    }
    let text = serde_yaml::to_string(&root).map_err(|err| format!("write YAML: {err}"))?;
    fs::write(path, text).map_err(|err| format!("save mihomo config: {err}"))
}

fn ensure_proxy(root: &mut YamlValue, cfg: &TailscaleConfig) -> Result<(), String> {
    let proxies = yaml_seq(root, "proxies")?;
    proxies.retain(|proxy| yaml_name(proxy) != Some(TS_TAG));
    let mut proxy = Mapping::new();
    proxy.insert(YamlValue::from("name"), YamlValue::from(TS_TAG));
    proxy.insert(YamlValue::from("type"), YamlValue::from("tailscale"));
    proxy.insert(
        YamlValue::from("hostname"),
        YamlValue::from(cfg.hostname.clone()),
    );
    proxy.insert(
        YamlValue::from("auth-key"),
        YamlValue::from(cfg.auth_key.clone()),
    );
    proxy.insert(YamlValue::from("udp"), YamlValue::from(true));
    proxy.insert(
        YamlValue::from("accept-routes"),
        YamlValue::from(cfg.accept_routes),
    );
    proxies.push(YamlValue::Mapping(proxy));
    ensure_group_contains(root, TS_TAG)?;
    Ok(())
}

fn ensure_routes(root: &mut YamlValue, subnets: &[String]) -> Result<(), String> {
    let rules = yaml_seq(root, "rules")?;
    rules.retain(|rule| !rule.as_str().is_some_and(|line| line.contains(TS_TAG)));
    rules.insert(
        0,
        YamlValue::from(format!("DOMAIN-SUFFIX,tailscale.net,{TS_TAG}")),
    );
    rules.insert(0, YamlValue::from(format!("DOMAIN-SUFFIX,ts.net,{TS_TAG}")));
    for subnet in subnets.iter().rev() {
        rules.insert(
            0,
            YamlValue::from(format!("IP-CIDR,{subnet},{TS_TAG},no-resolve")),
        );
    }
    Ok(())
}

fn remove_proxy(root: &mut YamlValue) -> Result<(), String> {
    yaml_seq(root, "proxies")?.retain(|proxy| yaml_name(proxy) != Some(TS_TAG));
    if let Some(groups) = yaml_seq_optional(root, "proxy-groups") {
        for group in groups {
            if let Some(proxies) = group
                .get_mut("proxies")
                .and_then(YamlValue::as_sequence_mut)
            {
                proxies.retain(|value| value.as_str() != Some(TS_TAG));
            }
        }
    }
    Ok(())
}

fn remove_routes(root: &mut YamlValue) -> Result<(), String> {
    yaml_seq(root, "rules")?
        .retain(|rule| !rule.as_str().is_some_and(|line| line.contains(TS_TAG)));
    Ok(())
}

fn ensure_group_contains(root: &mut YamlValue, tag: &str) -> Result<(), String> {
    let groups = yaml_seq(root, "proxy-groups")?;
    for group in groups {
        let Some(proxies) = group
            .get_mut("proxies")
            .and_then(YamlValue::as_sequence_mut)
        else {
            continue;
        };
        if !proxies.iter().any(|value| value.as_str() == Some(tag)) {
            proxies.insert(0, YamlValue::from(tag));
        }
        break;
    }
    Ok(())
}

fn yaml_seq<'a>(root: &'a mut YamlValue, key: &str) -> Result<&'a mut Vec<YamlValue>, String> {
    root.get_mut(key)
        .and_then(YamlValue::as_sequence_mut)
        .ok_or_else(|| format!("mihomo config missing sequence: {key}"))
}

fn yaml_seq_optional<'a>(root: &'a mut YamlValue, key: &str) -> Option<&'a mut Vec<YamlValue>> {
    root.get_mut(key).and_then(YamlValue::as_sequence_mut)
}

fn yaml_name(value: &YamlValue) -> Option<&str> {
    value.get("name").and_then(YamlValue::as_str)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

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
}
