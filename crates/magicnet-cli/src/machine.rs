use std::fs;
use std::path::Path;

use serde_json::{json, Value};

use crate::{
    clean_module_lines, diagnostics::supervisor_pid, read_kv, service::singbox_webui,
    singbox_pid_summary, webui_api::current_clash_mode, App,
};

mod transparent;

const MACHINE_SCHEMA: u64 = 1;
const SELECTED_CORE_CONF: &str = ".config/magicnet/current-core.conf";
const TRANSPARENT_MODE_CONF: &str = ".config/magicnet/transparent-mode.conf";
const DNS_CONF: &str = ".config/magicnet/dns.conf";
const NETWORK_POLICY_CONF: &str = ".config/magicnet/network-policy.conf";
const SINGBOX_CONFIG: &str = ".config/sing-box/config.json";
const SUBSCRIPTION_URL: &str = ".config/sing-box/subscription.url";
const SUBSCRIPTION_LOCAL: &str = ".config/sing-box/subscription.local";
const SUBSCRIPTION_STATUS: &str = ".state/sing-box/subscription-status";
const SUBSCRIPTION_TRANSACTION: &str = ".state/sing-box/subscription-transaction";
const SUBSCRIPTION_UPDATE_LOCK: &str = ".state/sing-box/subscription-update.lock";
const SUBSCRIPTION_CACHE: &str = ".state/sing-box/subscription-cache";
const SUBSCRIPTION_REFRESH_HOURS: &str = ".config/magicnet/subscription-refresh-hours";
const WIFI_POLICY_CONF: &str = ".config/magicnet/wifi-policy.conf";
const WIFI_SSID_LIST: &str = ".config/magicnet/wifi-ssid.list";
const WIFI_BSSID_LIST: &str = ".config/magicnet/wifi-bssid.list";
const WIFI_LAST_STATE: &str = ".state/wifi-policy/last-state.conf";
const MACHINE_COMMANDS: &[&str] = &[
    "service.status",
    "core.status",
    "supervisor.status",
    "transparent.status",
    "dns.status",
    "network.status",
    "sub.status",
    "wifi.status",
    "machine.capabilities",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct MachineError {
    code: &'static str,
    message: &'static str,
}

pub(crate) fn dispatch(app: &App, args: &[String]) -> Option<Result<(), String>> {
    let json_flags = args.iter().filter(|arg| arg.as_str() == "--json").count();
    if json_flags == 0 {
        return None;
    }
    if json_flags != 1 {
        return Some(print_machine_error(MachineError {
            code: "machine.invalid_request",
            message: "expected exactly one --json flag",
        }));
    }

    let command = args
        .iter()
        .filter(|arg| arg.as_str() != "--json")
        .map(String::as_str)
        .collect::<Vec<_>>();
    Some(match machine_value(app, &command) {
        Ok(value) => print_machine_value(&value),
        Err(error) => print_machine_error(error),
    })
}

fn machine_value(app: &App, command: &[&str]) -> Result<Value, MachineError> {
    match command {
        [command] if *command == "capabilities" => Ok(capabilities_value()),
        [command, action] if *command == "service" && *action == "status" => {
            Ok(service_status_value(app))
        }
        [command, action] if *command == "core" && *action == "status" => {
            Ok(core_status_value(app))
        }
        [command, action] if *command == "supervisor" && *action == "status" => {
            Ok(supervisor_status_value(app))
        }
        [command, action] if *command == "transparent" && *action == "status" => {
            Ok(transparent_status_value(app))
        }
        [command, action] if *command == "dns" && *action == "status" => Ok(dns_status_value(app)),
        [command, action] if *command == "network" && *action == "status" => {
            Ok(network_status_value(app))
        }
        [command, action] if *command == "sub" && *action == "status" => Ok(sub_status_value(app)),
        [command, action] if *command == "wifi" && *action == "status" => {
            Ok(wifi_status_value(app))
        }
        _ => Err(MachineError {
            code: "machine.unsupported_command",
            message: "unsupported machine command",
        }),
    }
}

fn print_machine_value(value: &Value) -> Result<(), String> {
    let encoded =
        serde_json::to_string(value).map_err(|err| format!("serialize machine response: {err}"))?;
    println!("{encoded}");
    Ok(())
}

fn print_machine_error(error: MachineError) -> Result<(), String> {
    print_machine_value(&json!({
        "schema": MACHINE_SCHEMA,
        "ok": false,
        "command": "machine.error",
        "error": {
            "code": error.code,
            "message": error.message,
        }
    }))?;
    Err(error.code.to_string())
}

fn envelope(command: &str, data: Value) -> Value {
    json!({
        "schema": MACHINE_SCHEMA,
        "ok": true,
        "command": command,
        "data": data,
    })
}

fn capabilities_value() -> Value {
    envelope(
        "machine.capabilities",
        json!({
            "machine_schema": MACHINE_SCHEMA,
            "commands": MACHINE_COMMANDS,
            "features": [
                "versioned_envelope",
                "structured_errors",
                "redacted_status",
                "configured_effective_split",
                "privacy_safe_network_identifiers",
                "readiness_signals"
            ],
            "json_flag_positions": ["prefix", "suffix"],
            "read_only": true,
        }),
    )
}

fn service_status_value(app: &App) -> Value {
    let singbox = singbox_pid_summary(app);
    let process_state = process_state(&singbox);
    let running = match process_state {
        "running" => Some(true),
        "stopped" => Some(false),
        _ => None,
    };
    let rss_kib = if process_state == "running" {
        singbox_rss_kib(&singbox)
    } else {
        None
    };
    let selected = selected_core(app);
    let configured_transparent = transparent_mode(app);
    let transparent = transparent::snapshot(app, process_state, &configured_transparent);
    let api_ready = api_readiness(app, process_state);
    let overall_ready = combine_readiness(api_ready, transparent.dataplane_ready);
    let lifecycle = service_lifecycle(process_state, &transparent.transition, overall_ready);
    let subscription_source = subscription_source_mode(app);

    envelope(
        "service.status",
        json!({
            "lifecycle": lifecycle,
            "core": {
                "selected": selected,
                "sing_box": {
                    "process_state": process_state,
                    "running": running,
                    "pid_summary": singbox,
                    "rss_kib": rss_kib,
                }
            },
            "supervisors": supervisor_data(app),
            "transparent": transparent.as_value(),
            "api": {
                "url": app.api,
                "webui": singbox_webui(app),
                "ready": api_ready,
            },
            "readiness": {
                "dataplane": transparent.dataplane_ready,
                "overall": overall_ready,
            },
            "subscription": {
                "source": subscription_source,
            }
        }),
    )
}

fn core_status_value(app: &App) -> Value {
    envelope(
        "core.status",
        json!({
            "selected": selected_core(app),
        }),
    )
}

fn supervisor_status_value(app: &App) -> Value {
    envelope("supervisor.status", supervisor_data(app))
}

fn transparent_status_value(app: &App) -> Value {
    let process = singbox_pid_summary(app);
    let process_state = process_state(&process);
    let configured = transparent_mode(app);
    let status = transparent::snapshot(app, process_state, &configured);
    envelope("transparent.status", status.as_value())
}

fn supervisor_data(app: &App) -> Value {
    json!({
        "fswatch": supervisor_pid(app, "fswatch", "magicnet-config"),
        "wifi_policy": supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy"),
    })
}

fn dns_status_value(app: &App) -> Value {
    let profile = dns_profile(app);
    let (primary, secondary, transport) = match profile.as_str() {
        "cloudflare-udp" => ("1.1.1.1", Some("1.0.0.1"), "udp"),
        "cloudflare-dot" => ("tls://1.1.1.1", Some("tls://1.0.0.1"), "dot"),
        "cloudflare-doh" => (
            "https://cloudflare-dns.com/dns-query",
            Some("https://1.0.0.1/dns-query"),
            "doh",
        ),
        _ => ("bootstrap-local-dns", None, "default"),
    };
    envelope(
        "dns.status",
        json!({
            "profile": profile,
            "primary": primary,
            "secondary": secondary,
            "transport": transport,
        }),
    )
}

fn network_status_value(app: &App) -> Value {
    let values = read_kv(app.moddir.join(NETWORK_POLICY_CONF));
    let configured_ipv6_mode = normalize_ipv6_mode(
        values
            .get("MAGICNET_IPV6_MODE")
            .map(String::as_str)
            .unwrap_or_default(),
    );
    let configured_mtu = values
        .get("MAGICNET_TUN_MTU")
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|value| (1280..=1500).contains(value))
        .unwrap_or(1400);
    let configured_udp_timeout = normalize_udp_timeout(
        values
            .get("MAGICNET_UDP_TIMEOUT")
            .map(String::as_str)
            .unwrap_or_default(),
    );

    let effective = fs::read_to_string(app.moddir.join(SINGBOX_CONFIG))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let tun = effective
        .as_ref()
        .and_then(|config| config.get("inbounds"))
        .and_then(Value::as_array)
        .and_then(|inbounds| {
            inbounds
                .iter()
                .find(|inbound| inbound.get("type").and_then(Value::as_str) == Some("tun"))
        });
    let effective_ipv6_mode = effective
        .as_ref()
        .and_then(|config| config.get("dns"))
        .and_then(|dns| dns.get("strategy"))
        .and_then(Value::as_str)
        .unwrap_or("unavailable");
    let effective_stack = tun
        .and_then(|tun| tun.get("stack"))
        .and_then(Value::as_str)
        .unwrap_or("unavailable");
    let effective_mtu = tun.and_then(|tun| tun.get("mtu")).and_then(Value::as_u64);
    let effective_udp_timeout = tun
        .and_then(|tun| tun.get("udp_timeout"))
        .and_then(Value::as_str)
        .unwrap_or("unavailable");

    envelope(
        "network.status",
        json!({
            "configured": {
                "ipv6_mode": configured_ipv6_mode,
                "mtu": configured_mtu,
                "udp_timeout": configured_udp_timeout,
            },
            "effective": {
                "ipv6_mode": effective_ipv6_mode,
                "stack": effective_stack,
                "mtu": effective_mtu,
                "udp_timeout": effective_udp_timeout,
            }
        }),
    )
}

