use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::net::IpAddr;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::diagnostics_dns::dns_leak_check;
use crate::diagnostics_routing::routing_policy_check;
use crate::{
    clean_module_lines, cmdline_has_command, cmdline_has_script, command_text_timeout, mcp,
    pid_summary, singbox_pid_summary, App,
};

pub(crate) fn health(app: &App) -> Result<(), String> {
    for (key, ok, detail) in health_items(app) {
        print_check(key, &ok, detail);
    }
    Ok(())
}

fn health_items(app: &App) -> Vec<(&'static str, bool, String)> {
    let singbox = singbox_pid_summary(app);
    let mode = transparent_mode(app);
    let (tun_ok, tun_detail) = tun_check(app, &mode);
    let (network_ok, network_detail) = network_policy_check(app);
    let ecapture = app.moddir.join("bin/ecapture");
    let (dns_ok, dns_detail) = dns_leak_check(app, &singbox, &mode);
    let (routing_ok, routing_detail) = routing_policy_check(app);
    let (tailscale_ok, tailscale_detail) = tailscale_check(app);
    let (loop_guard_ok, loop_guard_detail) = traffic_loop_guard_check(app);
    let (api_ok, api_detail) = api_probe(&app.api);
    let (_, mcp_bind, mcp_port, mcp_pid) = mcp::status(app);
    vec![
        ("Core", running(&singbox), format!("sing-box={singbox}")),
        ("TUN", tun_ok, tun_detail),
        ("UDP/IPv6", network_ok, network_detail),
        (
            "eCapture",
            ecapture.is_file(),
            format!("binary={}", ecapture.display()),
        ),
        ("DNS Leak", dns_ok, dns_detail),
        ("Routing Policy", routing_ok, routing_detail),
        ("Tailscale", tailscale_ok, tailscale_detail),
        ("Traffic Loop Guard", loop_guard_ok, loop_guard_detail),
        ("Core API", api_ok, api_detail),
        (
            "Subscription",
            has_subscription(app)
                || app
                    .moddir
                    .join(".config/sing-box/standalone-config")
                    .is_file(),
            if app
                .moddir
                .join(".config/sing-box/standalone-config")
                .is_file()
            {
                "validated standalone config present".to_string()
            } else {
                "subscription config present".to_string()
            },
        ),
        (
            "MCP",
            mcp_pid.ne("stopped"),
            format!("pid={mcp_pid}, url=http://{mcp_bind}:{mcp_port}/mcp"),
        ),
        (
            "WebUI",
            app.moddir.join("webroot/index.html").exists(),
            app.moddir.join("webroot").display().to_string(),
        ),
    ]
}

fn tailscale_check(app: &App) -> (bool, String) {
    const TAILNETS: [&str; 2] = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"];
    let config_dir = app.moddir.join(".config/sing-box");
    let Ok(text) = fs::read_to_string(config_dir.join("config.json")) else {
        return (false, "config missing".to_string());
    };
    let Ok(config) = serde_json::from_str::<Value>(&text) else {
        return (false, "config invalid".to_string());
    };
    let endpoint = config
        .get("endpoints")
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().find(|item| {
                item.get("type").and_then(Value::as_str) == Some("tailscale")
                    && item
                        .get("tag")
                        .and_then(Value::as_str)
                        .is_some_and(|tag| !tag.is_empty())
                    && !item
                        .get("system_interface")
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
            })
        });
    let Some(endpoint) = endpoint else {
        return (true, "configured=false".to_string());
    };
    let tag = endpoint
        .get("tag")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let state = endpoint
        .get("state_directory")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .map(|path| {
            if path.is_absolute() {
                path
            } else {
                config_dir.join(path)
            }
        })
        .unwrap_or_else(|| app.moddir.join(".state/sing-box/tailscale"));
    let state_created = state.exists();
    let tun_ingress = config
        .get("inbounds")
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().find(|item| {
                item.get("type").and_then(Value::as_str) == Some("tun")
                    && item.get("tag").and_then(Value::as_str) == Some("tun-in")
            })
        })
        .and_then(|tun| tun.get("route_exclude_address"))
        .and_then(Value::as_array)
        .is_some_and(|excluded| {
            TAILNETS
                .iter()
                .all(|cidr| !excluded.iter().any(|value| value.as_str() == Some(cidr)))
        });
    let route_linked = config
        .get("route")
        .and_then(|route| route.get("rules"))
        .and_then(Value::as_array)
        .is_some_and(|rules| {
            rules.iter().any(|rule| {
                rule.get("outbound").and_then(Value::as_str) == Some(tag)
                    && rule
                        .get("ip_cidr")
                        .and_then(Value::as_array)
                        .is_some_and(|cidrs| {
                            TAILNETS
                                .iter()
                                .all(|cidr| cidrs.iter().any(|value| value.as_str() == Some(cidr)))
                        })
            })
        });
    (
        state_created && tun_ingress && route_linked,
        format!(
            "configured=true tag={tag} state_created={} tun_ingress={} route_linked={}",
            state_created as u8, tun_ingress as u8, route_linked as u8
        ),
    )
}

pub(crate) fn topology(app: &App) -> Result<(), String> {
    println!("MagicNet network topology");
    println!("module={}", app.moddir.display());
    println!();
    println!("[interfaces]");
    println!(
        "{}",
        command_text_timeout("ip", &["-o", "addr", "show"], crate::SHORT_TIMEOUT)
    );
    println!();
    println!("[routes]");
    sysroute_snapshot();
    println!();
    println!("[forwarding]");
    println!(
        "{}",
        command_text_timeout(
            "sh",
            &["-c", "iptables -t nat -S 2>/dev/null | head -80"],
            crate::SHORT_TIMEOUT
        )
    );
    Ok(())
}

pub(crate) fn sysroute(args: &[String]) -> Result<(), String> {
    match args.get(1).map(String::as_str).unwrap_or("snapshot") {
        "list" | "snapshot" => {
            sysroute_snapshot();
            Ok(())
        }
        "add-rule" => ip(&["rule", "add", "priority", arg(args, 2)?, "lookup", arg(args, 3)?]),
        "del-rule" => ip(&["rule", "del", "priority", arg(args, 2)?]),
        "add-route" => {
            let table = arg(args, 2)?;
            let dest = normalize_default(arg(args, 3)?);
            let dev = arg(args, 4)?;
            if let Some(via) = args.get(5).map(String::as_str) {
                ip(&["route", "add", "table", table, dest, "via", via, "dev", dev])
            } else {
                ip(&["route", "add", "table", table, dest, "dev", dev])
            }
        }
        "del-route" => {
            let table = arg(args, 2)?;
            let dest = normalize_default(arg(args, 3)?);
            ip(&["route", "del", "table", table, dest])
        }
        _ => Err("Usage: cli sysroute {snapshot|add-rule <priority> <table>|del-rule <priority>|add-route <table> <dest|default> <dev> [via]|del-route <table> <dest|default>}".to_string()),
    }
}

