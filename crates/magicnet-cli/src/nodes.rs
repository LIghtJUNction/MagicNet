use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

use crate::node_delay::node_delay;
use crate::webui_api::select_proxy;
use crate::App;
use serde_json::Value;

pub(crate) fn node_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => {
            node_list(app);
            Ok(())
        }
        "current" => node_current(app),
        "use" => {
            let name = args[1..].join(" ");
            node_use(app, &name)
        }
        "test" => {
            let name = args[1..].join(" ");
            node_test(app, &name)
        }
        "test-all" => node_test_all(app, &args[1..]),
        _ => Err("Usage: cli node {list|current|use|test <name>|test-all [name ...]}".to_string()),
    }
}

fn node_list(app: &App) {
    let limit = env::var("MAGICNET_NODE_LIST_LIMIT")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|value| value.min(500))
        .unwrap_or(48);
    let cache = app.moddir.join(".tmp/magicnet-node-list.cache");
    let cache_enabled = env::var("MAGICNET_NODE_CACHE").unwrap_or_else(|_| "1".to_string()) != "0";
    let names = resolve_node_names(app, limit, cache_enabled, &cache);
    if !names.is_empty() {
        let text = format!("{}\n", names.join("\n"));
        print!("{text}");
    }
}

fn node_current(app: &App) -> Result<(), String> {
    let proxy = read_proxy_selector(app)?;
    let current = proxy
        .get("now")
        .and_then(Value::as_str)
        .or_else(|| proxy.get("selected").and_then(Value::as_str))
        .unwrap_or("");
    if current.is_empty() {
        return Err("current node is not reported by sing-box API".to_string());
    }
    println!("{current}");
    Ok(())
}

fn node_use(app: &App, name: &str) -> Result<(), String> {
    let clean = name.trim();
    if clean.is_empty() {
        return Err("Usage: cli node use <name>".to_string());
    }
    select_proxy(app, "proxy", clean)
}

fn node_test(app: &App, name: &str) -> Result<(), String> {
    let clean = name.trim();
    if clean.is_empty() {
        return Err("Usage: cli node test <name>".to_string());
    }
    let delay = node_delay(&app.api, clean).map_err(|err| format!("test node failed: {err}"))?;
    println!("{clean}={delay}ms");
    Ok(())
}

fn node_test_all(app: &App, args: &[String]) -> Result<(), String> {
    let nodes = test_all_targets(app, args);
    if nodes.is_empty() {
        return Err("Usage: cli node test-all [name ...]".to_string());
    }
    let total = nodes.len();
    let mut failed = 0usize;
    for node in nodes {
        match node_delay(&app.api, &node) {
            Ok(delay) => println!("{node}={delay}ms"),
            Err(err) => {
                failed += 1;
                println!("{node}=error: {err}");
            }
        }
    }
    node_test_all_status(total.saturating_sub(failed), failed)
}

fn node_test_all_status(successful: usize, failed: usize) -> Result<(), String> {
    if successful == 0 && failed > 0 {
        Err(format!("{failed} node tests failed"))
    } else {
        if failed > 0 {
            eprintln!("[warning] {failed} node tests failed; {successful} node tests succeeded");
        }
        Ok(())
    }
}

fn test_all_targets(app: &App, args: &[String]) -> Vec<String> {
    if !args.is_empty() {
        return args
            .iter()
            .map(|item| item.trim())
            .filter(|item| !item.is_empty())
            .map(ToString::to_string)
            .collect();
    }
    let cache = app.moddir.join(".tmp/magicnet-node-list.cache");
    resolve_node_names(app, 16, true, &cache)
}

fn read_proxy_selector(app: &App) -> Result<Value, String> {
    let output = Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            "5",
            "--max-filesize",
            "8388608",
            &format!("{}/proxies/proxy", app.api),
        ])
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("read proxy selector failed: {}", stderr.trim()));
    }
    serde_json::from_slice(&output.stdout).map_err(|err| format!("parse proxy selector: {err}"))
}