fn sub_status_value(app: &App) -> Value {
    let values = read_kv(app.moddir.join(SUBSCRIPTION_STATUS));
    let source_mode = subscription_source_mode(app);
    let configured_count = if source_mode == "local_file" {
        1
    } else {
        clean_module_lines(app, Path::new(SUBSCRIPTION_URL))
            .map(|lines| lines.len())
            .unwrap_or(0)
    };
    let reason = values.get("reason").map(String::as_str).unwrap_or("none");
    let schedule_interval = fs::read_to_string(app.moddir.join(SUBSCRIPTION_REFRESH_HOURS))
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| matches!(value.as_str(), "12" | "24" | "48" | "72"))
        .unwrap_or_else(|| "off".to_string());
    let schedule_enabled = schedule_interval != "off";

    envelope(
        "sub.status",
        json!({
            "source": {
                "mode": source_mode,
                "configured_count": configured_count,
            },
            "update": {
                "lock_present": app.moddir.join(SUBSCRIPTION_UPDATE_LOCK).is_dir(),
                "transaction_pending": app.moddir.join(SUBSCRIPTION_TRANSACTION).is_dir(),
            },
            "last": {
                "phase": status_token(&values, "phase", "never"),
                "result": status_token(&values, "result", "never"),
                "attempt_epoch": status_u64(&values, "attempt_epoch"),
                "success_epoch": status_u64(&values, "success_epoch"),
                "configured_count": status_u64(&values, "configured_count"),
                "source_count": status_u64(&values, "source_count"),
                "imported_count": status_u64(&values, "imported_count"),
                "skipped_count": status_u64(&values, "skipped_count"),
                "generation_id": status_token(&values, "generation_id", "none"),
                "has_reason": !reason.is_empty() && reason != "none",
                "source_mode": status_token(&values, "source_mode", "unknown"),
                "native_parser": status_token(&values, "native_parser", "unknown"),
                "native_node_count": status_u64(&values, "native_node_count"),
                "converter_enabled": status_token(&values, "converter_enabled", "unknown"),
                "converter_available": status_token(&values, "converter_available", "unknown"),
                "converter_attempted": status_token(&values, "converter_attempted", "0"),
                "converter_format": status_token(&values, "converter_format", "none"),
                "converter_result": status_token(&values, "converter_result", "unknown"),
            },
            "cache": {
                "entries": directory_regular_file_count(&app.moddir.join(SUBSCRIPTION_CACHE)),
            },
            "schedule": {
                "interval_hours": schedule_interval,
                "enabled": schedule_enabled,
            }
        }),
    )
}

