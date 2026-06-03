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

pub(super) fn yaml_name(value: &YamlValue) -> Option<&str> {
    value.get("name").and_then(YamlValue::as_str)
}
