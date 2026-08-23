use std::process::Command;

use serde_json::Value;

use crate::node_delay::encode_path_segment;
use crate::App;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ConnectionCloseSummary {
    pub(crate) targets: usize,
    pub(crate) closed: usize,
    pub(crate) failed: usize,
}

pub(crate) fn close_connections_through_chain(
    app: &App,
    selector_tag: &str,
) -> Result<ConnectionCloseSummary, String> {
    let text = curl_text(app, "/connections")?;
    let root: Value =
        serde_json::from_str(&text).map_err(|err| format!("parse connections: {err}"))?;
    let ids = connection_ids_through_chain(&root, selector_tag);
    let targets = ids.len();
    let mut failed = 0usize;
    for id in ids {
        if curl_delete(app, &format!("/connections/{}", encode_path_segment(&id))).is_err() {
            failed += 1;
        }
    }
    let summary = ConnectionCloseSummary {
        targets,
        closed: targets.saturating_sub(failed),
        failed,
    };
    print_close_summary(summary.targets, summary.closed, summary.failed);
    if summary.failed > 0 {
        Err(format!(
            "{} selector connections failed to close",
            summary.failed
        ))
    } else {
        Ok(summary)
    }
}

fn connection_ids_through_chain(root: &Value, selector_tag: &str) -> Vec<String> {
    root.get("connections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|connection| {
            connection
                .get("chains")
                .and_then(Value::as_array)
                .is_some_and(|chains| chains.iter().any(|tag| tag.as_str() == Some(selector_tag)))
        })
        .filter_map(|connection| {
            connection
                .get("id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
        })
        .collect()
}

pub(crate) fn close_matching_connections(app: &App, query: &str) -> Result<(), String> {
    let clean = query.trim();
    if clean.is_empty() {
        return Err("Usage: cli api close-matching <query>".to_string());
    }
    let text = curl_text(app, "/connections")?;
    let root: Value =
        serde_json::from_str(&text).map_err(|err| format!("parse connections: {err}"))?;
    let mut targets = matching_connections(&root, clean);
    targets.sort_by_key(|target| std::cmp::Reverse(target.bytes));
    targets.truncate(8);
    close_targets(app, targets)
}

pub(crate) fn close_top_connections(app: &App, count: &str) -> Result<(), String> {
    let limit = close_top_limit(count);
    let text = curl_text(app, "/connections")?;
    let root: Value =
        serde_json::from_str(&text).map_err(|err| format!("parse connections: {err}"))?;
    let mut targets = matching_connections(&root, "");
    targets.sort_by_key(|target| std::cmp::Reverse(target.bytes));
    targets.truncate(limit);
    close_targets(app, targets)
}

fn close_top_limit(count: &str) -> usize {
    count
        .trim()
        .parse::<usize>()
        .ok()
        .filter(|value| (1..=8).contains(value))
        .unwrap_or(3)
}

fn close_targets(app: &App, targets: Vec<ConnectionMatch>) -> Result<(), String> {
    if targets.is_empty() {
        println!("[info] no matching connections");
        print_close_summary(0, 0, 0);
        return Ok(());
    }
    let mut failed = 0usize;
    for target in &targets {
        match curl_delete(
            app,
            &format!("/connections/{}", encode_path_segment(&target.id)),
        ) {
            Ok(()) => println!("closed {} {}", target.id, target.label),
            Err(err) => {
                failed += 1;
                println!("failed {} {}: {err}", target.id, target.label);
            }
        }
    }
    let closed = targets.len().saturating_sub(failed);
    print_close_summary(targets.len(), closed, failed);
    if failed > 0 {
        Err(format!("{failed} matching connections failed to close"))
    } else {
        println!("[info] closed {} matching connections", targets.len());
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq)]
struct ConnectionMatch {
    id: String,
    label: String,
    haystack: String,
    bytes: u64,
}

