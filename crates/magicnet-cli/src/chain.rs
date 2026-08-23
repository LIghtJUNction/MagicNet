use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::selector_store;
use crate::service::apply_config;
use crate::webui_api::{curl_get_json, select_proxy};
use crate::{write_text_file, App};

const POLICY_PATH: &str = ".config/magicnet/proxy-chain.json";
const CHAIN_PREFIX: &str = "magicnet-chain-";

pub(crate) fn chain_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => chain_status(app),
        "enable" => set_enabled(app, true),
        "disable" => set_enabled(app, false),
        "set-upstream" => set_role(app, "upstream", &args[1..].join(" ")),
        "set-exit" => set_role(app, "exit", &args[1..].join(" ")),
        "clear-upstream" => clear_role(app, "upstream"),
        "clear-exit" => clear_role(app, "exit"),
        "mode" => set_mode(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "select-upstream" => select_upstream(app, &args[1..].join(" ")),
        "select-exit" => select_exit(app, &args[1..].join(" ")),
        _ => Err(chain_usage()),
    }
}

fn chain_usage() -> String {
    "Usage: cli chain {status|enable|disable|set-upstream <tag>|set-exit <tag>|clear-upstream|clear-exit|mode <manual|auto>|select-upstream <tag>|select-exit <tag>}"
        .to_string()
}

fn policy_path(app: &App) -> PathBuf {
    app.moddir.join(POLICY_PATH)
}

fn default_policy() -> Value {
    json!({
        "enabled": false,
        "mode": "manual",
        "upstream": [],
        "exit": []
    })
}

fn load_policy(app: &App) -> Result<(Value, Option<Vec<u8>>), String> {
    let path = policy_path(app);
    let previous = match fs::read(&path) {
        Ok(bytes) => Some(bytes),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(format!("read proxy chain policy: {error}")),
    };
    let policy = match previous.as_deref() {
        Some(bytes) => serde_json::from_slice(bytes)
            .map_err(|error| format!("parse proxy chain policy: {error}"))?,
        None => default_policy(),
    };
    if !policy.is_object() {
        return Err("proxy chain policy must be a JSON object".to_string());
    }
    Ok((policy, previous))
}

fn write_policy(app: &App, policy: &Value) -> Result<(), String> {
    let text = serde_json::to_string_pretty(policy)
        .map_err(|error| format!("encode proxy chain policy: {error}"))?;
    write_text_file(app, Path::new(POLICY_PATH), &format!("{text}\n"))
}

fn restore_policy(app: &App, previous: Option<&[u8]>) -> Result<(), String> {
    let path = policy_path(app);
    match previous {
        Some(bytes) => {
            write_text_file(app, Path::new(POLICY_PATH), &String::from_utf8_lossy(bytes))
        }
        None => match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("remove new proxy chain policy: {error}")),
        },
    }
}

fn commit_policy(
    app: &App,
    policy: &Value,
    previous: Option<&[u8]>,
    apply: bool,
) -> Result<(), String> {
    write_policy(app, policy)?;
    if !apply {
        return Ok(());
    }
    if let Err(error) = apply_config(app) {
        let restore_error = restore_policy(app, previous).err();
        let detail = restore_error
            .map(|restore| format!("; policy restore failed: {restore}"))
            .unwrap_or_default();
        return Err(format!("apply proxy chain policy failed: {error}{detail}"));
    }
    Ok(())
}

fn policy_enabled(policy: &Value) -> bool {
    policy
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn policy_mode(policy: &Value) -> &str {
    policy
        .get("mode")
        .and_then(Value::as_str)
        .filter(|mode| matches!(*mode, "manual" | "auto"))
        .unwrap_or("manual")
}

fn role_tags<'a>(policy: &'a Value, role: &str) -> Vec<&'a str> {
    policy
        .get(role)
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

