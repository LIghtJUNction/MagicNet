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

fn scan_proxy_yaml(text: &str, limit: usize, names: &mut Vec<String>) {
    for line in text.lines() {
        let trimmed = line.trim_start();
        let Some(rest) = trimmed.strip_prefix("- name:") else {
            continue;
        };
        let name = rest.trim().trim_matches('"').trim_matches('\'').to_string();
        if name.is_empty() || is_builtin_node(&name) || is_obvious_group(&name) || names.contains(&name) {
            continue;
        }
        names.push(name);
        if names.len() >= limit {
            break;
        }
    }
}

fn is_builtin_node(name: &str) -> bool {
    matches!(
        name,
        "" | "DIRECT" | "REJECT" | "REJECT-DROP" | "PASS" | "COMPATIBLE"
    )
}

fn is_obvious_group(name: &str) -> bool {
    matches!(name, "GLOBAL" | "Global" | "global")
        || name.contains("选择")
        || name.contains("策略")
        || name.contains("Selector")
        || name.contains("selector")
        || name.contains("URLTest")
        || name.contains("urltest")
        || name.contains("Fallback")
        || name.contains("fallback")
}
