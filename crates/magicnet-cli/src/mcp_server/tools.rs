use serde_json::Value;
use std::sync::OnceLock;

pub(crate) const TOOLS_JSON: &str = r#"{"tools":[
{"name":"magicnet_status","description":"Show MagicNet service status","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_cli","description":"Run a MagicNet CLI command with explicit argv. This is restricted to the MagicNet CLI binary, not a shell.","inputSchema":{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":24}},"required":["args"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_service_control","description":"Run service status/start/ensure/stop/restart/toggle/logs, optionally with a target such as current or sing-box.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["status","start","ensure","stop","restart","toggle","logs"]},"target":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_core_select","description":"Confirm MagicNet uses the sing-box core. Only sing-box is supported.","inputSchema":{"type":"object","properties":{"core":{"type":"string","enum":["sing-box"]}},"required":["core"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_config_apply","description":"Apply runtime config helpers.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_config_get","description":"Read generated sing-box config through the config editor.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]}},"required":["target"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_config_validate","description":"Validate sing-box config.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box","all"]}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_config_sync_template","description":"Sync sing-box config from the bundled upstream template.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]}},"required":["target"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_config_save_base64","description":"Validate and save sing-box config from base64 text.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]},"content_base64":{"type":"string"}},"required":["target","content_base64"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_transparent_set","description":"Explicitly switch MagicNet transparent capture between tun (default, magicnet0) and ebpf (local cgroup plus shared TC when a confirmed downstream interface exists). The operation is atomic and rolls back on failure; auto is not supported.","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["tun","ebpf"]}},"required":["mode"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_transparent_apply","description":"Re-apply transparent proxy rules.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_health","description":"Run MagicNet health diagnostics","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_list","description":"Show MagicNet community and manual blocklist state","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_set_enabled","description":"Enable or disable MagicNet blocklist.","inputSchema":{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_set_community","description":"Enable or disable community blocklist rules.","inputSchema":{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_update","description":"Download and apply the community blocklist","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_add_domain","description":"Add a blocked domain suffix.","inputSchema":{"type":"object","properties":{"suffix":{"type":"string"}},"required":["suffix"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_remove_domain","description":"Remove a blocked domain suffix.","inputSchema":{"type":"object","properties":{"suffix":{"type":"string"}},"required":["suffix"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_allow_rule","description":"Locally allow/exclude one community block rule.","inputSchema":{"type":"object","properties":{"rule":{"type":"string"}},"required":["rule"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_unallow_rule","description":"Remove a local allow/exclude override for one community block rule.","inputSchema":{"type":"object","properties":{"rule":{"type":"string"}},"required":["rule"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_diff","description":"Show blocklist diff.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_block_apply","description":"Apply blocklist rules to current configs.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_subscription_list","description":"Show configured sing-box subscription URLs","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_subscription_set","description":"Set one subscription URL for sing-box.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box"]},"url":{"type":"string"}},"required":["target","url"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_subscription_set_singbox_lines","description":"Set sing-box subscription URLs from newline-separated text","inputSchema":{"type":"object","properties":{"content":{"type":"string"}},"required":["content"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_subscription_update","description":"Update sing-box subscriptions.","inputSchema":{"type":"object","properties":{"target":{"type":"string","enum":["sing-box","all"]}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_subscription_update_all","description":"Update all subscriptions and providers.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_backup_export","description":"Export MagicNet configuration backup as base64. Password is optional and may be empty.","inputSchema":{"type":"object","properties":{"password":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_backup_restore_base64","description":"Restore MagicNet configuration backup from base64. Password may be '-' for empty.","inputSchema":{"type":"object","properties":{"password":{"type":"string"},"content_base64":{"type":"string"}},"required":["content_base64"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_pingtest","description":"Run MagicNet domestic and global connectivity checks","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_speedtest","description":"Run direct and proxy throughput tests. Downloads at most 10 MiB total; use intentionally to avoid unexpected data consumption.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_topology","description":"Show Android network interfaces, routes, forwarding and MagicNet topology","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_sysroute_snapshot","description":"Show Android route and rule snapshot.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_ecapture_status","description":"Show bundled eCapture binary status and kernel prerequisites.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_ecapture_help","description":"Show eCapture help for tls, gotls, nspr, or pcap.","inputSchema":{"type":"object","properties":{"command":{"type":"string","enum":["tls","gotls","nspr","pcap"]}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_ecapture_tls","description":"Run a bounded eCapture TLS plaintext/event capture. Output is written under MagicNet .log.","inputSchema":{"type":"object","properties":{"duration_seconds":{"type":"integer","minimum":1,"maximum":60},"pid":{"type":"string"},"uid":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_ecapture_gotls","description":"Run a bounded eCapture Go TLS plaintext/event capture. Output is written under MagicNet .log.","inputSchema":{"type":"object","properties":{"duration_seconds":{"type":"integer","minimum":1,"maximum":60},"pid":{"type":"string"},"uid":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_ecapture_pcap","description":"Run a bounded eCapture pcap capture on an interface. The pcapng file is written under MagicNet .log.","inputSchema":{"type":"object","properties":{"duration_seconds":{"type":"integer","minimum":1,"maximum":60},"ifname":{"type":"string"},"filter":{"type":"string"}},"required":["ifname"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_support_bundle","description":"Generate MagicNet support bundle context.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_app_list","description":"List MagicNet per-app policy state.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_app_packages","description":"Search installed Android packages.","inputSchema":{"type":"object","properties":{"query":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_app_mode","description":"Set per-app policy mode.","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["blacklist","whitelist"]}},"required":["mode"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_app_add","description":"Add a package to proxy or bypass app policy.","inputSchema":{"type":"object","properties":{"package":{"type":"string"},"target":{"type":"string","enum":["proxy","bypass"]}},"required":["package","target"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_app_add_many","description":"Add multiple packages to proxy or bypass app policy.","inputSchema":{"type":"object","properties":{"packages":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200},"target":{"type":"string","enum":["proxy","bypass"]}},"required":["packages","target"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_app_remove","description":"Remove a package from proxy or bypass app policy.","inputSchema":{"type":"object","properties":{"package":{"type":"string"},"target":{"type":"string","enum":["proxy","bypass"]}},"required":["package","target"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_app_apply","description":"Apply per-app policy to current configs.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_mcp_control","description":"Control MagicNet MCP status, enable, disable, start, stop, restart, or logs.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["status","enable","disable","start","stop","restart","logs"]}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_api","description":"Call core API helpers: groups, conns, stats, close-all, or ui.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["groups","conns","stats","close-all","ui"]}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_webui_status","description":"Show WebUI panel status.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_webui_verify","description":"Verify WebUI panel files.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_webui_install_local","description":"Install a SHA-256-pinned local core WebUI panel from a download URL.","inputSchema":{"type":"object","properties":{"url":{"type":"string"},"sha256":{"type":"string"},"name":{"type":"string"}},"required":["url","sha256"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_log_list","description":"List MagicNet runtime log files and known log aliases","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_log_read","description":"Read the tail of a MagicNet runtime log. Sources include sing-box, mcp, fswatch, kernel, service, or a log filename under .log. Redaction is enabled by default.","inputSchema":{"type":"object","properties":{"source":{"type":"string"},"lines":{"type":"integer","minimum":1,"maximum":1000},"redact":{"type":"boolean"}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_debug_snapshot","description":"Collect a redacted MagicNet debug snapshot with MCP status, service status, health checks, listeners, routes, log inventory, and recent core/MCP logs.","inputSchema":{"type":"object","properties":{"lines":{"type":"integer","minimum":20,"maximum":300}},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_file_list","description":"List files under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_file_read","description":"Read a text file under the MagicNet module directory","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_capabilities","description":"Read supported schema-1 commands and features.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_transparent_status","description":"Read configured/effective transparent dataplane readiness.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_dns_status","description":"Read DNS policy status.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_network_access_status","description":"Read capability-detected OS network policy counts; effective application DNS is a separate observation.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_network_access_inspect","description":"Explicitly enumerate configured OS network restrictions and their package groups. Contains installed package names; do not attach to public reports.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_network_status","description":"Read configured and effective network settings.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_subscription_status","description":"Read subscription state without private URLs.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_wifi_status","description":"Read Wi-Fi policy status without SSID/BSSID.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_override_status","description":"Read redacted override status.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_override_inspect","description":"Explicitly read private override JSON and revision. Do not include this result in diagnostics.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_override_preview","description":"Validate a JSON Merge Patch without changing configuration. Arrays replace; null deletes.","inputSchema":{"type":"object","properties":{"patch":{"type":"object"}},"additionalProperties":false,"required":["patch"]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_override_set","description":"Validate and save complete persistent override intent using expected_revision. Does not activate it.","inputSchema":{"type":"object","properties":{"patch":{"type":"object"},"expected_revision":{"type":"integer","minimum":0}},"additionalProperties":false,"required":["patch","expected_revision"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_override_reset","description":"Reset only override intent using expected_revision. Subscription and other settings remain. Apply separately.","inputSchema":{"type":"object","properties":{"expected_revision":{"type":"integer","minimum":0}},"additionalProperties":false,"required":["expected_revision"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_override_apply","description":"Activate the saved override through the shared lifecycle controller; may briefly interrupt connections.","inputSchema":{"type":"object","properties":{"expected_revision":{"type":"integer","minimum":0}},"required":["expected_revision"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}},
{"name":"magicnet_network_set","description":"Set IPv6 strategy, MTU and UDP timeout; restarts the core.","inputSchema":{"type":"object","properties":{"ipv6_mode":{"type":"string","enum":["ipv4_only","prefer_ipv4","prefer_ipv6"]},"mtu":{"type":"integer","minimum":1280,"maximum":1500},"udp_timeout":{"type":"string","enum":["1m","3m","5m","10m","15m","30m"]}},"additionalProperties":false,"required":["ipv6_mode","mtu","udp_timeout"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_dns_set","description":"Set the DNS profile; restarts the core.","inputSchema":{"type":"object","properties":{"profile":{"type":"string","enum":["default","cloudflare-doh","cloudflare-dot","cloudflare-udp"]}},"additionalProperties":false,"required":["profile"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_dns_test","description":"Probe a public domain through the local proxy. HTTP errors are distinct from transport failures.","inputSchema":{"type":"object","properties":{"domain":{"type":"string","minLength":1,"maxLength":256}},"additionalProperties":false,"required":["domain"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_node_list","description":"List available node names; private configuration metadata.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_node_current","description":"Read the current proxy selector choice; private configuration metadata.","inputSchema":{"type":"object","properties":{},"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
{"name":"magicnet_node_test","description":"Measure one node with the configured HTTP delay endpoint. This updates delay history.","inputSchema":{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":256}},"additionalProperties":false,"required":["name"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_selector_select","description":"Select a node in a named group and persist the choice.","inputSchema":{"type":"object","properties":{"group":{"type":"string","minLength":1,"maxLength":256},"node":{"type":"string","minLength":1,"maxLength":256}},"additionalProperties":false,"required":["group","node"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_connection_close","description":"Close a specific connection by its ID.","inputSchema":{"type":"object","properties":{"id":{"type":"string","minLength":1,"maxLength":256}},"additionalProperties":false,"required":["id"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_subscription_schedule","description":"Set automatic subscription refresh interval.","inputSchema":{"type":"object","properties":{"hours":{"type":"string","enum":["off","12","24","48","72"]}},"additionalProperties":false,"required":["hours"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_route_domain","description":"Add or remove a domain-suffix routing rule.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["add-domain","remove-domain"]},"target":{"type":"string","enum":["proxy","direct","block","warp"]},"domain":{"type":"string","minLength":1,"maxLength":256}},"additionalProperties":false,"required":["action","target","domain"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}},
{"name":"magicnet_supervisor_control","description":"Control maintenance supervisors independently of the proxy core.","inputSchema":{"type":"object","properties":{"action":{"type":"string","enum":["status","start","stop","restart"]},"target":{"type":"string","enum":["fswatch","wifi-policy","all"]}},"additionalProperties":false,"required":["action","target"]},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}}
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
        if let Some(args) = args.as_object() {
            if args.keys().any(|key| !properties.contains_key(key)) {
                return Err("unknown tool argument".into());
            }
        }
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
    if schema["enum"]
        .as_array()
        .is_some_and(|choices| !choices.contains(value))
    {
        return false;
    }
    match schema["type"].as_str() {
        Some("string") => value.as_str().is_some_and(|text| {
            let len = text.chars().count() as u64;
            schema["minLength"].as_u64().is_none_or(|min| len >= min)
                && schema["maxLength"].as_u64().is_none_or(|max| len <= max)
        }),
        Some("boolean") => value.is_boolean(),
        Some("integer") => {
            (value.is_i64() || value.is_u64())
                && value.as_f64().is_some_and(|number| {
                    schema["minimum"].as_f64().is_none_or(|min| number >= min)
                        && schema["maximum"].as_f64().is_none_or(|max| number <= max)
                })
        }
        Some("object") => value.is_object(),
        Some("array") => value.as_array().is_some_and(|items| {
            schema["minItems"]
                .as_u64()
                .is_none_or(|min| items.len() as u64 >= min)
                && schema["maxItems"]
                    .as_u64()
                    .is_none_or(|max| items.len() as u64 <= max)
                && items
                    .iter()
                    .all(|item| argument_type_matches(item, &schema["items"]))
        }),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use super::{validate_tool_arguments, TOOLS_JSON};

    #[test]
    fn schemas_reject_enum_bounds_and_unknown_arguments_before_execution() {
        for (tool, args) in [
            ("magicnet_transparent_set", json!({"mode":"auto"})),
            (
                "magicnet_network_set",
                json!({"ipv6_mode":"prefer_ipv4","mtu":9000,"udp_timeout":"5m"}),
            ),
            (
                "magicnet_override_set",
                json!({"patch":{},"expected_revision":-1}),
            ),
            (
                "magicnet_override_set",
                json!({"patch":[],"expected_revision":0}),
            ),
            ("magicnet_log_read", json!({"lines":1001})),
            ("magicnet_status", json!({"unexpected":true})),
        ] {
            assert!(validate_tool_arguments(tool, &args).is_err(), "{tool}");
        }
        assert!(validate_tool_arguments(
            "magicnet_override_set",
            &json!({"patch":{"dns":{"final":"local"}},"expected_revision":0})
        )
        .is_ok());
    }

    #[test]
    fn every_tool_has_explicit_risk_hints_and_unique_name() {
        let catalog: Value = serde_json::from_str(TOOLS_JSON).unwrap();
        let mut names = std::collections::HashSet::new();
        for tool in catalog["tools"].as_array().unwrap() {
            assert!(names.insert(tool["name"].as_str().unwrap()));
            for hint in [
                "readOnlyHint",
                "destructiveHint",
                "idempotentHint",
                "openWorldHint",
            ] {
                assert!(tool["annotations"][hint].is_boolean());
            }
        }
    }

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
            Some(&json!({"type":"object","properties":{},"additionalProperties":false}))
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