fn wifi_status_value(app: &App) -> Value {
    let current_mode = current_clash_mode(app).unwrap_or_else(|_| "unavailable".to_string());
    wifi_status_value_with_current(app, &current_mode)
}

fn wifi_status_value_with_current(app: &App, current_mode: &str) -> Value {
    let config = read_kv(app.moddir.join(WIFI_POLICY_CONF));
    let last = read_kv(app.moddir.join(WIFI_LAST_STATE));
    let enabled = config
        .get("MAGICNET_WIFI_POLICY_ENABLED")
        .is_some_and(|value| value == "1");
    let policy_mode = match config.get("MAGICNET_WIFI_POLICY_MODE").map(String::as_str) {
        Some("whitelist") => "whitelist",
        _ => "blacklist",
    };
    let interval_seconds = config
        .get("MAGICNET_WIFI_POLICY_INTERVAL")
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| (3..=300).contains(value))
        .unwrap_or(5);
    let connected = last.get("connected").is_some_and(|value| value == "1");
    let matched = last.get("matched").is_some_and(|value| value == "1");
    let desired_mode = match last.get("desired_mode").map(String::as_str) {
        Some("direct") => "direct",
        _ => "rule",
    };
    let has_ssid = last.get("ssid").is_some_and(|value| !value.is_empty());
    let has_bssid = last.get("bssid").is_some_and(|value| !value.is_empty());

    envelope(
        "wifi.status",
        json!({
            "policy": {
                "enabled": enabled,
                "mode": policy_mode,
                "interval_seconds": interval_seconds,
                "supervisor": supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy"),
            },
            "last_network": {
                "connected": connected,
                "matched": matched,
                "desired_mode": desired_mode,
                "has_ssid": has_ssid,
                "has_bssid": has_bssid,
            },
            "current_mode": current_mode,
            "entries": {
                "ssid_count": clean_module_lines(app, Path::new(WIFI_SSID_LIST))
                    .map(|values| values.len())
                    .unwrap_or(0),
                "bssid_count": clean_module_lines(app, Path::new(WIFI_BSSID_LIST))
                    .map(|values| values.len())
                    .unwrap_or(0),
            }
        }),
    )
}