pub(crate) fn support(app: &App, args: &[String]) -> Result<(), String> {
    if args.first().map(String::as_str).unwrap_or_default() != "bundle" {
        return Err("Usage: cli support bundle".to_string());
    }
    print!("{}", support_bundle(app));
    Ok(())
}

fn support_bundle(app: &App) -> String {
    let singbox = singbox_pid_summary(app);
    let mode = transparent_mode(app);
    let mut output = String::from("MagicNet canonical support bundle\n");
    append_support_section(
        &mut output,
        "subscription lifecycle",
        &subscription_evidence(app),
    );
    append_support_section(
        &mut output,
        "service status",
        &format!(
            "module_enabled={}\ncore={}\nfswatch={}\ntransparent_mode={mode}",
            !app.moddir.join("disable").exists(),
            singbox,
            pid_summary("fswatch")
        ),
    );
    append_support_section(&mut output, "startup state", &startup_state_evidence(app));
    let health = health_items(app)
        .into_iter()
        .map(|(key, ok, detail)| format!("{} {key}: {detail}", if ok { "ok" } else { "warn" }))
        .collect::<Vec<_>>()
        .join("\n");
    append_support_section(&mut output, "health", &health);
    append_support_section(
        &mut output,
        "core process and listeners",
        &format!(
            "core_process={singbox}\n{}",
            read_only_command("ss", &["-lntup"])
        ),
    );
    append_support_section(
        &mut output,
        "tun routes and ip rules",
        &[
            read_only_command("ip", &["-o", "link", "show"]),
            read_only_command("ip", &["-o", "addr", "show"]),
            read_only_command("ip", &["rule", "show"]),
            read_only_command("ip", &["route", "show", "table", "all"]),
        ]
        .join("\n"),
    );
    append_support_section(
        &mut output,
        "proxy selector and connection chains",
        &proxy_chain_evidence(app),
    );
    let (dns_ok, dns_detail) = dns_leak_check(app, &singbox, &mode);
    let (api_ok, api_detail) = api_probe(&app.api);
    let (mcp_enabled, mcp_bind, mcp_port, mcp_pid) = mcp::status(app);
    append_support_section(
        &mut output,
        "dns api and mcp",
        &format!(
            "dns_ok={dns_ok} detail={dns_detail}\napi_ok={api_ok} detail={api_detail}\nmcp_enabled={mcp_enabled} bind={mcp_bind} port={mcp_port} pid={mcp_pid}"
        ),
    );
    append_support_section(
        &mut output,
        "subscription refresh log counts",
        &subscription_refresh_log_counts(app.log_dir.join("subscription-refresh.log")),
    );
    output
}

const SUPPORT_CHAIN_TAGS: &[&str] = &[
    "proxy",
    "chain",
    "chain-hop1",
    "chain-exit",
    "chain-auto",
    "select",
    "final",
    "proxy-rule",
    "dns-guard",
    "network-test",
    "hotspot",
    "download-direct",
    "dev-proxy",
    "social-proxy",
    "media-proxy",
    "game-proxy",
    "telegram-proxy",
    "ai-proxy",
    "ai-chatgpt",
    "ai-gemini",
    "ai-grok",
    "ai-claude",
    "direct",
    "block",
];

fn proxy_chain_evidence(app: &App) -> String {
    let proxies = crate::webui_api::curl_get_json(app, "/proxies").ok();
    let connections = crate::webui_api::curl_get_json(app, "/connections").ok();
    proxy_chain_evidence_from_values(proxies.as_ref(), connections.as_ref())
}

fn proxy_chain_evidence_from_values(
    proxies: Option<&Value>,
    connections: Option<&Value>,
) -> String {
    let proxy_map = proxies
        .and_then(|root| root.get("proxies"))
        .and_then(Value::as_object);
    let mut lines = Vec::new();
    if let Some(proxy_map) = proxy_map {
        lines.push("selector_snapshot=available".to_string());
        for tag in SUPPORT_CHAIN_TAGS {
            if proxy_map.contains_key(*tag) {
                lines.push(format!(
                    "selector.{tag}={}",
                    sanitized_selector_chain(tag, proxy_map)
                ));
            }
        }
    } else {
        lines.push("selector_snapshot=unavailable".to_string());
    }

    let Some(items) = connections
        .and_then(|root| root.get("connections"))
        .and_then(Value::as_array)
    else {
        lines.push("active_connections=unavailable".to_string());
        return lines.join("\n");
    };
    lines.push(format!("active_connection_count={}", items.len()));
    let mut chain_counts = BTreeMap::<String, usize>::new();
    for item in items {
        let chain = item
            .get("chains")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(|tag| sanitized_chain_hop(tag, proxy_map))
                    .collect::<Vec<_>>()
                    .join(" -> ")
            })
            .filter(|chain| !chain.is_empty())
            .unwrap_or_else(|| "<empty>".to_string());
        *chain_counts.entry(chain).or_default() += 1;
    }
    let mut chains = chain_counts.into_iter().collect::<Vec<_>>();
    chains.sort_by(|(left_chain, left_count), (right_chain, right_count)| {
        right_count
            .cmp(left_count)
            .then_with(|| left_chain.cmp(right_chain))
    });
    for (index, (chain, count)) in chains.into_iter().take(10).enumerate() {
        lines.push(format!(
            "active_chain.{}=count:{count} chain:{chain}",
            index + 1
        ));
    }
    lines.join("\n")
}