fn resolve_node_names(app: &App, limit: usize, cache_enabled: bool, cache: &Path) -> Vec<String> {
    let names = scan_node_names(app, limit);
    if !names.is_empty() {
        refresh_node_cache(cache, &names);
        return names;
    }
    if cache_enabled {
        return read_node_cache(cache, limit).unwrap_or_default();
    }
    Vec::new()
}

fn scan_node_names(app: &App, limit: usize) -> Vec<String> {
    let mut names = Vec::new();
    scan_singbox_tags(app, limit, &mut names);
    names
}

fn scan_singbox_tags(app: &App, limit: usize, names: &mut Vec<String>) {
    let tags = app
        .moddir
        .join(".state/sing-box/subscription-work/tags.txt");
    if let Ok(text) = fs::read_to_string(tags) {
        for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
            push_node(line, limit, names);
            if names.len() >= limit {
                return;
            }
        }
    }
    let config = app.moddir.join(".config/sing-box/config.json");
    if let Ok(text) = fs::read_to_string(config) {
        if let Ok(json) = serde_json::from_str::<Value>(&text) {
            if let Some(outbounds) = json.get("outbounds").and_then(Value::as_array) {
                let proxy_members = proxy_member_tags(outbounds);
                if !proxy_members.is_empty() {
                    for outbound in outbounds {
                        let Some(name) = outbound.get("tag").and_then(Value::as_str) else {
                            continue;
                        };
                        if proxy_members.contains(name) && is_real_outbound(outbound) {
                            push_node(name, limit, names);
                            if names.len() >= limit {
                                return;
                            }
                        }
                    }
                } else {
                    for outbound in outbounds {
                        let Some(name) = outbound.get("tag").and_then(Value::as_str) else {
                            continue;
                        };
                        if is_real_outbound(outbound) {
                            push_node(name, limit, names);
                            if names.len() >= limit {
                                return;
                            }
                        }
                    }
                }
            }
        }
    }
}

fn push_node(name: &str, limit: usize, names: &mut Vec<String>) {
    if name.is_empty() || is_builtin_node(name) || is_obvious_group(name) {
        return;
    }
    if !names.iter().any(|item| item == name) {
        names.push(name.to_string());
        if names.len() >= limit {
            names.truncate(limit);
        }
    }
}

fn read_node_cache(cache: &Path, limit: usize) -> Option<Vec<String>> {
    let text = fs::read_to_string(cache).ok()?;
    let mut names = Vec::new();
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        push_node(line, limit, &mut names);
        if names.len() >= limit {
            break;
        }
    }
    if names.is_empty() {
        None
    } else {
        Some(names)
    }
}

fn refresh_node_cache(cache: &Path, names: &[String]) {
    if let Some(parent) = cache.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let text = format!("{}\n", names.join("\n"));
    let _ = fs::write(cache, text);
}

fn proxy_member_tags(outbounds: &[Value]) -> HashSet<String> {
    let mut members = HashSet::new();
    for outbound in outbounds {
        if outbound.get("tag").and_then(Value::as_str) != Some("proxy") {
            continue;
        }
        let Some(proxy_outbounds) = outbound.get("outbounds").and_then(Value::as_array) else {
            continue;
        };
        for member in proxy_outbounds {
            if let Some(tag) = member.as_str() {
                members.insert(tag.to_string());
            }
        }
    }
    members
}

fn is_real_outbound(outbound: &Value) -> bool {
    let Some(outbound_type) = outbound.get("type").and_then(Value::as_str) else {
        return false;
    };
    !matches!(
        outbound_type,
        "" | "selector" | "urltest" | "direct" | "block" | "dns"
    )
}

fn is_builtin_node(name: &str) -> bool {
    matches!(
        name,
        "" | "DIRECT" | "REJECT" | "REJECT-DROP" | "PASS" | "COMPATIBLE" | "direct" | "block"
    )
}

