pub(crate) const TOOLS_JSON: &str = r#"{"tools":[
{"name":"magicnet_status","description":"Show MagicNet service status","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_cli","description":"Run a MagicNet CLI command with explicit argv. This is restricted to the MagicNet CLI binary, not a shell.","inputSchema":{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":24}},"required":["args"]}},
{"name":"magicnet_service_control","description":"Run service status/start/ensure/stop/restart/toggle/logs, optionally with a target such as current or sing-box.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["status","start","ensure","stop","restart","toggle","logs"]},"target":{"type":"string"}}}},
{"name":"magicnet_core_select","description":"Select the default core.","inputSchema":{"type":"object","properties":{"core":{"type":"string","enum":["sing-box"]}},"required":["core"]}},
{"name":"magicnet_config_apply","description":"Apply runtime config helpers.","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_config_get","description":"Read generated sing-box config through the config editor.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]}},"required":["target"]}},
{"name":"magicnet_config_validate","description":"Validate sing-box config.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box","all"]}}}},
{"name":"magicnet_config_sync_template","description":"Sync sing-box config from the bundled upstream template.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]}},"required":["target"]}},
{"name":"magicnet_config_save_base64","description":"Validate and save sing-box config from base64 text.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]},"content_base64":{"type":"string"}},"required":["target","content_base64"]}},
{"name":"magicnet_transparent_set","description":"Set MagicNet capture/orchestrator mode.","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["proxy","external-tun","hybrid","tun"]}},"required":["mode"]}},
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
{"name":"magicnet_webui_install_local","description":"Install a local core WebUI panel from a download URL.","inputSchema":{"type":"object","properties":{"url":{"type":"string"},"name":{"type":"string"}},"required":["url"]}},
{"name":"magicnet_download_to_downloads","description":"Download a URL to /sdcard/Download with a safe filename. Used by WebUI donation QR save actions.","inputSchema":{"type":"object","properties":{"url":{"type":"string"},"filename":{"type":"string"}},"required":["url","filename"]}},
{"name":"magicnet_log_list","description":"List MagicNet runtime log files and known log aliases","inputSchema":{"type":"object","properties":{}}},
{"name":"magicnet_log_read","description":"Read the tail of a MagicNet runtime log. Sources include sing-box, mcp, fswatch, kernel, service, or a log filename under .log. Redaction is enabled by default.","inputSchema":{"type":"object","properties":{"source":{"type":"string"},"lines":{"type":"integer","minimum":1,"maximum":1000},"redact":{"type":"boolean"}}}},
{"name":"magicnet_debug_snapshot","description":"Collect a redacted MagicNet debug snapshot with MCP status, service status, health checks, listeners, routes, log inventory, and recent core/MCP logs.","inputSchema":{"type":"object","properties":{"lines":{"type":"integer","minimum":20,"maximum":300}}}},
{"name":"magicnet_file_list","description":"List files under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_read","description":"Read a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
{"name":"magicnet_file_write","description":"Hot-update a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
{"name":"magicnet_file_write_base64","description":"Hot-update a file from base64 content under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content_base64":{"type":"string"},"mode":{"type":"string","enum":["0644","0755","0600","0640"]}},"required":["path","content_base64"]}},
{"name":"magicnet_file_chmod","description":"Change permissions for a file or directory under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"mode":{"type":"string","enum":["0644","0755","0600","0640"]}},"required":["path","mode"]}},
{"name":"magicnet_dir_make","description":"Create a directory under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},
{"name":"magicnet_webui_build","description":"Run MagicNet WebUI build hook to rebuild webroot after hot-updating frontend files","inputSchema":{"type":"object","properties":{}}}
]}"#;

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
}
