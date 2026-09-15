use serde_json::Value;
use std::sync::OnceLock;

pub(crate) const TOOLS_JSON: &str = r#"{"tools":[
{"name":"magicnet_status","description":"Show MagicNet service status","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_cli","description":"Run a MagicNet CLI command with explicit argv. This is restricted to the MagicNet CLI binary, not a shell.","inputSchema":{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":24}},"required":["args"]}},
{"name":"magicnet_service_control","description":"Run service status/start/ensure/stop/restart/toggle/logs, optionally with a target such as current or sing-box.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["status","start","ensure","stop","restart","toggle","logs"]},"target":{"type":"string"}}}},
{"name":"magicnet_core_select","description":"Confirm MagicNet uses the sing-box core. Only sing-box is supported.","inputSchema":{"type":"object","properties":{"core":{"type":"string","enum":["sing-box"]}},"required":["core"]}},
{"name":"magicnet_config_apply","description":"Apply runtime config helpers.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_config_get","description":"Read generated sing-box config through the config editor.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]}},"required":["target"]}},
{"name":"magicnet_config_validate","description":"Validate sing-box config.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box","all"]}}}},
{"name":"magicnet_config_sync_template","description":"Sync sing-box config from the bundled upstream template.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]}},"required":["target"]}},
{"name":"magicnet_config_save_base64","description":"Validate and save sing-box config from base64 text.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]},"content_base64":{"type":"string"}},"required":["target","content_base64"]}},
{"name":"magicnet_transparent_set","description":"Explicitly switch MagicNet transparent capture between tun (default, magicnet0) and ebpf (local cgroup plus shared TC when a confirmed downstream interface exists). The operation is atomic and rolls back on failure; auto is not supported.","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["tun","ebpf"]}},"required":["mode"]}},
{"name":"magicnet_transparent_apply","description":"Re-apply transparent proxy rules.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_health","description":"Run MagicNet health diagnostics","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_list","description":"Show MagicNet community and manual blocklist state","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_set_enabled","description":"Enable or disable MagicNet blocklist.","inputSchema":{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"]}},
{"name":"magicnet_block_set_community","description":"Enable or disable community blocklist rules.","inputSchema":{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"]}},
{"name":"magicnet_block_update","description":"Download and apply the community blocklist","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_add_domain","description":"Add a blocked domain suffix.","inputSchema":{"type":"object","properties":{"suffix":{"type":"string"}},"required":["suffix"]}},
{"name":"magicnet_block_remove_domain","description":"Remove a blocked domain suffix.","inputSchema":{"type":"object","properties":{"suffix":{"type":"string"}},"required":["suffix"]}},
{"name":"magicnet_block_allow_rule","description":"Locally allow/exclude one community block rule.","inputSchema":{"type":"object","properties":{"rule":{"type":"string"}},"required":["rule"]}},
{"name":"magicnet_block_unallow_rule","description":"Remove a local allow/exclude override for one community block rule.","inputSchema":{"type":"object","properties":{"rule":{"type":"string"}},"required":["rule"]}},
{"name":"magicnet_block_diff","description":"Show blocklist diff.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_block_apply","description":"Apply blocklist rules to current configs.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_subscription_list","description":"Show configured sing-box subscription URLs","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_subscription_set","description":"Set one subscription URL for sing-box.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]},"url":{"type":"string"}},"required":["target","url"]}},
{"name":"magicnet_subscription_set_singbox_lines","description":"Set sing-box subscription URLs from newline-separated text","inputSchema":{"type":"object","properties":{"content":{"type":"string"}},"required":["content"]}},
{"name":"magicnet_subscription_update","description":"Update sing-box subscriptions.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box","all"]}}}},
{"name":"magicnet_subscription_update_all","description":"Update all subscriptions and providers.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_backup_export","description":"Export MagicNet configuration backup as base64. Password is optional and may be empty.","inputSchema":{"type":"object","properties":{"password":{"type":"string"}}}},
{"name":"magicnet_backup_restore_base64","description":"Restore MagicNet configuration backup from base64. Password may be '-' for empty.","inputSchema":{"type":"object","properties":{"password":{"type":"string"},"content_base64":{"type":"string"}},"required":["content_base64"]}},
{"name":"magicnet_pingtest","description":"Run MagicNet domestic and global connectivity checks","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_speedtest","description":"Run direct and proxy throughput tests. Downloads at most 10 MiB total; use intentionally to avoid unexpected data consumption.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_topology","description":"Show Android network interfaces, routes, forwarding and MagicNet topology","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_sysroute_snapshot","description":"Show Android route and rule snapshot.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_ecapture_status","description":"Show bundled eCapture binary status and kernel prerequisites.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_ecapture_help","description":"Show eCapture help for tls, gotls, nspr, or pcap.","inputSchema":{"type":"object","properties":{"command":{"type":"string","enum":["tls","gotls","nspr","pcap"]}}}},
{"name":"magicnet_ecapture_tls","description":"Run a bounded eCapture TLS plaintext/event capture. Output is written under MagicNet .log.","inputSchema":{"type":"object","properties":{"duration_seconds":{"type":"integer","minimum":1,"maximum":60},"pid":{"type":"string"},"uid":{"type":"string"}}}},
{"name":"magicnet_ecapture_gotls","description":"Run a bounded eCapture Go TLS plaintext/event capture. Output is written under MagicNet .log.","inputSchema":{"type":"object","properties":{"duration_seconds":{"type":"integer","minimum":1,"maximum":60},"pid":{"type":"string"},"uid":{"type":"string"}}}},
{"name":"magicnet_ecapture_pcap","description":"Run a bounded eCapture pcap capture on an interface. The pcapng file is written under MagicNet .log.","inputSchema":{"type":"object","properties":{"duration_seconds":{"type":"integer","minimum":1,"maximum":60},"ifname":{"type":"string"},"filter":{"type":"string"}},"required":["ifname"]}},
{"name":"magicnet_support_bundle","description":"Generate MagicNet support bundle context.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_app_list","description":"List MagicNet per-app policy state.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_app_packages","description":"Search installed Android packages.","inputSchema":{"type":"object","properties":{"query":{"type":"string"}}}},
{"name":"magicnet_app_mode","description":"Set per-app policy mode.","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["blacklist","whitelist"]}},"required":["mode"]}},
{"name":"magicnet_app_add","description":"Add a package to proxy or bypass app policy.","inputSchema":{"type":"object","properties":{"package":{"type":"string"},"target":{"type":"string","enum":["proxy","bypass"]}},"required":["package","target"]}},
{"name":"magicnet_app_add_many","description":"Add multiple packages to proxy or bypass app policy.","inputSchema":{"type":"object","properties":{"packages":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200},"target":{"type":"string","enum":["proxy","bypass"]}},"required":["packages","target"]}},
{"name":"magicnet_app_remove","description":"Remove a package from proxy or bypass app policy.","inputSchema":{"type":"object","properties":{"package":{"type":"string"},"target":{"type":"string","enum":["proxy","bypass"]}},"required":["package","target"]}},
{"name":"magicnet_app_apply","description":"Apply per-app policy to current configs.","inputSchema":{"type":"object","properties":{}}},
	{"name":"magicnet_mcp_control","description":"Control MagicNet MCP status, enable, disable, start, stop, restart, or logs.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["status","enable","disable","start","stop","restart","logs"]}}}},
{"name":"magicnet_api","description":"Call core API helpers: groups, conns, stats, close-all, or ui.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["groups","conns","stats","close-all","ui"]}}}},
{"name":"magicnet_webui_status","description":"Show WebUI panel status.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_webui_verify","description":"Verify WebUI panel files.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_webui_install_local","description":"Install a SHA-256-pinned local core WebUI panel from a download URL.","inputSchema":{"type":"object","properties":{"url":{"type":"string"},"sha256":{"type":"string"},"name":{"type":"string"}},"required":["url","sha256"]}},
{"name":"magicnet_log_list","description":"List MagicNet runtime log files and known log aliases","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_log_read","description":"Read the tail of a MagicNet runtime log. Sources include sing-box, mcp, fswatch, kernel, service, or a log filename under .log. Redaction is enabled by default.","inputSchema":{"type":"object","properties":{"source":{"type":"string"},"lines":{"type":"integer","minimum":1,"maximum":1000},"redact":{"type":"boolean"}}}},
{"name":"magicnet_debug_snapshot","description":"Collect a redacted MagicNet debug snapshot with MCP status, service status, health checks, listeners, routes, log inventory, and recent core/MCP logs.","inputSchema":{"type":"object","properties":{"lines":{"type":"integer","minimum":20,"maximum":300}}}},
{"name":"magicnet_file_list","description":"List files under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_read","description":"Read a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}}
]}"#;

pub(crate) fn tool_catalog() -> Result<&'static Value, &'static str> {
    static CATALOG: OnceLock<Result<Value, serde_json::Error>> = OnceLock::new();
    CATALOG
        .get_or_init(|| serde_json::from_str(TOOLS_JSON))
        .as_ref()
        .map_err(|_| "invalid MCP tool catalog")
}

/// Enforce required fields and JSON types before defaults or side effects.
/// Domain-specific value validation remains owned by the CLI.
pub(crate) fn validate_tool_arguments(tool: &str, args: &Value) -> Result<(), String> {
    let catalog = tool_catalog()?;
    let schema = catalog["tools"]
        .as_array()
        .and_then(|tools| tools.iter().find(|entry| entry["name"] == tool))
        .map(|entry| &entry["inputSchema"])
        .ok_or("unknown tool")?;
    // Omitted arguments are compatible with the existing no-argument tools.
    if !args.is_null() && !args.is_object() {
        return Err("arguments must be an object".into());
    }
    if let Some(required) = schema["required"].as_array() {
        for key in required.iter().filter_map(Value::as_str) {
            if args.get(key).is_none() {
                return Err(format!("missing required argument: {key}"));
            }
        }
    }
    if let Some(properties) = schema["properties"].as_object() {
        for (key, property) in properties {
            if let Some(value) = args.get(key) {
                if !argument_type_matches(value, property) {
                    return Err(format!("invalid argument type: {key}"));
                }
            }
        }
    }
    Ok(())
}

fn argument_type_matches(value: &Value, schema: &Value) -> bool {
    match schema["type"].as_str() {
        Some("string") => value.is_string(),
        Some("boolean") => value.is_boolean(),
        Some("integer") => value.is_i64() || value.is_u64(),
        Some("array") => value.as_array().is_some_and(|items| {
            items
                .iter()
                .all(|item| argument_type_matches(item, &schema["items"]))
        }),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use super::TOOLS_JSON;

    fn speedtest_tool(document: &Value) -> &Value {
        document
            .get("tools")
            .and_then(Value::as_array)
            .and_then(|tools| {
                tools.iter().find(|tool| {
                    tool.get("name").and_then(Value::as_str) == Some("magicnet_speedtest")
                })
            })
            .expect("speedtest tool must exist")
    }

    #[test]
    fn tools_json_is_valid_json() {
        assert!(serde_json::from_str::<Value>(TOOLS_JSON).is_ok());
    }

    #[test]
    fn local_webui_install_requires_a_sha256_digest() {
        let document: Value = serde_json::from_str(TOOLS_JSON).expect("TOOLS_JSON must be valid");
        let tool = document
            .get("tools")
            .and_then(Value::as_array)
            .and_then(|tools| {
                tools.iter().find(|tool| {
                    tool.get("name").and_then(Value::as_str) == Some("magicnet_webui_install_local")
                })
            })
            .expect("local WebUI install tool must exist");

        assert_eq!(
            tool.pointer("/inputSchema/properties/sha256/type")
                .and_then(Value::as_str),
            Some("string")
        );
        assert!(tool
            .pointer("/inputSchema/required")
            .and_then(Value::as_array)
            .is_some_and(|required| required.iter().any(|value| value == "sha256")));
    }

    #[test]
    fn speedtest_tool_is_registered_once() {
        let document: Value = serde_json::from_str(TOOLS_JSON).expect("TOOLS_JSON must be valid");
        let count = document
            .get("tools")
            .and_then(Value::as_array)
            .expect("tools must be an array")
            .iter()
            .filter(|tool| tool.get("name").and_then(Value::as_str) == Some("magicnet_speedtest"))
            .count();

        assert_eq!(count, 1);
    }

    #[test]
    fn speedtest_tool_has_empty_object_schema() {
        let document: Value = serde_json::from_str(TOOLS_JSON).expect("TOOLS_JSON must be valid");

        assert_eq!(
            speedtest_tool(&document).get("inputSchema"),
            Some(&json!({"type":"object","properties":{}}))
        );
    }

    #[test]
    fn speedtest_tool_description_discloses_ten_mib_download_budget() {
        let document: Value = serde_json::from_str(TOOLS_JSON).expect("TOOLS_JSON must be valid");
        let description = speedtest_tool(&document)
            .get("description")
            .and_then(Value::as_str)
            .expect("speedtest description must be a string");

        assert!(description.contains("10 MiB"));
    }

    #[test]
    fn core_select_describes_singbox_only() {
        let document: Value = serde_json::from_str(TOOLS_JSON).expect("TOOLS_JSON must be valid");
        let tool = document
            .get("tools")
            .and_then(Value::as_array)
            .and_then(|tools| {
                tools.iter().find(|tool| {
                    tool.get("name").and_then(Value::as_str) == Some("magicnet_core_select")
                })
            })
            .expect("core select tool must exist");

        let description = tool
            .get("description")
            .and_then(Value::as_str)
            .expect("core select description must be a string");
        assert!(description.contains("sing-box"));
        assert!(!description.to_lowercase().contains("default core"));
        assert_eq!(
            tool.pointer("/inputSchema/properties/core/enum"),
            Some(&json!(["sing-box"]))
        );
    }

    #[test]
    fn transparent_set_exposes_only_explicit_tun_or_ebpf() {
        let document: Value = serde_json::from_str(TOOLS_JSON).expect("TOOLS_JSON must be valid");
        let tool = document
            .get("tools")
            .and_then(Value::as_array)
            .and_then(|tools| {
                tools.iter().find(|tool| {
                    tool.get("name").and_then(Value::as_str) == Some("magicnet_transparent_set")
                })
            })
            .expect("transparent set tool must exist");

        assert_eq!(
            tool.pointer("/inputSchema/properties/mode/enum"),
            Some(&json!(["tun", "ebpf"]))
        );
        let description = tool
            .get("description")
            .and_then(Value::as_str)
            .expect("transparent set description must be a string");
        assert!(description.contains("atomic"));
        assert!(description.contains("rolls back"));
        assert!(description.contains("auto is not supported"));
    }

    #[test]
    fn generic_write_tools_are_not_registered() {
        let document: Value = serde_json::from_str(TOOLS_JSON).expect("TOOLS_JSON must be valid");
        let names = document
            .get("tools")
            .and_then(Value::as_array)
            .expect("tools must be an array")
            .iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str))
            .collect::<Vec<_>>();

        for removed in [
            "magicnet_file_write",
            "magicnet_file_write_base64",
            "magicnet_file_chmod",
            "magicnet_dir_make",
            "magicnet_webui_build",
            "magicnet_download_to_downloads",
        ] {
            assert!(
                !names.contains(&removed),
                "{removed} must not be exposed by the MCP manifest"
            );
        }
    }
}