fn set_enabled(app: &App, enabled: bool) -> Result<(), String> {
    let (mut policy, previous) = load_policy(app)?;
    if enabled
        && (role_tags(&policy, "upstream").is_empty() || role_tags(&policy, "exit").is_empty())
    {
        return Err("set upstream and exit nodes before enabling the proxy chain".to_string());
    }
    policy["enabled"] = Value::Bool(enabled);
    commit_policy(app, &policy, previous.as_deref(), true)?;
    let runtime_member = if enabled {
        "chain".to_string()
    } else {
        proxy_default_member(app)?
    };
    select_runtime_member(app, "proxy", &runtime_member)?;
    println!(
        "[info] proxy chain {}",
        if enabled { "enabled" } else { "disabled" }
    );
    Ok(())
}

fn set_role(app: &App, role: &str, tag: &str) -> Result<(), String> {
    let tag = clean_tag(tag)?;
    if !base_node_exists(app, &tag)? {
        return Err(format!("proxy node is not available: {tag}"));
    }
    let (mut policy, previous) = load_policy(app)?;
    policy[role] = json!([tag]);
    let apply = policy_enabled(&policy);
    commit_policy(app, &policy, previous.as_deref(), apply)?;
    println!("[info] proxy chain {role} node set to {tag}");
    Ok(())
}

fn clear_role(app: &App, role: &str) -> Result<(), String> {
    let (mut policy, previous) = load_policy(app)?;
    policy[role] = json!([]);
    if policy_enabled(&policy) {
        return Err("disable the proxy chain before clearing a chain role".to_string());
    }
    commit_policy(app, &policy, previous.as_deref(), false)?;
    println!("[info] proxy chain {role} node cleared");
    Ok(())
}

fn set_mode(app: &App, mode: &str) -> Result<(), String> {
    if !matches!(mode.trim(), "manual" | "auto") {
        return Err("proxy chain mode must be manual or auto".to_string());
    }
    let (mut policy, previous) = load_policy(app)?;
    policy["mode"] = Value::String(mode.trim().to_string());
    let apply = policy_enabled(&policy);
    commit_policy(app, &policy, previous.as_deref(), apply)?;
    println!("[info] proxy chain mode set to {}", mode.trim());
    Ok(())
}

fn clean_tag(tag: &str) -> Result<String, String> {
    let tag = tag.trim();
    if tag.is_empty() {
        return Err(chain_usage());
    }
    if tag.chars().any(char::is_control) {
        return Err("proxy node tag contains a control character".to_string());
    }
    if tag.starts_with(CHAIN_PREFIX) {
        return Err("generated proxy chain tags cannot be used as base nodes".to_string());
    }
    Ok(tag.to_string())
}

fn load_singbox_config(app: &App) -> Result<Value, String> {
    let config = fs::read_to_string(app.moddir.join(".config/sing-box/config.json"))
        .map_err(|error| format!("read sing-box config: {error}"))?;
    serde_json::from_str(&config).map_err(|error| format!("parse sing-box config: {error}"))
}

fn base_node_exists(app: &App, tag: &str) -> Result<bool, String> {
    let value = load_singbox_config(app)?;
    Ok(value
        .get("outbounds")
        .and_then(Value::as_array)
        .is_some_and(|outbounds| {
            outbounds.iter().any(|outbound| {
                outbound.get("tag").and_then(Value::as_str) == Some(tag)
                    && outbound
                        .get("tag")
                        .and_then(Value::as_str)
                        .is_some_and(|name| !name.starts_with(CHAIN_PREFIX))
                    && matches!(
                        outbound.get("type").and_then(Value::as_str),
                        Some(
                            "shadowsocks"
                                | "vmess"
                                | "vless"
                                | "trojan"
                                | "hysteria2"
                                | "anytls"
                                | "tuic"
                                | "socks"
                        )
                    )
            })
        }))
}