fn sanitized_selector_chain(start: &str, proxies: &serde_json::Map<String, Value>) -> String {
    let mut chain = Vec::new();
    let mut visited = Vec::new();
    let mut current = start;
    loop {
        if chain.len() >= 12 {
            chain.push("<truncated>".to_string());
            break;
        }
        if visited.contains(&current) {
            chain.push("<cycle>".to_string());
            break;
        }
        visited.push(current);
        chain.push(sanitized_chain_hop(current, Some(proxies)));
        let Some(next) = proxies
            .get(current)
            .and_then(|proxy| proxy.get("now"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            break;
        };
        current = next;
    }
    chain.join(" -> ")
}

fn sanitized_chain_hop(tag: &str, proxies: Option<&serde_json::Map<String, Value>>) -> String {
    if SUPPORT_CHAIN_TAGS.contains(&tag) {
        return tag.to_string();
    }
    let kind = proxies
        .and_then(|items| items.get(tag))
        .and_then(|proxy| proxy.get("type"))
        .and_then(Value::as_str)
        .map(safe_proxy_kind)
        .unwrap_or("unknown");
    format!("<node:{kind}>")
}

fn safe_proxy_kind(value: &str) -> &str {
    match value.to_ascii_lowercase().as_str() {
        "shadowsocks" => "shadowsocks",
        "vmess" => "vmess",
        "vless" => "vless",
        "trojan" => "trojan",
        "hysteria2" => "hysteria2",
        "anytls" => "anytls",
        "tuic" => "tuic",
        "wireguard" => "wireguard",
        "socks" => "socks",
        "http" => "http",
        "selector" => "selector",
        "urltest" => "urltest",
        "direct" => "direct",
        "block" => "block",
        _ => "unknown",
    }
}

fn startup_state_evidence(app: &App) -> String {
    let path = app.moddir.join(".state/startup-error");
    match fs::read_to_string(path) {
        Ok(text) if !text.trim().is_empty() => {
            format!(
                "blocked=true\nreason={}",
                clean_lines_from_text(&text).join(" ")
            )
        }
        _ => "blocked=false\nreason=none".to_string(),
    }
}

fn clean_lines_from_text(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect()
}

fn append_support_section(output: &mut String, title: &str, evidence: &str) {
    output.push_str(&format!("[{title}]\n"));
    if evidence.trim().is_empty() {
        output.push_str("unavailable\n");
        return;
    }
    for line in evidence.lines().take(100) {
        output.push_str(&redact(line));
        output.push('\n');
    }
}

fn read_only_command(program: &str, args: &[&str]) -> String {
    read_only_command_with_timeout(program, args, Duration::from_secs(3))
}

fn read_only_command_with_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    let mut child = match Command::new(program)
        .args(args)
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(err) => return format!("{program}=unavailable reason={err}"),
    };

    let stdout_reader = child.stdout.take().map(|stdout| {
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stdout.take(4096).read_to_end(&mut bytes);
            bytes
        })
    });
    let stderr_reader = child.stderr.take().map(|stderr| {
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stderr.take(4096).read_to_end(&mut bytes);
            bytes
        })
    });

    let started = Instant::now();
    let command_error = loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                if stdout_reader
                    .as_ref()
                    .is_some_and(|reader| !reader.is_finished())
                    || stderr_reader
                        .as_ref()
                        .is_some_and(|reader| !reader.is_finished())
                {
                    terminate_read_only_process_group(&mut child);
                }
                break None;
            }
            Ok(None) if started.elapsed() >= timeout => {
                terminate_read_only_process_group(&mut child);
                break Some(format!("{program}=timeout after {}ms", timeout.as_millis()));
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(err) => {
                terminate_read_only_process_group(&mut child);
                break Some(format!("{program}=unavailable reason={err}"));
            }
        }
    };

    let stdout = stdout_reader
        .and_then(|reader| reader.join().ok())
        .unwrap_or_default();
    let stderr = stderr_reader
        .and_then(|reader| reader.join().ok())
        .unwrap_or_default();
    if let Some(error) = command_error {
        return error;
    }

    let mut text = String::from_utf8_lossy(&stdout).to_string();
    if !stderr.is_empty() {
        text.push_str(&String::from_utf8_lossy(&stderr));
    }
    text = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .take(4)
        .collect::<Vec<_>>()
        .join("\n");
    if text.chars().count() > 600 {
        text = text.chars().take(600).collect();
        text.push_str("\n[truncated]");
    }
    text
}

fn terminate_read_only_process_group(child: &mut Child) {
    let process_group = -(child.id() as i32);
    unsafe {
        libc::kill(process_group, libc::SIGKILL);
    }
    let _ = child.wait();
}

fn subscription_evidence(app: &App) -> String {
    const STATUS_KEYS: &[(&str, &str)] = &[
        ("phase", "last_phase"),
        ("result", "last_result"),
        ("attempt_epoch", "last_attempt_epoch"),
        ("success_epoch", "last_success_epoch"),
        ("configured_count", "last_configured_count"),
        ("source_count", "last_source_count"),
        ("imported_count", "last_imported_count"),
        ("skipped_count", "last_skipped_count"),
        ("generation_id", "last_generation_id"),
        ("reason", "last_reason"),
        ("source_mode", "last_source_mode"),
        ("native_parser", "last_native_parser"),
        ("native_node_count", "last_native_node_count"),
        ("converter_enabled", "last_converter_enabled"),
        ("converter_available", "last_converter_available"),
        ("converter_attempted", "last_converter_attempted"),
        ("converter_format", "last_converter_format"),
        ("converter_result", "last_converter_result"),
    ];
    let status = fs::read_to_string(app.moddir.join(".state/sing-box/subscription-status"))
        .unwrap_or_default();
    let local_source = app.moddir.join(".config/sing-box/subscription.local");
    let source_mode = if fs::metadata(&local_source)
        .map(|metadata| metadata.len() > 0)
        .unwrap_or(false)
    {
        "local"
    } else {
        "url"
    };
    let update_owner = process_owner_state(
        &app.moddir
            .join(".state/sing-box/subscription-update.lock/owner"),
        None,
    );
    let mut lines = vec![
        format!(
            "configured_count={}",
            if fs::metadata(&local_source)
                .map(|metadata| metadata.len() > 0)
                .unwrap_or(false)
            {
                1
            } else {
                clean_module_lines(app, Path::new(".config/sing-box/subscription.url"))
                    .unwrap_or_default()
                    .len()
            }
        ),
        format!("source_mode={source_mode}"),
        format!("update_running={}", (update_owner == "active") as u8),
        format!("update_lock_owner={update_owner}"),
        format!("update_owner={update_owner}"),
    ];
    for (source_key, output_key) in STATUS_KEYS {
        let value = status
            .lines()
            .find_map(|line| line.split_once('=').filter(|(key, _)| key == source_key))
            .map(|(_, value)| value.trim())
            .unwrap_or("unknown");
        lines.push(format!("{output_key}={value}"));
    }
    let cache_dir = app.moddir.join(".state/sing-box/subscription-cache");
    let (cache_count, provenance_count) = fs::read_dir(cache_dir)
        .map(|entries| {
            entries
                .flatten()
                .fold((0usize, 0usize), |(cache, provenance), entry| {
                    let name = entry.file_name();
                    let name = name.to_string_lossy();
                    (
                        cache + usize::from(name.ends_with(".yaml")),
                        provenance + usize::from(name.ends_with(".yaml.identity")),
                    )
                })
        })
        .unwrap_or_default();
    lines.push(format!("cache_count={cache_count}"));
    lines.push(format!("cache_provenance_count={provenance_count}"));
    lines.push("cache_source=url_sha256_identity".to_string());
    let interval = fs::read_to_string(
        app.moddir
            .join(".config/magicnet/subscription-refresh-hours"),
    )
    .ok()
    .map(|value| value.trim().to_string())
    .filter(|value| matches!(value.as_str(), "12" | "24" | "48" | "72"))
    .unwrap_or_else(|| "off".to_string());
    lines.push(format!("schedule_interval_hours={interval}"));
    lines.push(format!(
        "schedule_owner={}",
        subscription_schedule_owner_state(app)
    ));
    lines.join("\n")
}

