use std::fs;

use serde_json::{json, Value};

use crate::{
    diagnostics::supervisor_pid, read_kv, service::singbox_webui, singbox_pid_summary, App,
};

const MACHINE_SCHEMA: u64 = 1;
const SELECTED_CORE_CONF: &str = ".config/magicnet/current-core.conf";
const TRANSPARENT_MODE_CONF: &str = ".config/magicnet/transparent-mode.conf";
const DNS_CONF: &str = ".config/magicnet/dns.conf";
const NETWORK_POLICY_CONF: &str = ".config/magicnet/network-policy.conf";
const SINGBOX_CONFIG: &str = ".config/sing-box/config.json";

pub(crate) fn dispatch(app: &App, args: &[String]) -> Option<Result<(), String>> {
    let command = normalized_machine_args(args)?;
    let value = match command.as_slice() {
        [command, action] if command == "service" && action == "status" => {
            service_status_value(app)
        }
        [command, action] if command == "core" && action == "status" => core_status_value(app),
        [command, action] if command == "supervisor" && action == "status" => {
            supervisor_status_value(app)
        }
        [command, action] if command == "dns" && action == "status" => dns_status_value(app),
        [command, action] if command == "network" && action == "status" => {
            network_status_value(app)
        }
        _ => return None,
    };
    Some(print_machine_value(&value))
}

fn normalized_machine_args(args: &[String]) -> Option<Vec<&str>> {
    let mut normalized = Vec::with_capacity(args.len());
    let mut json_flags = 0usize;
    for arg in args {
        if arg == "--json" {
            json_flags += 1;
        } else {
            normalized.push(arg.as_str());
        }
    }
    (json_flags == 1).then_some(normalized)
}

fn print_machine_value(value: &Value) -> Result<(), String> {
    let encoded =
        serde_json::to_string(value).map_err(|err| format!("serialize machine status: {err}"))?;
    println!("{encoded}");
    Ok(())
}

fn envelope(command: &str, data: Value) -> Value {
    json!({
        "schema": MACHINE_SCHEMA,
        "ok": true,
        "command": command,
        "data": data,
    })
}

fn service_status_value(app: &App) -> Value {
    let singbox = singbox_pid_summary(app);
    let running = singbox != "stopped";
    let rss_kib = singbox_rss_kib(&singbox);
    let selected = selected_core(app);
    let transparent = transparent_mode(app);
    let subscription_source = if app
        .moddir
        .join(".config/sing-box/subscription.local")
        .metadata()
        .map(|metadata| metadata.len() > 0)
        .unwrap_or(false)
    {
        "local_file"
    } else {
        "remote_url"
    };

    envelope(
        "service.status",
        json!({
            "core": {
                "selected": selected,
                "sing_box": {
                    "running": running,
                    "pid_summary": singbox,
                    "rss_kib": rss_kib,
                }
            },
            "supervisors": supervisor_data(app),
            "transparent": {
                "mode": transparent,
            },
            "api": {
                "url": app.api,
                "webui": singbox_webui(app),
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
    let effective_mtu = tun
        .and_then(|tun| tun.get("mtu"))
        .and_then(Value::as_u64);
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
        dns_status_value, network_status_value, normalized_machine_args, parse_rss_kib,
        service_status_value,
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
    fn machine_flag_accepts_prefix_or_suffix_and_rejects_duplicates() {
        let prefix = vec!["--json", "dns", "status"]
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        let suffix = vec!["dns", "status", "--json"]
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        let duplicate = vec!["--json", "dns", "status", "--json"]
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        assert_eq!(normalized_machine_args(&prefix), Some(vec!["dns", "status"]));
        assert_eq!(normalized_machine_args(&suffix), Some(vec!["dns", "status"]));
        assert_eq!(normalized_machine_args(&duplicate), None);
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
    fn parses_proc_rss_kib() {
        assert_eq!(parse_rss_kib("Name:\ttest\nVmRSS:\t2048 kB\n"), Some(2048));
        assert_eq!(parse_rss_kib("VmRSS:\t2 MB\n"), None);
    }
}