fn proxy_default_member(app: &App) -> Result<String, String> {
    let value = load_singbox_config(app)?;
    let default = value
        .get("outbounds")
        .and_then(Value::as_array)
        .and_then(|outbounds| {
            outbounds.iter().find(|outbound| {
                outbound.get("tag").and_then(Value::as_str) == Some("proxy")
                    && outbound.get("type").and_then(Value::as_str) == Some("selector")
            })
        })
        .and_then(|proxy| proxy.get("default"))
        .and_then(Value::as_str)
        .filter(|member| {
            !member.is_empty() && *member != "chain" && !member.starts_with(CHAIN_PREFIX)
        })
        .unwrap_or("block");
    Ok(default.to_string())
}

fn select_upstream(app: &App, tag: &str) -> Result<(), String> {
    let tag = clean_tag(tag)?;
    let (policy, _) = load_policy(app)?;
    if !role_tags(&policy, "upstream").contains(&tag.as_str()) {
        return Err("upstream tag is not in the configured chain role".to_string());
    }
    select_runtime_member(app, "chain-hop1", &tag)
}

fn select_exit(app: &App, tag: &str) -> Result<(), String> {
    let requested = tag.trim();
    if requested.is_empty() {
        return Err(chain_usage());
    }
    let member = if requested.starts_with("magicnet-chain-exit::") {
        if requested.chars().any(char::is_control) || !generated_exit_exists(app, requested)? {
            return Err("generated chain exit is not available".to_string());
        }
        requested.to_string()
    } else {
        let base = clean_tag(requested)?;
        let generated = format!("magicnet-chain-exit::{base}");
        if !generated_exit_exists(app, &generated)? {
            return Err(format!("generated chain exit is not available: {base}"));
        }
        generated
    };
    select_runtime_member(app, "chain-exit", &member)
}

fn generated_exit_exists(app: &App, tag: &str) -> Result<bool, String> {
    let value = load_singbox_config(app)?;
    Ok(value
        .get("outbounds")
        .and_then(Value::as_array)
        .is_some_and(|outbounds| {
            outbounds.iter().any(|outbound| {
                outbound.get("tag").and_then(Value::as_str) == Some(tag)
                    && outbound.get("detour").and_then(Value::as_str) == Some("chain-hop1")
            })
        }))
}

fn select_runtime_member(app: &App, group: &str, member: &str) -> Result<(), String> {
    if curl_get_json(app, "/proxies").is_ok() {
        select_proxy(app, group, member)
    } else {
        selector_store::save(app, group, member)
            .map_err(|error| format!("persist proxy chain selector: {error}"))
    }
}

fn chain_status(app: &App) -> Result<(), String> {
    let (policy, _) = load_policy(app)?;
    println!("enabled={}", policy_enabled(&policy));
    println!("mode={}", policy_mode(&policy));
    print_role_status("upstream", &policy);
    print_role_status("exit", &policy);
    match curl_get_json(app, "/proxies") {
        Ok(runtime) => {
            println!("runtime=available");
            for group in ["proxy", "chain", "chain-hop1", "chain-exit"] {
                if let Some(now) = runtime
                    .get("proxies")
                    .and_then(|proxies| proxies.get(group))
                    .and_then(|value| value.get("now"))
                    .and_then(Value::as_str)
                {
                    println!("runtime.{group}={now}");
                }
            }
        }
        Err(_) => println!("runtime=unavailable"),
    }
    Ok(())
}

fn print_role_status(role: &str, policy: &Value) {
    let tags = role_tags(policy, role);
    if tags.is_empty() {
        println!("{role}=none");
    } else {
        println!("{role}={}", tags.join(","));
    }
}

#[cfg(test)]
mod tests {
    use super::{clean_tag, default_policy, policy_mode};

    #[test]
    fn default_policy_starts_disabled_and_manual() {
        let policy = default_policy();
        assert!(!policy["enabled"].as_bool().unwrap_or(true));
        assert_eq!(policy_mode(&policy), "manual");
    }

    #[test]
    fn clean_tag_rejects_generated_chain_tags() {
        assert!(clean_tag("magicnet-chain-exit::node-a").is_err());
    }

    #[test]
    fn clean_tag_preserves_node_names_with_spaces() {
        assert_eq!(clean_tag("  node a  ").unwrap(), "node a");
    }
}