fn subscription_schedule_owner_state(app: &App) -> &'static str {
    let state_dir = app.moddir.join(".state/watchdog");
    let owner = state_dir.join("magicnet-subscription-refresh.owner");
    let loop_file = state_dir.join("magicnet-subscription-refresh.loop.sh");
    process_owner_state(&owner, Some(&loop_file))
}

fn process_owner_state(
    owner: &std::path::Path,
    exact_script: Option<&std::path::Path>,
) -> &'static str {
    let Ok(record) = fs::read_to_string(owner) else {
        return "none";
    };
    let mut fields = record.trim().split(':');
    let Some(pid) = fields.next().and_then(|value| value.parse::<u32>().ok()) else {
        return "stale";
    };
    let Some(expected_start) = fields.next() else {
        return "stale";
    };
    let live_start = fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()
        .and_then(|stat| crate::proc_start_time(&stat));
    if live_start.as_deref() != Some(expected_start) {
        return "stale";
    }
    if let Some(script) = exact_script {
        let cmdline = fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
        let argv = cmdline.split(|byte| *byte == 0).collect::<Vec<_>>();
        if argv.get(1).copied() != Some(script.as_os_str().as_encoded_bytes()) {
            return "stale";
        }
    }
    "active"
}

fn print_check(key: &str, ok: &bool, detail: String) {
    let status = if *ok { "ok" } else { "warn" };
    println!("[{status}] {key}: {}", redact(&detail));
}

fn running(core: &str) -> bool {
    core != "stopped"
}

fn transparent_mode(app: &App) -> String {
    fs::read_to_string(app.moddir.join(".config/magicnet/transparent-mode.conf"))
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let (_, value) = line.split_once('=')?;
                match value.trim() {
                    "proxy" | "external" | "external-tun" | "hybrid" => Some("tun".to_string()),
                    "tun" => Some("tun".to_string()),
                    _ => None,
                }
            })
        })
        .unwrap_or_else(|| "tun".to_string())
}

fn iface_detail(name: &str) -> String {
    command_text_timeout("ip", &["addr", "show", name], crate::SHORT_TIMEOUT)
}

fn tun_check(app: &App, _mode: &str) -> (bool, String) {
    // MagicNet owns one transparent interface.  Accepting foreign TUN names
    // here can report a stale mihomo/Meta/utun interface as a healthy
    // MagicNet runtime even when magicnet0 is missing.
    let expected = "magicnet0";
    let configured = configured_tun_names(app);
    let configured_ok = configured_tun_is_canonical(&configured);
    if configured_ok && PathBuf::from(format!("/sys/class/net/{expected}")).exists() {
        return (true, format!("{expected}: {}", iface_detail(expected)));
    }
    (
        false,
        format!(
            "No canonical MagicNet TUN interface found. checked={expected} configured={}",
            if configured.is_empty() {
                "none".to_string()
            } else {
                configured.join(",")
            }
        ),
    )
}

fn configured_tun_is_canonical(names: &[String]) -> bool {
    !names.is_empty() && names.iter().all(|name| name == "magicnet0")
}

fn configured_tun_names(app: &App) -> Vec<String> {
    let Ok(text) = fs::read_to_string(app.moddir.join(".config/sing-box/config.json")) else {
        return Vec::new();
    };
    let Ok(config) = serde_json::from_str::<Value>(&text) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    for inbound in config
        .get("inbounds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|inbound| inbound.get("type").and_then(Value::as_str) == Some("tun"))
    {
        if let Some(name) = inbound.get("interface_name").and_then(Value::as_str) {
            push_unique(&mut names, name.to_string());
        }
    }
    names
}

fn traffic_loop_guard_check(app: &App) -> (bool, String) {
    let path = app.moddir.join(".config/sing-box/config.json");
    let Ok(text) = fs::read_to_string(&path) else {
        return (false, format!("config missing: {}", path.display()));
    };
    let Ok(config) = serde_json::from_str::<Value>(&text) else {
        return (false, "sing-box config is not valid JSON".to_string());
    };
    let tun = config
        .get("inbounds")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("type").and_then(Value::as_str) == Some("tun"))
        });
    let Some(tun) = tun else {
        return (false, "TUN inbound missing".to_string());
    };
    let root_excluded = tun
        .get("exclude_uid")
        .and_then(Value::as_array)
        .is_some_and(|items| items.iter().any(|value| value.as_u64() == Some(0)));
    let excluded_routes = tun
        .get("route_exclude_address")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let excludes_ipv4_loopback = excluded_routes
        .iter()
        .any(|value| value.as_str() == Some("127.0.0.0/8"));
    let excludes_ipv6_loopback = excluded_routes
        .iter()
        .any(|value| value.as_str() == Some("::1/128"));
    let loopback_servers = config
        .get("outbounds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|outbound| {
            let kind = outbound.get("type").and_then(Value::as_str)?;
            if !matches!(
                kind,
                "vless"
                    | "vmess"
                    | "trojan"
                    | "shadowsocks"
                    | "hysteria2"
                    | "tuic"
                    | "anytls"
                    | "socks"
            ) {
                return None;
            }
            let server = outbound.get("server").and_then(Value::as_str)?;
            let loopback = server.eq_ignore_ascii_case("localhost")
                || server
                    .parse::<IpAddr>()
                    .is_ok_and(|address| address.is_loopback());
            loopback.then(|| {
                outbound
                    .get("tag")
                    .and_then(Value::as_str)
                    .unwrap_or("unnamed")
                    .to_string()
            })
        })
        .collect::<Vec<_>>();
    let ok = root_excluded
        && excludes_ipv4_loopback
        && excludes_ipv6_loopback
        && loopback_servers.is_empty();
    (
        ok,
        format!(
            "exclude_uid_0={} ipv4_loopback_excluded={} ipv6_loopback_excluded={} loopback_proxy_servers={}",
            root_excluded as u8,
            excludes_ipv4_loopback as u8,
            excludes_ipv6_loopback as u8,
            if loopback_servers.is_empty() {
                "none".to_string()
            } else {
                loopback_servers.join(",")
            }
        ),
    )
}