fn api_readiness(app: &App, process_state: &str) -> Option<bool> {
    match process_state {
        "running" => Some(current_clash_mode(app).is_ok()),
        "stopped" => Some(false),
        _ => None,
    }
}

fn combine_readiness(api_ready: Option<bool>, dataplane_ready: Option<bool>) -> Option<bool> {
    match (api_ready, dataplane_ready) {
        (Some(false), _) | (_, Some(false)) => Some(false),
        (Some(true), Some(true)) => Some(true),
        _ => None,
    }
}

fn service_lifecycle(
    process_state: &str,
    transition: &str,
    overall_ready: Option<bool>,
) -> &'static str {
    match process_state {
        "stopped" => "stopped",
        "unknown" => "unknown",
        "running" if transition != "idle" => "reconfiguring",
        "running" => match overall_ready {
            Some(true) => "ready",
            Some(false) => "not_ready",
            None => "running_unknown",
        },
        _ => "unknown",
    }
}

fn subscription_source_mode(app: &App) -> &'static str {
    if clean_module_lines(app, Path::new(SUBSCRIPTION_LOCAL))
        .map(|lines| !lines.is_empty())
        .unwrap_or(false)
    {
        "local_file"
    } else {
        "remote_url"
    }
}

fn status_u64(values: &std::collections::HashMap<String, String>, key: &str) -> u64 {
    values
        .get(key)
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(0)
}

fn status_token(
    values: &std::collections::HashMap<String, String>,
    key: &str,
    fallback: &str,
) -> String {
    let Some(value) = values.get(key) else {
        return fallback.to_string();
    };
    let value = value.trim();
    if !value.is_empty()
        && value.len() <= 80
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        value.to_string()
    } else {
        fallback.to_string()
    }
}

fn directory_regular_file_count(path: &Path) -> usize {
    if !fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_dir()) {
        return 0;
    }
    fs::read_dir(path)
        .ok()
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
                .count()
        })
        .unwrap_or(0)
}

fn process_state(summary: &str) -> &'static str {
    if summary == "stopped" {
        "stopped"
    } else if summary == "unknown" {
        "unknown"
    } else if summary
        .split(',')
        .all(|pid| !pid.is_empty() && pid.bytes().all(|byte| byte.is_ascii_digit()))
    {
        "running"
    } else {
        "unknown"
    }
}

fn selected_core(app: &App) -> String {
    config_value(
        app,
        SELECTED_CORE_CONF,
        "MAGICNET_DEFAULT_CORE",
        "sing-box",
        &["sing-box", "singbox"],
    )
    .replace("singbox", "sing-box")
}

