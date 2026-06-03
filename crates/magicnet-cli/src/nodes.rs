use std::env;
use std::fs;

use crate::App;

pub(crate) fn node_list(app: &App) {
    let limit = env::var("MAGICNET_NODE_LIST_LIMIT")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(48);
    let cache = app.moddir.join(".tmp/magicnet-node-list.cache");
    if env::var("MAGICNET_NODE_CACHE").unwrap_or_else(|_| "1".to_string()) != "0" {
        if let Ok(text) = fs::read_to_string(&cache) {
            if !text.trim().is_empty() {
                print!("{text}");
                return;
            }
        }
    }
    let names = scan_node_names(app, limit);
    if !names.is_empty() {
        if let Some(parent) = cache.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let text = format!("{}\n", names.join("\n"));
        let _ = fs::write(cache, &text);
        print!("{text}");
    }
}

fn scan_node_names(app: &App, limit: usize) -> Vec<String> {
    let mut names = Vec::new();
    scan_singbox_tags(app, limit, &mut names);
    if names.len() >= limit {
        return names;
    }
    let dir = app.moddir.join(".config/mihomo/proxies");
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            if entry.path().extension().and_then(|value| value.to_str()) != Some("yaml") {
                continue;
            }
            let Ok(text) = fs::read_to_string(entry.path()) else {
                continue;
            };
            scan_proxy_yaml(&text, limit, &mut names);
            if names.len() >= limit {
                break;
            }
        }
    }
    names
}

fn scan_singbox_tags(app: &App, limit: usize, names: &mut Vec<String>) {
    let tags = app
        .moddir
        .join(".config/sing-box/.subscription-work/tags.txt");
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
        for line in text.lines() {
            let Some(name) = json_tag(line) else {
                continue;
            };
            push_node(&name, limit, names);
            if names.len() >= limit {
                return;
            }
        }
    }
}

fn scan_proxy_yaml(text: &str, limit: usize, names: &mut Vec<String>) {
    for line in text.lines() {
        let trimmed = line.trim_start();
        let Some(rest) = trimmed.strip_prefix("- name:") else {
            continue;
        };
        let name = rest.trim().trim_matches('"').trim_matches('\'').to_string();
        push_node(&name, limit, names);
        if names.len() >= limit {
            break;
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

fn json_tag(line: &str) -> Option<String> {
    let (_, rest) = line.split_once("\"tag\"")?;
    let (_, value) = rest.split_once(':')?;
    let value = value.trim().trim_end_matches(',').trim();
    value
        .strip_prefix('"')?
        .strip_suffix('"')
        .map(ToOwned::to_owned)
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
        || name.contains("Selector")
        || name.contains("selector")
        || name.contains("URLTest")
        || name.contains("urltest")
        || name.contains("Fallback")
        || name.contains("fallback")
}