fn network_policy_check(app: &App) -> (bool, String) {
    let path = app.moddir.join(".config/sing-box/config.json");
    let Ok(text) = fs::read_to_string(&path) else {
        return (false, format!("config missing: {}", path.display()));
    };
    let Ok(config) = serde_json::from_str::<Value>(&text) else {
        return (false, "sing-box config is not valid JSON".to_string());
    };
    let strategy = config
        .get("dns")
        .and_then(|dns| dns.get("strategy"))
        .and_then(Value::as_str)
        .unwrap_or("unset");
    let tun = config
        .get("inbounds")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("type").and_then(Value::as_str) == Some("tun"))
        });
    let stack = tun
        .and_then(|tun| tun.get("stack"))
        .and_then(Value::as_str)
        .unwrap_or("unset");
    let mtu = tun
        .and_then(|tun| tun.get("mtu"))
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let udp_timeout = tun
        .and_then(|tun| tun.get("udp_timeout"))
        .and_then(Value::as_str)
        .unwrap_or("unset");
    let ipv6_address = tun
        .and_then(|tun| tun.get("address"))
        .and_then(Value::as_array)
        .is_some_and(|addresses| {
            addresses
                .iter()
                .filter_map(Value::as_str)
                .any(|address| address.contains(':'))
        });
    let ipv6_guard = config
        .get("route")
        .and_then(|route| route.get("rules"))
        .and_then(Value::as_array)
        .is_some_and(|rules| rules.iter().any(is_managed_ipv6_guard));
    let strategy_ok = matches!(strategy, "ipv4_only" | "prefer_ipv4" | "prefer_ipv6");
    let guard_ok = if strategy == "ipv4_only" {
        ipv6_guard
    } else {
        !ipv6_guard
    };
    let address_ok = strategy == "ipv4_only" || ipv6_address;
    let ok = strategy_ok
        && stack == "mixed"
        && (1280..=1500).contains(&mtu)
        && matches!(udp_timeout, "1m" | "3m" | "5m" | "10m" | "15m" | "30m")
        && guard_ok
        && address_ok;
    (
        ok,
        format!(
            "strategy={strategy} stack={stack} mtu={mtu} udp_timeout={udp_timeout} ipv6_address={} ipv6_guard={}",
            ipv6_address as u8, ipv6_guard as u8
        ),
    )
}

fn is_managed_ipv6_guard(rule: &Value) -> bool {
    let Some(rule) = rule.as_object() else {
        return false;
    };
    let legacy_guard = rule.len() == 2
        && rule.get("ip_version").and_then(Value::as_u64) == Some(6)
        && rule.get("outbound").and_then(Value::as_str) == Some("block");
    let canonical_fields = (rule.len() == 3 && !rule.contains_key("method"))
        || (rule.len() == 4 && rule.get("method").and_then(Value::as_str) == Some("default"));
    legacy_guard
        || (canonical_fields
            && rule.get("ip_version").and_then(Value::as_u64) == Some(6)
            && rule.get("action").and_then(Value::as_str) == Some("reject")
            && rule.get("no_drop").and_then(Value::as_bool) == Some(true))
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !value.is_empty() && !values.iter().any(|item| item == &value) {
        values.push(value);
    }
}

fn api_probe(api: &str) -> (bool, String) {
    let base = api.trim_end_matches('/');
    let endpoint = format!("{base}/version");
    let text = command_text_timeout(
        "curl",
        &["-fsS", "--max-time", "2", &endpoint],
        crate::SHORT_TIMEOUT,
    );
    let ok = text.contains('{') || text.contains("version");
    (ok, endpoint)
}

pub(crate) fn supervisor_pid(app: &App, kind: &str, name: &str) -> String {
    let path = app
        .moddir
        .join(".state")
        .join(kind)
        .join(format!("{name}.pid"));
    fs::read_to_string(path)
        .ok()
        .and_then(|text| text.trim().parse::<u32>().ok())
        .filter(|pid| supervisor_pid_matches(app, *pid, name))
        .map(|pid| pid.to_string())
        .unwrap_or_else(|| "stopped".to_string())
}

fn supervisor_pid_matches(app: &App, pid: u32, name: &str) -> bool {
    let proc_dir = PathBuf::from(format!("/proc/{pid}"));
    if !proc_dir.exists() {
        return false;
    }
    let cmdline = fs::read(proc_dir.join("cmdline"))
        .ok()
        .map(|bytes| {
            String::from_utf8_lossy(&bytes)
                .replace('\0', " ")
                .trim()
                .to_string()
        })
        .unwrap_or_default();
    supervisor_cmdline_matches(&app.moddir, name, &cmdline)
}

fn supervisor_cmdline_matches(moddir: &Path, name: &str, cmdline: &str) -> bool {
    let module = moddir.to_string_lossy();
    match name {
        "magicnet-config" => {
            cmdline_has_script(
                cmdline,
                &format!("{module}/.state/fswatch/magicnet-config.loop.sh"),
            ) || cmdline_has_command(cmdline, &format!("{module}/cli"), &["config", "apply"])
        }
        "magicnet-wifi-policy" => {
            cmdline_has_command(cmdline, &format!("{module}/cli"), &["wifi", "watch"])
                || cmdline_has_command(
                    cmdline,
                    &format!("{module}/bin/magicnet-cli"),
                    &["wifi", "watch"],
                )
        }
        _ => false,
    }
}

fn has_subscription(app: &App) -> bool {
    [
        ".config/sing-box/subscription.url",
        ".config/sing-box/subscription.local",
    ]
    .into_iter()
    .any(|relative| {
        clean_module_lines(app, Path::new(relative))
            .map(|lines| !lines.is_empty())
            .unwrap_or(false)
    })
}

fn sysroute_snapshot() {
    println!("ip rule:");
    println!(
        "{}",
        command_text_timeout("ip", &["rule", "show"], crate::SHORT_TIMEOUT)
    );
    println!("ip route:");
    println!(
        "{}",
        command_text_timeout(
            "ip",
            &["route", "show", "table", "all"],
            crate::SHORT_TIMEOUT
        )
    );
}