fn transparent_mode(app: &App) -> String {
    config_value(
        app,
        TRANSPARENT_MODE_CONF,
        "MAGICNET_TRANSPARENT_MODE",
        "tun",
        &["tun", "ebpf"],
    )
}

fn dns_profile(app: &App) -> String {
    let value = read_kv(app.moddir.join(DNS_CONF))
        .remove("MAGICNET_DNS_PROFILE")
        .unwrap_or_default();
    match value.as_str() {
        "cloudflare" | "cloudflare-doh" | "1.1.1.1-doh" | "doh" => "cloudflare-doh",
        "cloudflare-dot" | "1.1.1.1-dot" | "dot" => "cloudflare-dot",
        "cloudflare-udp" | "1.1.1.1" | "udp" => "cloudflare-udp",
        _ => "default",
    }
    .to_string()
}

fn normalize_ipv6_mode(value: &str) -> &'static str {
    match value {
        "ipv4_only" | "ipv4-only" | "compat" | "disabled" => "ipv4_only",
        "prefer_ipv6" | "prefer-ipv6" => "prefer_ipv6",
        _ => "prefer_ipv4",
    }
}

fn normalize_udp_timeout(value: &str) -> &'static str {
    match value {
        "1m" => "1m",
        "3m" => "3m",
        "10m" => "10m",
        "15m" => "15m",
        "30m" => "30m",
        _ => "5m",
    }
}

fn config_value(
    app: &App,
    relative_path: &str,
    key: &str,
    default: &str,
    allowed: &[&str],
) -> String {
    let value = read_kv(app.moddir.join(relative_path))
        .remove(key)
        .unwrap_or_else(|| default.to_string());
    if allowed.contains(&value.as_str()) {
        value
    } else {
        "invalid".to_string()
    }
}

fn singbox_rss_kib(summary: &str) -> Option<u64> {
    summary.split(',').try_fold(0u64, |total, pid| {
        let pid = pid.parse::<u32>().ok()?;
        let status = fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
        total.checked_add(parse_rss_kib(&status)?)
    })
}

fn parse_rss_kib(status: &str) -> Option<u64> {
    let mut fields = status
        .lines()
        .find_map(|line| line.strip_prefix("VmRSS:"))?
        .split_whitespace();
    let value = fields.next()?.parse().ok()?;
    (fields.next()? == "kB").then_some(value)
}