fn is_obvious_group(name: &str) -> bool {
    matches!(
        name,
        "GLOBAL"
            | "Global"
            | "global"
            | "proxy"
            | "chain"
            | "chain-hop1"
            | "chain-exit"
            | "chain-auto"
            | "select"
            | "lan"
            | "ad-block"
            | "cn-direct"
            | "apple-cn"
            | "microsoft-cn"
            | "google-cn"
            | "icloud"
            | "bing"
            | "network-test"
            | "ai-proxy"
            | "proxy-rule"
            | "dev-proxy"
            | "social-proxy"
            | "download-direct"
            | "media-proxy"
            | "game-proxy"
            | "telegram-proxy"
            | "final"
    ) || name.contains("选择")
        || name.contains("策略")
        || name.starts_with("magicnet-chain-")
        || name.contains("Selector")
        || name.contains("selector")
        || name.contains("URLTest")
        || name.contains("urltest")
        || name.contains("Fallback")
        || name.contains("fallback")
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::test_support::temp_app;

    fn write_file(path: impl AsRef<Path>, text: &str) {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, text).unwrap();
    }

    fn resolve_config_nodes(config: &str) -> Vec<String> {
        let app = temp_app();
        write_file(app.moddir.join(".config/sing-box/config.json"), config);
        resolve_node_names(
            &app,
            48,
            false,
            &app.moddir.join(".tmp/magicnet-node-list.cache"),
        )
    }

    #[test]
    fn compact_config_json_skips_selector_groups_and_keeps_real_nodes() {
        let names = resolve_config_nodes(
            r#"{"outbounds":[{"tag":"dns-guard","type":"selector","outbounds":["alpha"]},{"tag":"alpha","type":"shadowsocks"},{"tag":"beta","type":"vless"}]}"#,
        );

        assert_eq!(names, vec!["alpha".to_string(), "beta".to_string()]);
    }

    #[test]
    fn proxy_selector_members_control_included_nodes() {
        let names = resolve_config_nodes(
            r#"{"outbounds":[{"tag":"dns-guard","type":"selector","outbounds":["alpha"]},{"tag":"proxy","type":"selector","outbounds":["alpha","beta"]},{"tag":"alpha","type":"shadowsocks"},{"tag":"beta","type":"vless"},{"tag":"gamma","type":"trojan"}]}"#,
        );

        assert_eq!(names, vec!["alpha".to_string(), "beta".to_string()]);
    }

    #[test]
    fn stale_cache_does_not_override_current_scan() {
        let app = temp_app();
        write_file(app.moddir.join(".tmp/magicnet-node-list.cache"), "stale\n");
        write_file(
            app.moddir.join(".config/sing-box/config.json"),
            r#"{"outbounds":[{"tag":"current","type":"shadowsocks"}]}"#,
        );

        let cache = app.moddir.join(".tmp/magicnet-node-list.cache");
        let names = resolve_node_names(&app, 48, true, &cache);

        assert_eq!(names, vec!["current".to_string()]);
        assert_eq!(fs::read_to_string(cache).unwrap(), "current\n");
    }

    #[test]
    fn cache_fallback_is_used_when_current_scan_is_empty() {
        let app = temp_app();
        let cache = app.moddir.join(".tmp/magicnet-node-list.cache");
        write_file(&cache, "cached\n");

        let names = resolve_node_names(&app, 48, true, &cache);

        assert_eq!(names, vec!["cached".to_string()]);
    }

    #[test]
    fn test_all_uses_explicit_targets_when_present() {
        let app = temp_app();
        let names = test_all_targets(&app, &["alpha".to_string(), " beta ".to_string()]);
        assert_eq!(names, vec!["alpha".to_string(), "beta".to_string()]);
    }

    #[test]
    fn partial_node_batch_is_not_reported_as_total_failure() {
        assert!(node_test_all_status(3, 1).is_ok());
    }

    #[test]
    fn all_failed_node_batch_still_reports_failure() {
        assert!(node_test_all_status(0, 4).is_err());
    }
}