fn ip(args: &[&str]) -> Result<(), String> {
    let output = Command::new("ip")
        .args(args)
        .output()
        .map_err(|err| format!("run ip: {err}"))?;
    print!("{}", String::from_utf8_lossy(&output.stdout));
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn arg(args: &[String], index: usize) -> Result<&str, String> {
    args.get(index)
        .map(String::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "missing argument".to_string())
}

fn normalize_default(value: &str) -> &str {
    if value == "default" {
        "default"
    } else {
        value
    }
}

fn subscription_refresh_log_counts(path: PathBuf) -> String {
    let text = fs::read_to_string(path).unwrap_or_default();
    let mut events = 0usize;
    let mut errors = 0usize;
    for line in text.lines().rev().take(200) {
        if line.trim().is_empty() {
            continue;
        }
        events += 1;
        let lower = line.to_ascii_lowercase();
        errors += usize::from(
            lower.contains("error")
                || lower.contains("failed")
                || lower.contains("fatal")
                || lower.contains("panic"),
        );
    }
    format!("subscription_refresh_event_count={events}\nsubscription_refresh_error_count={errors}")
}

pub(crate) fn redact(text: &str) -> String {
    let mut redact_next = 0;
    let parts = text.split_whitespace().collect::<Vec<_>>();
    parts
        .iter()
        .enumerate()
        .map(|(index, part)| {
            let part = *part;
            let lower = part.to_ascii_lowercase();
            if redact_next > 0 {
                redact_next -= 1;
                return "<redacted-value>".to_string();
            }
            if lower.contains("http://") || lower.contains("https://") {
                "<redacted-url>".to_string()
            } else if contains_sensitive_assignment(&lower) {
                "<redacted-sensitive>".to_string()
            } else if let Some(has_inline_value) = sensitive_key(part) {
                let is_safe_url_status = !has_inline_value
                    && part
                        .trim_matches(|ch: char| matches!(ch, '(' | ')' | ',' | ';' | '"' | '\''))
                        .eq_ignore_ascii_case("url")
                    && parts
                        .get(index + 1)
                        .is_some_and(|next| next.eq_ignore_ascii_case("is"))
                    && parts.get(index + 2).is_some_and(|next| {
                        next.trim_matches(|ch: char| {
                            matches!(ch, '(' | ')' | ',' | ';' | '"' | '\'')
                        })
                        .eq_ignore_ascii_case("configured")
                    });
                if is_safe_url_status {
                    part.to_string()
                } else {
                    let url_precedes_copula = !has_inline_value
                        && part
                            .trim_matches(|ch: char| {
                                matches!(ch, '(' | ')' | ',' | ';' | '"' | '\'')
                            })
                            .eq_ignore_ascii_case("url")
                        && parts.get(index + 1).is_some_and(|next| {
                            matches!(next.to_ascii_lowercase().as_str(), "is" | "was")
                        });
                    redact_next = if has_inline_value {
                        0
                    } else if url_precedes_copula {
                        2
                    } else {
                        1
                    };
                    "<redacted-sensitive>".to_string()
                }
            } else if looks_like_email(part) {
                "<redacted-email>".to_string()
            } else if looks_like_mac(part) {
                "<redacted-mac>".to_string()
            } else if looks_like_stable_interface_id(part) {
                "<redacted-interface-id>".to_string()
            } else if contains_non_loopback_ip(part) {
                "<redacted-ip>".to_string()
            } else if looks_like_hostname(part) {
                "<redacted-host>".to_string()
            } else if part.starts_with('/') || part.contains("=/") {
                "<redacted-path>".to_string()
            } else if looks_like_opaque_token(part) {
                "<redacted-token>".to_string()
            } else {
                part.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn contains_sensitive_assignment(value: &str) -> bool {
    [
        "password=",
        "password:",
        "passwd=",
        "passwd:",
        "token=",
        "token:",
        "secret=",
        "secret:",
        "authorization=",
        "authorization:",
        "api_key=",
        "api-key=",
        "private_key=",
        "private-key=",
    ]
    .iter()
    .any(|needle| value.contains(needle))
}

fn sensitive_key(value: &str) -> Option<bool> {
    const KEYS: &[&str] = &[
        "url",
        "query",
        "path",
        "candidate",
        "selected",
        "node",
        "outbound",
        "host",
        "profile",
        "secret",
        "token",
        "email",
        "ip",
        "password",
        "passwd",
        "authorization",
        "android_id",
        "device_id",
        "device-id",
        "serial",
        "imei",
        "api_key",
        "api-key",
    ];
    let clean = value.trim_matches(|ch: char| matches!(ch, '(' | ')' | ',' | ';' | '"' | '\''));
    let separator = clean.find(['=', ':']);
    let key = separator
        .map_or(clean, |index| &clean[..index])
        .to_ascii_lowercase();
    if KEYS
        .iter()
        .any(|sensitive| sensitive_key_matches(&key, sensitive))
        || key.contains("节点")
    {
        Some(separator.is_some())
    } else {
        None
    }
}

fn sensitive_key_matches(key: &str, sensitive: &str) -> bool {
    key == sensitive
        || key
            .strip_suffix(sensitive)
            .is_some_and(|prefix| prefix.ends_with('_') || prefix.ends_with('-'))
}

fn looks_like_opaque_token(value: &str) -> bool {
    let clean = clean_network_token(value);
    let candidate = clean.split_once('=').map_or(clean, |(_, value)| value);
    candidate.len() >= 20
        && candidate.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(
                    byte,
                    b'-' | b'_'
                        | b'.'
                        | b'!'
                        | b'@'
                        | b'#'
                        | b'$'
                        | b'%'
                        | b'^'
                        | b'&'
                        | b'*'
                        | b'+'
                        | b'='
                        | b'?'
                )
        })
        && candidate.bytes().any(|byte| byte.is_ascii_alphabetic())
        && candidate.bytes().any(|byte| byte.is_ascii_digit())
}

fn contains_non_loopback_ip(value: &str) -> bool {
    if is_non_loopback_ip(value) {
        return true;
    }
    value
        .split(|ch: char| !(ch.is_ascii_hexdigit() || matches!(ch, '.' | ':' | '/' | '[' | ']')))
        .filter(|part| !part.is_empty())
        .any(is_non_loopback_ip)
}

fn clean_network_token(value: &str) -> &str {
    value.trim_matches(|ch: char| matches!(ch, '(' | ')' | ',' | ';' | '"' | '\''))
}

fn is_non_loopback_ip(value: &str) -> bool {
    let clean = clean_network_token(value);
    let without_prefix = clean.split('/').next().unwrap_or(clean);
    let host = if without_prefix.starts_with('[') {
        without_prefix
            .strip_prefix('[')
            .and_then(|item| item.split(']').next())
            .unwrap_or(without_prefix)
    } else if without_prefix.matches(':').count() == 1 && without_prefix.contains('.') {
        without_prefix.split(':').next().unwrap_or(without_prefix)
    } else {
        without_prefix
    };
    host.parse::<IpAddr>()
        .map(|ip| !ip.is_loopback())
        .unwrap_or(false)
}

fn looks_like_mac(value: &str) -> bool {
    let clean = clean_network_token(value);
    let parts = clean.split(':').collect::<Vec<_>>();
    parts.len() == 6
        && parts
            .iter()
            .all(|part| part.len() == 2 && part.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

fn looks_like_stable_interface_id(value: &str) -> bool {
    let clean = clean_network_token(value)
        .trim_matches(|ch: char| matches!(ch, '[' | ']' | ':'))
        .split('@')
        .next()
        .unwrap_or_default();
    let suffix_len = clean
        .bytes()
        .rev()
        .take_while(u8::is_ascii_hexdigit)
        .count();
    if suffix_len < 12 || suffix_len == clean.len() {
        return false;
    }
    let prefix = &clean[..clean.len() - suffix_len];
    prefix.bytes().any(|byte| byte.is_ascii_alphabetic())
        && prefix
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn looks_like_email(value: &str) -> bool {
    let clean = clean_network_token(value);
    let Some((local, host)) = clean.split_once('@') else {
        return false;
    };
    !local.is_empty() && host.contains('.')
}

fn looks_like_hostname(value: &str) -> bool {
    let clean = clean_network_token(value)
        .trim_end_matches('.')
        .trim_end_matches(':');
    if clean.eq_ignore_ascii_case("localhost") || clean.parse::<IpAddr>().is_ok() {
        return false;
    }
    clean.contains('.')
        && !clean.contains('/')
        && clean
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
}

#[cfg(test)]
mod tests {
    use super::{
        configured_tun_is_canonical, network_policy_check, proxy_chain_evidence_from_values,
        read_only_command_with_timeout, redact, supervisor_cmdline_matches, support_bundle,
        traffic_loop_guard_check,
    };
    use crate::App;
    use std::fs;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    #[test]
    fn tun_health_accepts_only_the_canonical_magicnet_interface() {
        assert!(!configured_tun_is_canonical(&[]));
        assert!(configured_tun_is_canonical(&[String::from("magicnet0")]));
        assert!(!configured_tun_is_canonical(&[String::from("utun")]));
        assert!(!configured_tun_is_canonical(&[
            String::from("magicnet0"),
            String::from("Meta"),
        ]));
    }

    #[test]
    fn supervisor_status_requires_exact_managed_argv() {
        let module = std::path::PathBuf::from("/data/adb/modules/MagicNet");
        assert!(supervisor_cmdline_matches(
            &module,
            "magicnet-config",
            "/system/bin/sh /data/adb/modules/MagicNet/.state/fswatch/magicnet-config.loop.sh"
        ));
        assert!(supervisor_cmdline_matches(
            &module,
            "magicnet-wifi-policy",
            "/system/bin/sh /data/adb/modules/MagicNet/cli wifi watch"
        ));
        assert!(!supervisor_cmdline_matches(
            &module,
            "magicnet-config",
            "sleep 600 /data/adb/modules/MagicNet/.state/fswatch/magicnet-config.loop.sh"
        ));
        assert!(!supervisor_cmdline_matches(
            &module,
            "magicnet-wifi-policy",
            "/system/bin/sh /data/adb/modules/Other/cli wifi watch"
        ));
    }

    #[test]
    fn traffic_loop_guard_requires_root_and_loopback_exclusions() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("magicnet-loop-guard-{stamp}"));
        fs::create_dir_all(root.join(".config/sing-box")).unwrap();
        fs::write(
            root.join(".config/sing-box/config.json"),
            r#"{
              "inbounds": [{
                "type": "tun",
                "exclude_uid": [0],
                "route_exclude_address": ["127.0.0.0/8", "::1/128"]
              }],
              "outbounds": [{"type": "vless", "tag": "node", "server": "example.com"}]
            }"#,
        )
        .unwrap();
        let app = App::for_test(root.clone());
        assert!(traffic_loop_guard_check(&app).0);

        fs::write(
            root.join(".config/sing-box/config.json"),
            r#"{"inbounds":[{"type":"tun"}],"outbounds":[]}"#,
        )
        .unwrap();
        assert!(!traffic_loop_guard_check(&app).0);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn network_policy_accepts_dual_stack_and_rejects_stale_ipv6_guard() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("magicnet-network-policy-{stamp}"));
        fs::create_dir_all(root.join(".config/sing-box")).unwrap();
        let config_path = root.join(".config/sing-box/config.json");
        fs::write(
            &config_path,
            r#"{
              "dns": {"strategy": "prefer_ipv4"},
              "inbounds": [{
                "type": "tun",
                "stack": "mixed",
                "mtu": 1400,
                "udp_timeout": "5m",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
              }],
              "route": {"rules": []}
            }"#,
        )
        .unwrap();
        let app = App::for_test(root.clone());
        assert!(network_policy_check(&app).0);

        fs::write(
            &config_path,
            r#"{
              "dns": {"strategy": "prefer_ipv4"},
              "inbounds": [{
                "type": "tun",
                "stack": "mixed",
                "mtu": 1400,
                "udp_timeout": "5m",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
              }],
              "route": {"rules": [
                {"ip_version": 6, "action": "reject", "method": "default", "no_drop": true}
              ]}
            }"#,
        )
        .unwrap();
        assert!(!network_policy_check(&app).0);

        fs::write(
            &config_path,
            r#"{
              "dns": {"strategy": "prefer_ipv6"},
              "inbounds": [{
                "type": "tun",
                "stack": "mixed",
                "mtu": 1280,
                "udp_timeout": "10m",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
              }],
              "route": {"rules": [{"ip_version": 6, "outbound": "block"}]}
            }"#,
        )
        .unwrap();
        assert!(!network_policy_check(&app).0);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn redact_removes_subscription_and_node_identifiers() {
        let input = "url=https://sub.example.com/path?token=abc query=customer-id candidate=private-profile selected=Tokyo-Premium path=config/subscription.url outbound=private-out host=edge.example.com profile=paid secret=secret-value token=customer-token-1234567890 email=user@example.com ip=203.0.113.9 device_id=DEVICE-CANARY serial=SERIAL-CANARY https://bare.example.net/a?x=y BareToken0123456789Secret ReviewerBarePassword!2026 bare@example.net 198.51.100.7 节点-东京";
        let output = redact(input);

        for sensitive in [
            "sub.example.com",
            "/path",
            "abc",
            "secret-value",
            "user@example.com",
            "203.0.113.9",
            "Tokyo-Premium",
            "customer-id",
            "private-profile",
            "config/subscription.url",
            "private-out",
            "edge.example.com",
            "paid",
            "节点-东京",
            "bare.example.net",
            "BareToken0123456789Secret",
            "bare@example.net",
            "198.51.100.7",
            "DEVICE-CANARY",
            "SERIAL-CANARY",
            "ReviewerBarePassword!2026",
        ] {
            assert!(!output.contains(sensitive), "leaked {sensitive}: {output}");
        }
    }

    #[test]
    fn redact_removes_stable_interface_ids_but_keeps_interface_state() {
        let input = "2: enx001122aabbcc: <BROADCAST,UP> state UP type ether 3: br-deadbeefcafe1234: state DOWN type bridge 4: veth0123456789abcdef@if5: state UP type ether";
        let output = redact(input);

        for sensitive in [
            "enx001122aabbcc",
            "br-deadbeefcafe1234",
            "veth0123456789abcdef",
        ] {
            assert!(!output.contains(sensitive), "leaked {sensitive}: {output}");
        }
        assert!(output.contains("state UP type ether"));
        assert!(output.contains("state DOWN type bridge"));
    }

    #[test]
    fn redact_keeps_safe_status_assignments_and_filters_unknown_entropy() {
        let safe = "last_skipped_count=3 cache_provenance_count=2 cache_source=url_sha256_identity";
        assert_eq!(redact(safe), safe);

        let unknown = "mystery=UnknownHighEntropyToken1234567890";
        assert!(!redact(unknown).contains("UnknownHighEntropyToken1234567890"));
    }

    #[test]
    fn redact_keeps_prose_url_label_but_filters_following_secret_assignment() {
        let input = "reason=No subscription URL is configured; token=BUNDLE-STARTUP-CANARY";
        let output = redact(input);

        assert!(output.contains("reason=No subscription URL is configured"));
        assert!(!output.contains("BUNDLE-STARTUP-CANARY"));
    }

    #[test]
    fn redact_filters_values_after_url_copulas() {
        for input in [
            "reason=Configured URL is short-secret",
            "reason=Configured URL was short-secret",
        ] {
            let output = redact(input);
            assert!(!output.contains("short-secret"), "leaked value: {output}");
        }
    }

    #[test]
    fn read_only_command_reports_explicit_timeout() {
        let started = Instant::now();
        let output = read_only_command_with_timeout(
            "sh",
            &["-c", "sleep 5 & wait"],
            Duration::from_millis(50),
        );

        assert_eq!(output, "sh=timeout after 50ms");
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn read_only_command_closes_inherited_pipes_after_direct_child_exit() {
        let started = Instant::now();
        let output = read_only_command_with_timeout(
            "sh",
            &["-c", "sleep 5 & printf ready"],
            Duration::from_millis(50),
        );

        assert_eq!(output, "ready");
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn proxy_chain_evidence_keeps_routing_context_without_node_names_or_targets() {
        let proxies = serde_json::json!({
            "proxies": {
                "proxy-rule": {"type": "Selector", "now": "proxy"},
                "proxy": {"type": "Selector", "now": "PRIVATE-NODE-CANARY"},
                "PRIVATE-NODE-CANARY": {"type": "VLESS"},
                "direct": {"type": "Direct"},
                "block": {"type": "Block"}
            }
        });
        let connections = serde_json::json!({
            "connections": [
                {
                    "metadata": {
                        "host": "PRIVATE-TARGET-CANARY.example",
                        "destinationIP": "203.0.113.9"
                    },
                    "chains": ["PRIVATE-NODE-CANARY", "proxy", "proxy-rule"]
                },
                {
                    "metadata": {"host": "SECOND-PRIVATE-TARGET.example"},
                    "chains": ["PRIVATE-NODE-CANARY", "proxy", "proxy-rule"]
                },
                {"chains": ["direct"]}
            ]
        });

        let output = proxy_chain_evidence_from_values(Some(&proxies), Some(&connections));

        assert!(output.contains("selector.proxy-rule=proxy-rule -> proxy -> <node:vless>"));
        assert!(output.contains("active_chain.1=count:2 chain:<node:vless> -> proxy -> proxy-rule"));
        assert!(output.contains("active_connection_count=3"));
        let redacted = redact(&output);
        assert!(redacted.contains("selector.proxy-rule=proxy-rule -> proxy -> <node:vless>"));
        assert!(
            redacted.contains("active_chain.1=count:2 chain:<node:vless> -> proxy -> proxy-rule")
        );
        for sensitive in [
            "PRIVATE-NODE-CANARY",
            "PRIVATE-TARGET-CANARY",
            "SECOND-PRIVATE-TARGET",
            "203.0.113.9",
        ] {
            assert!(!output.contains(sensitive), "leaked {sensitive}: {output}");
        }
    }

    #[test]
    fn support_bundle_has_unique_redacted_read_only_evidence_sections() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("magicnet-support-{nonce}"));
        let app = App::for_test(root.clone());
        fs::create_dir_all(root.join(".config/sing-box")).unwrap();
        fs::create_dir_all(root.join(".state/sing-box")).unwrap();
        fs::create_dir_all(root.join(".log")).unwrap();
        fs::write(
            root.join(".config/sing-box/subscription.url"),
            "https://private.example.invalid/sub?token=BUNDLE-URL-CANARY\n",
        )
        .unwrap();
        fs::write(
            root.join(".state/sing-box/subscription-status"),
            "phase=activate\nresult=failed\nattempt_epoch=123\nsuccess_epoch=100\nconfigured_count=1\nsource_count=1\nimported_count=2\nskipped_count=0\ngeneration_id=123-456\nreason=token=BUNDLE-TOKEN-CANARY\nsource_mode=url\nnative_parser=share-links\nnative_node_count=0\nconverter_enabled=1\nconverter_available=1\nconverter_attempted=1\nconverter_format=singbox\nconverter_result=failed\n",
        )
        .unwrap();
        fs::write(
            root.join(".state/startup-error"),
            "No subscription URL is configured; token=BUNDLE-STARTUP-CANARY\n",
        )
        .unwrap();

        let bundle = support_bundle(&app);
        for heading in [
            "[subscription lifecycle]",
            "[service status]",
            "[startup state]",
            "[health]",
            "[core process and listeners]",
            "[tun routes and ip rules]",
            "[proxy selector and connection chains]",
            "[dns api and mcp]",
            "[subscription refresh log counts]",
        ] {
            assert_eq!(
                bundle.matches(heading).count(),
                1,
                "duplicate or missing {heading}"
            );
        }
        assert!(bundle.contains("last_phase=activate"));
        assert!(bundle.contains("last_result=failed"));
        assert!(bundle.contains("source_mode=url"));
        assert!(bundle.contains("update_running=0"));
        assert!(bundle.contains("last_native_node_count=0"));
        assert!(bundle.contains("last_converter_format=singbox"));
        assert!(bundle.contains("last_converter_result=failed"));
        assert!(bundle.contains("blocked=true"));
        assert!(bundle.contains("reason=No subscription URL is configured"));
        for sensitive in [
            "private.example.invalid",
            "BUNDLE-URL-CANARY",
            "BUNDLE-TOKEN-CANARY",
            "BUNDLE-STARTUP-CANARY",
            root.to_string_lossy().as_ref(),
        ] {
            assert!(
                !bundle.contains(sensitive),
                "support bundle leaked {sensitive}"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }
}