fn matching_connections(root: &Value, query: &str) -> Vec<ConnectionMatch> {
    let terms = query
        .split_whitespace()
        .map(|term| term.to_ascii_lowercase())
        .collect::<Vec<_>>();
    root.get("connections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(connection_match)
        .filter(|target| terms.iter().all(|term| target.haystack.contains(term)))
        .collect()
}

fn connection_match(item: &Value) -> Option<ConnectionMatch> {
    let id = item.get("id").and_then(Value::as_str)?.trim();
    if id.is_empty() {
        return None;
    }
    let metadata = item.get("metadata").unwrap_or(&Value::Null);
    let host = metadata
        .get("host")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let ip = metadata
        .get("destinationIP")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let port = metadata
        .get("destinationPort")
        .map(value_text)
        .unwrap_or_default();
    let target = if host.is_empty() { ip } else { host };
    if target.is_empty() {
        return None;
    }
    let label = if port.is_empty() || port == "0" {
        target.to_string()
    } else {
        format!("{target}:{port}")
    };
    let chains = item
        .get("chains")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(" ")
        })
        .unwrap_or_default();
    let source = source_label(metadata);
    let process = process_label(metadata);
    let haystack = format!(
        "{} {} {} {} {} {} {} {}",
        label,
        metadata
            .get("network")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        item.get("inbound")
            .or_else(|| metadata.get("inbound"))
            .or_else(|| metadata.get("type"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        source,
        process,
        item.get("rule").and_then(Value::as_str).unwrap_or_default(),
        item.get("rulePayload")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        chains
    )
    .to_ascii_lowercase();
    let upload = item
        .get("upload")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let download = item
        .get("download")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    Some(ConnectionMatch {
        id: id.to_string(),
        label,
        haystack,
        bytes: upload.saturating_add(download),
    })
}

fn source_label(metadata: &Value) -> String {
    let ip = metadata
        .get("sourceIP")
        .or_else(|| metadata.get("source"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    if ip.is_empty() {
        return String::new();
    }
    let port = metadata
        .get("sourcePort")
        .map(value_text)
        .unwrap_or_default();
    if port.is_empty() || port == "0" {
        ip.to_string()
    } else {
        format!("{ip}:{port}")
    }
}

fn process_label(metadata: &Value) -> String {
    let package = metadata
        .get("processPackageName")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !package.is_empty() {
        return package.to_string();
    }
    let name = metadata
        .get("processName")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !name.is_empty() {
        return name.to_string();
    }
    metadata
        .get("processPath")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .rsplit('/')
        .find(|part| !part.is_empty())
        .unwrap_or_default()
        .to_string()
}

pub(crate) fn print_close_all_summary(app: &App) -> Result<(), String> {
    let targets = connection_count(app).unwrap_or(0);
    curl_delete(app, "/connections")?;
    print_close_summary(targets, targets, 0);
    Ok(())
}

fn connection_count(app: &App) -> Result<usize, String> {
    let text = curl_text(app, "/connections")?;
    let root: Value =
        serde_json::from_str(&text).map_err(|err| format!("parse connections: {err}"))?;
    Ok(root
        .get("connections")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0))
}

fn print_close_summary(targets: usize, closed: usize, failed: usize) {
    print!("{}", format_close_summary(targets, closed, failed));
}

fn format_close_summary(targets: usize, closed: usize, failed: usize) -> String {
    format!("targets={targets}\nclosed={closed}\nfailed={failed}\n")
}

fn curl_text(app: &App, path: &str) -> Result<String, String> {
    let output = Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            "4",
            "--max-filesize",
            "8388608",
            &format!("{}{}", app.api, path),
        ])
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn curl_delete(app: &App, path: &str) -> Result<(), String> {
    let output = Command::new("curl")
        .args([
            "-fsS",
            "-X",
            "DELETE",
            "--max-time",
            "4",
            "--max-filesize",
            "1048576",
            &format!("{}{}", app.api, path),
        ])
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn value_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_connections_filters_by_host_rule_and_chain() {
        let root: Value = serde_json::from_str(
            r#"{
              "connections": [
                {
                  "id": "a",
                  "upload": 10,
                  "download": 20,
                  "metadata": {"host": "video.example.com", "destinationPort": 443, "network": "tcp"},
                  "rule": "RuleSet",
                  "rulePayload": "media",
                  "chains": ["proxy", "jp"]
                },
                {
                  "id": "b",
                  "upload": 99,
                  "download": 1,
                  "metadata": {"destinationIP": "203.0.113.9", "destinationPort": 80},
                  "rule": "GeoIP",
                  "rulePayload": "cn",
                  "chains": ["direct"]
                },
                {
                  "metadata": {"host": "missing-id.example"}
                }
              ]
            }"#,
        )
        .unwrap();

        let video = matching_connections(&root, "video jp");
        assert_eq!(video.len(), 1);
        assert_eq!(video[0].id, "a");
        assert_eq!(video[0].label, "video.example.com:443");
        assert_eq!(video[0].bytes, 30);

        let ip = matching_connections(&root, "203.0.113 geoip");
        assert_eq!(ip.len(), 1);
        assert_eq!(ip[0].id, "b");
    }

    #[test]
    fn matching_connections_filters_by_process_source_and_inbound() {
        let root: Value = serde_json::from_str(
            r#"{
              "connections": [
                {
                  "id": "app",
                  "upload": 7,
                  "download": 5,
                  "inbound": "tun-in",
                  "metadata": {
                    "host": "api.example.com",
                    "destinationPort": 443,
                    "sourceIP": "10.0.0.2",
                    "sourcePort": 51234,
                    "processPackageName": "com.example.app"
                  }
                },
                {
                  "id": "other",
                  "metadata": {"host": "other.example.com", "destinationPort": 443}
                }
              ]
            }"#,
        )
        .unwrap();

        let by_process = matching_connections(&root, "com.example.app");
        assert_eq!(by_process.len(), 1);
        assert_eq!(by_process[0].id, "app");

        let by_source = matching_connections(&root, "10.0.0.2:51234");
        assert_eq!(by_source.len(), 1);
        assert_eq!(by_source[0].id, "app");

        let by_inbound = matching_connections(&root, "tun-in");
        assert_eq!(by_inbound.len(), 1);
        assert_eq!(by_inbound[0].id, "app");
    }

    #[test]
    fn close_top_limit_defaults_and_clamps_to_safe_range() {
        assert_eq!(close_top_limit(""), 3);
        assert_eq!(close_top_limit("bad"), 3);
        assert_eq!(close_top_limit("0"), 3);
        assert_eq!(close_top_limit("9"), 3);
        assert_eq!(close_top_limit("8"), 8);
    }

    #[test]
    fn format_close_summary_includes_machine_readable_counts() {
        assert_eq!(
            "targets=5\nclosed=3\nfailed=2\n",
            format_close_summary(5, 3, 2)
        );
    }

    #[test]
    fn connection_ids_through_chain_matches_exact_selector_without_limit() {
        let connections = (0..10)
            .map(|index| {
                serde_json::json!({
                    "id": format!("exact-{index}"),
                    "chains": ["node", "proxy", "proxy-rule"]
                })
            })
            .chain([
                serde_json::json!({
                    "id": "substring",
                    "chains": ["node", "proxy-rule-extra"]
                }),
                serde_json::json!({"chains": ["proxy-rule"]}),
            ])
            .collect::<Vec<_>>();
        let root = serde_json::json!({"connections": connections});

        let ids = connection_ids_through_chain(&root, "proxy-rule");

        assert_eq!(ids.len(), 10);
        assert_eq!(ids.first().map(String::as_str), Some("exact-0"));
        assert_eq!(ids.last().map(String::as_str), Some("exact-9"));
        assert!(!ids.iter().any(|id| id == "substring"));
    }
}