#[cfg(test)]
mod tests {
    use super::{
        capabilities_value, combine_readiness, dns_status_value, machine_value,
        network_status_value, parse_rss_kib, process_state, service_lifecycle,
        service_status_value, sub_status_value, transparent_status_value,
        wifi_status_value_with_current,
    };
    use crate::App;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture() -> (std::path::PathBuf, App) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "magicnet-machine-status-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(root.join(".config/magicnet")).expect("create magicnet config");
        fs::create_dir_all(root.join(".config/sing-box")).expect("create sing-box config");
        let app = App::for_test(root.clone());
        (root, app)
    }

    #[test]
    fn unsupported_machine_commands_are_rejected_before_normal_dispatch() {
        let (root, app) = fixture();
        let error = machine_value(&app, &["service", "start"]).expect_err("must reject mutation");
        assert_eq!(error.code, "machine.unsupported_command");
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn capabilities_advertise_schema_and_supported_commands() {
        let value = capabilities_value();
        assert_eq!(value["schema"], 1);
        assert_eq!(value["command"], "machine.capabilities");
        assert_eq!(value["data"]["machine_schema"], 1);
        assert_eq!(value["data"]["read_only"], true);
        let commands = value["data"]["commands"]
            .as_array()
            .expect("commands array");
        assert!(commands
            .iter()
            .any(|command| command.as_str() == Some("service.status")));
        assert!(commands
            .iter()
            .any(|command| command.as_str() == Some("transparent.status")));
        assert!(commands
            .iter()
            .any(|command| command.as_str() == Some("sub.status")));
        assert!(commands
            .iter()
            .any(|command| command.as_str() == Some("wifi.status")));
    }

    #[test]
    fn service_status_machine_contract_is_versioned_and_does_not_expose_subscription_url() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/current-core.conf"),
            "MAGICNET_DEFAULT_CORE=sing-box\n",
        )
        .expect("write core config");
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=ebpf\n",
        )
        .expect("write transparent config");
        fs::write(
            root.join(".config/sing-box/subscription.url"),
            "https://user:secret@example.invalid/sub\n",
        )
        .expect("write subscription url");

        let value = service_status_value(&app);
        assert_eq!(value["schema"], 1);
        assert_eq!(value["ok"], true);
        assert_eq!(value["command"], "service.status");
        assert_eq!(value["data"]["core"]["selected"], "sing-box");
        assert_eq!(value["data"]["transparent"]["mode"], "ebpf");
        assert_eq!(value["data"]["subscription"]["source"], "remote_url");
        assert!(!value.to_string().contains("example.invalid"));
        assert!(!value.to_string().contains("secret"));

        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn transparent_machine_status_keeps_configured_and_effective_modes_distinct() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=ebpf\n",
        )
        .expect("write transparent config");
        fs::write(
            root.join(".config/sing-box/config.json"),
            r#"{"inbounds":[{"tag":"tun-in","type":"ebpf","mode":"hybrid","network":["tcp","udp"],"local":{"cgroup_path":"/sys/fs/cgroup"},"shared":{"interface":["wlan0"]}}]}"#,
        )
        .expect("write effective config");
        let value = transparent_status_value(&app);
        assert_eq!(value["command"], "transparent.status");
        assert_eq!(value["data"]["configured_mode"], "ebpf");
        assert_eq!(value["data"]["effective_type"], "ebpf");
        assert_eq!(value["data"]["effective_mode"], "hybrid");
        assert_eq!(value["data"]["shared_interface_count"], 1);
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn local_subscription_source_wins_and_invalid_modes_are_explicit() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=redirect\n",
        )
        .expect("write invalid transparent config");
        fs::write(
            root.join(".config/sing-box/subscription.local"),
            "proxies: []\n",
        )
        .expect("write local subscription");

        let value = service_status_value(&app);
        assert_eq!(value["data"]["transparent"]["mode"], "invalid");
        assert_eq!(value["data"]["subscription"]["source"], "local_file");

        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn dns_status_uses_canonical_profile_without_exposing_config_text() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/dns.conf"),
            "MAGICNET_DNS_PROFILE=doh\nIGNORED_SECRET=do-not-return\n",
        )
        .expect("write dns config");
        let value = dns_status_value(&app);
        assert_eq!(value["command"], "dns.status");
        assert_eq!(value["data"]["profile"], "cloudflare-doh");
        assert_eq!(value["data"]["transport"], "doh");
        assert!(!value.to_string().contains("do-not-return"));
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn network_status_separates_configured_and_effective_values() {
        let (root, app) = fixture();
        fs::write(
            root.join(".config/magicnet/network-policy.conf"),
            "MAGICNET_IPV6_MODE=prefer_ipv6\nMAGICNET_TUN_MTU=1380\nMAGICNET_UDP_TIMEOUT=10m\n",
        )
        .expect("write network policy");
        fs::write(
            root.join(".config/sing-box/config.json"),
            r#"{"dns":{"strategy":"prefer_ipv6"},"inbounds":[{"type":"tun","stack":"mixed","mtu":1380,"udp_timeout":"10m"}]}"#,
        )
        .expect("write effective config");
        let value = network_status_value(&app);
        assert_eq!(value["command"], "network.status");
        assert_eq!(value["data"]["configured"]["mtu"], 1380);
        assert_eq!(value["data"]["effective"]["stack"], "mixed");
        assert_eq!(value["data"]["effective"]["udp_timeout"], "10m");
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn subscription_status_reports_lifecycle_without_leaking_urls_or_reason() {
        let (root, app) = fixture();
        fs::create_dir_all(root.join(".state/sing-box/subscription-cache"))
            .expect("create subscription cache");
        fs::write(
            root.join(".config/sing-box/subscription.url"),
            "https://user:TOP-SECRET@example.invalid/sub\nhttps://example.invalid/second\n",
        )
        .expect("write subscriptions");
        fs::write(
            root.join(".state/sing-box/subscription-status"),
            "phase=activate\nresult=failed\nattempt_epoch=123\nsuccess_epoch=100\nconfigured_count=2\nsource_count=2\nimported_count=3\nskipped_count=1\ngeneration_id=123-456\nreason=TOP-SECRET\nsource_mode=url\nnative_parser=share-links\nnative_node_count=3\nconverter_enabled=1\nconverter_available=1\nconverter_attempted=0\nconverter_format=none\nconverter_result=unused\n",
        )
        .expect("write subscription status");
        fs::write(root.join(".state/sing-box/subscription-cache/a.json"), "{}")
            .expect("write cache");
        fs::write(
            root.join(".config/magicnet/subscription-refresh-hours"),
            "24\n",
        )
        .expect("write schedule");

        let value = sub_status_value(&app);
        assert_eq!(value["command"], "sub.status");
        assert_eq!(value["data"]["source"]["configured_count"], 2);
        assert_eq!(value["data"]["last"]["result"], "failed");
        assert_eq!(value["data"]["last"]["has_reason"], true);
        assert_eq!(value["data"]["cache"]["entries"], 1);
        assert_eq!(value["data"]["schedule"]["interval_hours"], "24");
        let encoded = value.to_string();
        assert!(!encoded.contains("TOP-SECRET"));
        assert!(!encoded.contains("example.invalid"));
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn wifi_status_does_not_expose_ssid_or_bssid_values() {
        let (root, app) = fixture();
        fs::create_dir_all(root.join(".state/wifi-policy")).expect("create wifi state");
        fs::write(
            root.join(".config/magicnet/wifi-policy.conf"),
            "MAGICNET_WIFI_POLICY_ENABLED=1\nMAGICNET_WIFI_POLICY_MODE=whitelist\nMAGICNET_WIFI_POLICY_INTERVAL=12\n",
        )
        .expect("write wifi policy");
        fs::write(
            root.join(".config/magicnet/wifi-ssid.list"),
            "SECRET-WIFI\n",
        )
        .expect("write ssid list");
        fs::write(
            root.join(".config/magicnet/wifi-bssid.list"),
            "aa:bb:cc:dd:ee:ff\n",
        )
        .expect("write bssid list");
        fs::write(
            root.join(".state/wifi-policy/last-state.conf"),
            "connected=1\nssid=SECRET-WIFI\nbssid=aa:bb:cc:dd:ee:ff\nmatched=1\ndesired_mode=rule\n",
        )
        .expect("write wifi state");

        let value = wifi_status_value_with_current(&app, "rule");
        assert_eq!(value["command"], "wifi.status");
        assert_eq!(value["data"]["policy"]["enabled"], true);
        assert_eq!(value["data"]["policy"]["mode"], "whitelist");
        assert_eq!(value["data"]["last_network"]["connected"], true);
        assert_eq!(value["data"]["last_network"]["has_ssid"], true);
        assert_eq!(value["data"]["entries"]["ssid_count"], 1);
        let encoded = value.to_string();
        assert!(!encoded.contains("SECRET-WIFI"));
        assert!(!encoded.contains("aa:bb:cc:dd:ee:ff"));
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn readiness_requires_both_control_plane_and_dataplane() {
        assert_eq!(combine_readiness(Some(true), Some(true)), Some(true));
        assert_eq!(combine_readiness(Some(true), Some(false)), Some(false));
        assert_eq!(combine_readiness(Some(false), None), Some(false));
        assert_eq!(combine_readiness(Some(true), None), None);
    }

    #[test]
    fn lifecycle_never_calls_a_pid_only_service_ready() {
        assert_eq!(service_lifecycle("stopped", "idle", Some(false)), "stopped");
        assert_eq!(service_lifecycle("unknown", "idle", None), "unknown");
        assert_eq!(
            service_lifecycle("running", "switching", Some(false)),
            "reconfiguring"
        );
        assert_eq!(
            service_lifecycle("running", "idle", Some(false)),
            "not_ready"
        );
        assert_eq!(service_lifecycle("running", "idle", None), "running_unknown");
        assert_eq!(service_lifecycle("running", "idle", Some(true)), "ready");
    }

    #[test]
    fn process_state_never_treats_unknown_or_malformed_pid_summary_as_running() {
        assert_eq!(process_state("stopped"), "stopped");
        assert_eq!(process_state("unknown"), "unknown");
        assert_eq!(process_state("123,456"), "running");
        assert_eq!(process_state("123,broken"), "unknown");
        assert_eq!(process_state(""), "unknown");
    }

    #[test]
    fn parses_proc_rss_kib() {
        assert_eq!(parse_rss_kib("Name:\ttest\nVmRSS:\t2048 kB\n"), Some(2048));
        assert_eq!(parse_rss_kib("VmRSS:\t2 MB\n"), None);
    }
}
