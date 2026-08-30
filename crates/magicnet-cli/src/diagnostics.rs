use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::net::IpAddr;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::diagnostics_dns::dns_leak_check;
use crate::diagnostics_routing::routing_policy_check;
use crate::{
    clean_module_lines, cmdline_has_command, cmdline_has_script, command_text_timeout, mcp,
    pid_summary, read_proc_argv, read_proc_text_bounded, singbox_pid_summary, App,
    MAX_PROC_STAT_BYTES,
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
    let mode_label = mode
        .as_ref()
        .map(|selection| selection.mode.as_str())
        .unwrap_or("invalid");
    let (dataplane_ok, dataplane_detail) = dataplane_check(app, &mode);
    let (network_ok, network_detail) = network_policy_check(app);
    let ecapture = app.moddir.join("bin/ecapture");
    let (dns_config_ok, dns_config_detail) = dns_leak_check(app, &singbox, mode_label);
    let (dns_capture_ok, dns_capture_detail) = dns_capture_runtime_check(app, &mode);
    let dns_ok = dns_config_ok && dns_capture_ok;
    let dns_detail = format!("{dns_config_detail}, capture={dns_capture_detail}");
    let (routing_ok, routing_detail) = routing_policy_check(app);
    let (tailscale_ok, tailscale_detail) = tailscale_check(app, &mode);
    let (loop_guard_ok, loop_guard_detail) = traffic_loop_guard_check(app);
    let (api_ok, api_detail) = api_probe(&app.api);
    let (_, mcp_bind, mcp_port, mcp_pid) = mcp::status(app);
    vec![
        ("Core", running(&singbox), format!("sing-box={singbox}")),
        ("Dataplane", dataplane_ok, dataplane_detail),
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

fn tailscale_check(app: &App, mode: &Result<TransparentModeSelection, String>) -> (bool, String) {
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
    let managed_ingress = mode.as_ref().is_ok_and(|selection| {
        managed_inbound(&config).is_ok_and(|inbound| match selection.mode {
            TransparentMode::Tun => {
                inbound.get("type").and_then(Value::as_str) == Some("tun")
                    && inbound
                        .get("route_exclude_address")
                        .and_then(Value::as_array)
                        .is_some_and(|excluded| {
                            TAILNETS.iter().all(|cidr| {
                                !excluded.iter().any(|value| value.as_str() == Some(cidr))
                            })
                        })
            }
            TransparentMode::Ebpf => inbound.get("type").and_then(Value::as_str) == Some("ebpf"),
        })
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
        state_created && managed_ingress && route_linked,
        format!(
            "configured=true tag={tag} state_created={} managed_ingress={} route_linked={}",
            state_created as u8, managed_ingress as u8, route_linked as u8
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
    let mode_label = mode
        .as_ref()
        .map(|selection| selection.mode.as_str())
        .unwrap_or("invalid");
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
            "module_enabled={}\ncore={}\nfswatch={}\ntransparent_mode={mode_label}",
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
    let (dns_ok, dns_detail) = dns_leak_check(app, &singbox, mode_label);
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

#[derive(Debug)]
struct ReadOnlyCommandResult {
    success: bool,
    text: String,
}

fn read_only_command_with_timeout(program: &str, args: &[&str], timeout: Duration) -> String {
    read_only_command_result_with_timeout(program, args, timeout).text
}

fn read_only_command_result_with_timeout(
    program: &str,
    args: &[&str],
    timeout: Duration,
) -> ReadOnlyCommandResult {
    let mut child = match Command::new(program)
        .args(args)
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(err) => {
            return ReadOnlyCommandResult {
                success: false,
                text: format!("{program}=unavailable reason={err}"),
            };
        }
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
    let command_status: Result<ExitStatus, String> = loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if stdout_reader
                    .as_ref()
                    .is_some_and(|reader| !reader.is_finished())
                    || stderr_reader
                        .as_ref()
                        .is_some_and(|reader| !reader.is_finished())
                {
                    terminate_read_only_process_group(&mut child);
                }
                break Ok(status);
            }
            Ok(None) if started.elapsed() >= timeout => {
                terminate_read_only_process_group(&mut child);
                break Err(format!("{program}=timeout after {}ms", timeout.as_millis()));
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(err) => {
                terminate_read_only_process_group(&mut child);
                break Err(format!("{program}=unavailable reason={err}"));
            }
        }
    };

    let stdout = stdout_reader
        .and_then(|reader| reader.join().ok())
        .unwrap_or_default();
    let stderr = stderr_reader
        .and_then(|reader| reader.join().ok())
        .unwrap_or_default();
    let status = match command_status {
        Ok(status) => status,
        Err(text) => {
            return ReadOnlyCommandResult {
                success: false,
                text,
            };
        }
    };

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
    if text.is_empty() && !status.success() {
        text = format!("{program}=exit status={status}");
    }
    ReadOnlyCommandResult {
        success: status.success(),
        text,
    }
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
    let stat_path = PathBuf::from(format!("/proc/{pid}/stat"));
    let live_start = read_proc_text_bounded(&stat_path, MAX_PROC_STAT_BYTES)
        .ok()
        .and_then(|stat| crate::proc_start_time(&stat));
    if live_start.as_deref() != Some(expected_start) {
        return "stale";
    }
    if let Some(script) = exact_script {
        let cmdline_path = PathBuf::from(format!("/proc/{pid}/cmdline"));
        let Ok(argv) = read_proc_argv(&cmdline_path) else {
            return "stale";
        };
        if argv.get(1).map(Path::new) != Some(script) {
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TransparentMode {
    Tun,
    Ebpf,
}

impl TransparentMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Tun => "tun",
            Self::Ebpf => "ebpf",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TransparentModeSource {
    Default,
    File,
}

impl TransparentModeSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::File => "file",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TransparentModeSelection {
    mode: TransparentMode,
    source: TransparentModeSource,
}

fn transparent_mode(app: &App) -> Result<TransparentModeSelection, String> {
    let path = app.moddir.join(".config/magicnet/transparent-mode.conf");
    match fs::read_to_string(&path) {
        Ok(text) => parse_transparent_mode(&text),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(TransparentModeSelection {
            mode: TransparentMode::Tun,
            source: TransparentModeSource::Default,
        }),
        Err(err) => Err(format!("mode config unreadable: {err}")),
    }
}

fn parse_transparent_mode(text: &str) -> Result<TransparentModeSelection, String> {
    const KEY: &str = "MAGICNET_TRANSPARENT_MODE";
    let mut parsed = None;
    for (index, raw_line) in text.lines().enumerate() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            return Err(format!("invalid mode config line {}", index + 1));
        };
        if key.trim() != KEY {
            return Err(format!("unknown mode assignment at line {}", index + 1));
        }
        if parsed.is_some() {
            return Err(format!("duplicate mode assignment at line {}", index + 1));
        }
        let mode = match value.trim() {
            "tun" => TransparentMode::Tun,
            "ebpf" => TransparentMode::Ebpf,
            value => return Err(format!("unknown transparent mode {value:?}")),
        };
        parsed = Some(mode);
    }
    parsed
        .map(|mode| TransparentModeSelection {
            mode,
            source: TransparentModeSource::File,
        })
        .ok_or_else(|| "mode assignment missing".to_string())
}

fn dns_capture_runtime_check(
    app: &App,
    mode: &Result<TransparentModeSelection, String>,
) -> (bool, String) {
    let selection = match mode {
        Ok(selection) => *selection,
        Err(_) => return (false, "unknown-mode".to_string()),
    };
    if selection.mode == TransparentMode::Ebpf {
        let effective = read_singbox_config(app)
            .and_then(|config| managed_inbound(&config).cloned())
            .and_then(|inbound| effective_ebpf_config(&inbound));
        return match effective {
            Ok(effective)
                if !matches!(effective.mode, EbpfMode::Local | EbpfMode::Hybrid)
                    || effective.local_dns_mode == "hijack" =>
            {
                (true, "ebpf-inbound".to_string())
            }
            Ok(_) => (false, "ebpf-local-dns-not-hijacked".to_string()),
            Err(_) => (false, "ebpf-inbound-invalid".to_string()),
        };
    }

    if dns_capture_profile_is_direct_udp(app) {
        return (true, "profile-direct-udp".to_string());
    }

    let ipv4 = dns_capture_family_rules("iptables");
    let (ipv4_ok, ipv4_detail) = match ipv4 {
        Some(rules) => dns_capture_rule_summary(rules.0, rules.1, rules.2, rules.3),
        None => (false, "iptables-unavailable"),
    };
    let ipv6 = dns_capture_family_rules("ip6tables");
    let (ipv6_ok, ipv6_detail) = match ipv6 {
        Some(rules) => dns_capture_rule_summary(rules.0, rules.1, rules.2, rules.3),
        None => (true, "unavailable"),
    };
    (
        ipv4_ok && ipv6_ok,
        format!("ipv4:{ipv4_detail},ipv6:{ipv6_detail}"),
    )
}

fn dns_capture_profile_is_direct_udp(app: &App) -> bool {
    fs::read_to_string(app.moddir.join(".config/magicnet/dns.conf"))
        .ok()
        .and_then(|text| {
            text.lines().find_map(|raw| {
                let line = raw.trim();
                let (key, value) = line.split_once('=')?;
                (key.trim() == "MAGICNET_DNS_PROFILE").then(|| value.trim().to_string())
            })
        })
        .is_some_and(|profile| matches!(profile.as_str(), "cloudflare-udp" | "udp" | "1.1.1.1"))
}

fn dns_capture_family_rules(program: &str) -> Option<(bool, bool, bool, bool)> {
    let program = if Path::new(&format!("/system/bin/{program}")).is_file() {
        format!("/system/bin/{program}")
    } else {
        program.to_string()
    };
    let rule_exists = |args: &[&str]| {
        read_only_command_result_with_timeout(&program, args, Duration::from_secs(2)).success
    };
    if !rule_exists(&["-t", "nat", "-L"]) {
        return None;
    }
    let uid0_bypass = rule_exists(&[
        "-t",
        "nat",
        "-C",
        "magicnet-dns-output",
        "-m",
        "owner",
        "--uid-owner",
        "0",
        "-j",
        "RETURN",
    ]);
    let output_jump = rule_exists(&["-t", "nat", "-C", "OUTPUT", "-j", "magicnet-dns-output"]);
    let udp_redirect = rule_exists(&[
        "-t",
        "nat",
        "-C",
        "magicnet-dns-output",
        "-p",
        "udp",
        "--dport",
        "53",
        "-j",
        "REDIRECT",
        "--to-ports",
        "1053",
    ]);
    let tcp_redirect = rule_exists(&[
        "-t",
        "nat",
        "-C",
        "magicnet-dns-output",
        "-p",
        "tcp",
        "--dport",
        "53",
        "-j",
        "REDIRECT",
        "--to-ports",
        "1053",
    ]);
    Some((uid0_bypass, output_jump, udp_redirect, tcp_redirect))
}

fn dns_capture_rule_summary(
    uid0_bypass: bool,
    output_jump: bool,
    udp_redirect: bool,
    tcp_redirect: bool,
) -> (bool, &'static str) {
    if uid0_bypass {
        return (false, "uid0-bypass-leak");
    }
    if !output_jump {
        return (false, "output-jump-missing");
    }
    match (udp_redirect, tcp_redirect) {
        (true, true) => (true, "redirected"),
        (false, true) => (false, "udp-redirect-missing"),
        (true, false) => (false, "tcp-redirect-missing"),
        (false, false) => (false, "redirects-missing"),
    }
}

fn iface_detail(name: &str) -> String {
    command_text_timeout("ip", &["addr", "show", name], crate::SHORT_TIMEOUT)
}

fn dataplane_check(app: &App, mode: &Result<TransparentModeSelection, String>) -> (bool, String) {
    let selection = match mode {
        Ok(selection) => *selection,
        Err(reason) => {
            return (
                false,
                format!("configured=invalid effective=none probe=skipped reason={reason}"),
            );
        }
    };
    match selection.mode {
        TransparentMode::Tun => tun_dataplane_check(app, selection.source),
        TransparentMode::Ebpf => ebpf_dataplane_check(app, selection.source),
    }
}

fn tun_dataplane_check(app: &App, source: TransparentModeSource) -> (bool, String) {
    let expected = "magicnet0";
    let config = match read_singbox_config(app) {
        Ok(config) => config,
        Err(reason) => {
            return (
                false,
                format!(
                    "configured=mode:tun source:{} inbound:invalid effective=interface:{expected} probe=skipped reason={reason}",
                    source.as_str()
                ),
            );
        }
    };
    let inbound = match managed_inbound(&config) {
        Ok(inbound) => inbound,
        Err(reason) => {
            return (
                false,
                format!(
                    "configured=mode:tun source:{} inbound:invalid effective=interface:{expected} probe=skipped reason={reason}",
                    source.as_str()
                ),
            );
        }
    };
    let configured = inbound
        .get("interface_name")
        .and_then(Value::as_str)
        .unwrap_or("none");
    let configured_ok = inbound.get("type").and_then(Value::as_str) == Some("tun")
        && configured_tun_is_canonical(&[configured.to_string()]);
    let present = PathBuf::from(format!("/sys/class/net/{expected}")).exists();
    if configured_ok && present {
        return (
            true,
            format!(
                "configured=mode:tun source:{} inbound:tun interface:{configured} effective=interface:{expected} probe=present detail={}",
                source.as_str(),
                iface_detail(expected)
            ),
        );
    }
    (
        false,
        format!(
            "configured=mode:tun source:{} inbound:{} interface:{configured} effective=interface:{expected} probe={}",
            source.as_str(),
            inbound
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("invalid"),
            if present { "present" } else { "missing" }
        ),
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EbpfMode {
    Local,
    Shared,
    Hybrid,
}

impl EbpfMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Shared => "shared",
            Self::Hybrid => "hybrid",
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
struct EbpfEffectiveConfig {
    mode: EbpfMode,
    mode_configured: bool,
    network: Vec<String>,
    network_configured: bool,
    udp_timeout: String,
    local_dns_mode: String,
    local_cgroup_path: String,
    local_ipv6: bool,
    shared_dns_mode: String,
    shared_interfaces: Vec<String>,
    shared_ipv6: bool,
}

fn ebpf_dataplane_check(app: &App, source: TransparentModeSource) -> (bool, String) {
    let config = match read_singbox_config(app) {
        Ok(config) => config,
        Err(reason) => {
            return (
                false,
                format!(
                    "configured=mode:ebpf source:{} inbound:invalid effective=none probe=skipped reason={reason}",
                    source.as_str()
                ),
            );
        }
    };
    let inbound = match managed_inbound(&config) {
        Ok(inbound) if inbound.get("type").and_then(Value::as_str) == Some("ebpf") => inbound,
        Ok(inbound) => {
            return (
                false,
                format!(
                    "configured=mode:ebpf source:{} inbound:{} effective=none probe=skipped reason=managed tun-in is not ebpf",
                    source.as_str(),
                    inbound
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or("invalid")
                ),
            );
        }
        Err(reason) => {
            return (
                false,
                format!(
                    "configured=mode:ebpf source:{} inbound:invalid effective=none probe=skipped reason={reason}",
                    source.as_str()
                ),
            );
        }
    };
    let effective = match effective_ebpf_config(inbound) {
        Ok(effective) => effective,
        Err(reason) => {
            return (
                false,
                format!(
                    "configured=mode:ebpf source:{} inbound:ebpf effective=invalid probe=skipped reason={reason}",
                    source.as_str()
                ),
            );
        }
    };
    let configured_mode = if effective.mode_configured {
        effective.mode.as_str()
    } else {
        "default"
    };
    let configured_network = if effective.network_configured {
        effective.network.join(",")
    } else {
        "default".to_string()
    };
    let effective_network = effective.network.join(",");
    let local_effective = matches!(effective.mode, EbpfMode::Local | EbpfMode::Hybrid);
    let shared_effective = matches!(effective.mode, EbpfMode::Shared | EbpfMode::Hybrid);
    let shared_state = if !shared_effective {
        "pending".to_string()
    } else if effective.shared_interfaces.is_empty() {
        "missing".to_string()
    } else {
        effective.shared_interfaces.join(",")
    };
    if local_effective && effective.local_dns_mode != "hijack" {
        return (
            false,
            format!(
                "configured=mode:ebpf source:{} inbound:ebpf effective=mode:{} local=enabled local.dns:{} probe=skipped reason=managed local DNS must use hijack",
                source.as_str(),
                effective.mode.as_str(),
                effective.local_dns_mode
            ),
        );
    }
    if shared_effective && effective.shared_interfaces.is_empty() {
        return (
            false,
            format!(
                "configured=mode:ebpf source:{} inbound:ebpf requested_mode:{configured_mode} requested_network:{configured_network} effective=mode:{} network:{effective_network} local={} shared=missing probe=skipped reason=shared.interface is required",
                source.as_str(),
                effective.mode.as_str(),
                if local_effective { "enabled" } else { "disabled" }
            ),
        );
    }

    let program = app.moddir.join("bin/sing-box");
    let program = program.to_string_lossy();
    let mut probes = Vec::new();
    let cgroup =
        (!effective.local_cgroup_path.is_empty()).then_some(effective.local_cgroup_path.as_str());
    match effective.mode {
        EbpfMode::Local => probes.push(ebpf_capability_probe(&program, "local", cgroup, None)),
        EbpfMode::Shared => {
            for interface in &effective.shared_interfaces {
                probes.push(ebpf_capability_probe(
                    &program,
                    "shared-network",
                    None,
                    Some(interface),
                ));
            }
        }
        EbpfMode::Hybrid => {
            for interface in &effective.shared_interfaces {
                probes.push(ebpf_capability_probe(
                    &program,
                    "all",
                    cgroup,
                    Some(interface),
                ));
            }
        }
    }
    let probe_ok = probes.iter().all(|probe| probe.success);
    let probe_detail = probes
        .iter()
        .map(|probe| {
            if probe.success {
                "ok".to_string()
            } else {
                format!("failed({})", probe.text)
            }
        })
        .collect::<Vec<_>>()
        .join(",");
    (
        probe_ok,
        format!(
            "configured=mode:ebpf source:{} inbound:ebpf requested_mode:{configured_mode} requested_network:{configured_network} effective=mode:{} network:{effective_network} local={} local.cgroup:{} local.dns:{} local.ipv6:{} shared={shared_state} shared.interface:{} shared.dns:{} shared.ipv6:{} probe=capability:{probe_detail}",
            source.as_str(),
            effective.mode.as_str(),
            if local_effective { "enabled" } else { "disabled" },
            if effective.local_cgroup_path.is_empty() {
                "/sys/fs/cgroup"
            } else {
                effective.local_cgroup_path.as_str()
            },
            effective.local_dns_mode,
            effective.local_ipv6 as u8,
            if effective.shared_interfaces.is_empty() {
                "none".to_string()
            } else {
                effective.shared_interfaces.join(",")
            },
            effective.shared_dns_mode,
            effective.shared_ipv6 as u8
        ),
    )
}

fn read_singbox_config(app: &App) -> Result<Value, String> {
    let path = app.moddir.join(".config/sing-box/config.json");
    let text = fs::read_to_string(&path).map_err(|err| format!("config unreadable: {err}"))?;
    serde_json::from_str(&text).map_err(|err| format!("config invalid: {err}"))
}

fn managed_inbound(config: &Value) -> Result<&Value, String> {
    let Some(inbounds) = config.get("inbounds").and_then(Value::as_array) else {
        return Err("inbounds missing or invalid".to_string());
    };
    let mut matches = inbounds
        .iter()
        .filter(|inbound| inbound.get("tag").and_then(Value::as_str) == Some("tun-in"));
    let Some(inbound) = matches.next() else {
        return Err("managed inbound tun-in missing".to_string());
    };
    if matches.next().is_some() {
        return Err("managed inbound tun-in duplicated".to_string());
    }
    Ok(inbound)
}

fn effective_ebpf_config(inbound: &Value) -> Result<EbpfEffectiveConfig, String> {
    let mode_value = inbound.get("mode");
    let mode = match mode_value {
        None => EbpfMode::Local,
        Some(Value::String(value)) if value == "local" => EbpfMode::Local,
        Some(Value::String(value)) if value == "shared" => EbpfMode::Shared,
        Some(Value::String(value)) if value == "hybrid" => EbpfMode::Hybrid,
        _ => return Err("ebpf mode must be local, shared, or hybrid".to_string()),
    };
    let network_value = inbound.get("network");
    let network = strict_ebpf_network(network_value)?;
    let udp_timeout = strict_optional_string(inbound.get("udp_timeout"), "udp_timeout")?
        .unwrap_or_else(|| "5m".to_string());
    let local = strict_optional_object(inbound.get("local"), "local")?;
    let shared = strict_optional_object(inbound.get("shared"), "shared")?;
    let local_dns_mode = strict_dns_mode(local.and_then(|value| value.get("dns_mode")))?;
    let local_cgroup_path = strict_optional_string(
        local.and_then(|value| value.get("cgroup_path")),
        "local.cgroup_path",
    )?
    .unwrap_or_default();
    if !local_cgroup_path.is_empty() && !Path::new(&local_cgroup_path).is_absolute() {
        return Err("local.cgroup_path must be absolute or empty".to_string());
    }
    let local_ipv6 = strict_optional_bool(local.and_then(|value| value.get("ipv6")), "local.ipv6")?
        .unwrap_or(true);
    let shared_dns_mode = strict_dns_mode(shared.and_then(|value| value.get("dns_mode")))?;
    let shared_interfaces =
        strict_shared_interfaces(shared.and_then(|value| value.get("interface")))?;
    let shared_ipv6 =
        strict_optional_bool(shared.and_then(|value| value.get("ipv6")), "shared.ipv6")?
            .unwrap_or(true);
    Ok(EbpfEffectiveConfig {
        mode,
        mode_configured: mode_value.is_some(),
        network,
        network_configured: network_value.is_some(),
        udp_timeout,
        local_dns_mode,
        local_cgroup_path,
        local_ipv6,
        shared_dns_mode,
        shared_interfaces,
        shared_ipv6,
    })
}

fn strict_optional_object<'a>(
    value: Option<&'a Value>,
    field: &str,
) -> Result<Option<&'a serde_json::Map<String, Value>>, String> {
    match value {
        None => Ok(None),
        Some(Value::Object(value)) => Ok(Some(value)),
        Some(_) => Err(format!("{field} must be an object")),
    }
}

fn strict_ebpf_network(value: Option<&Value>) -> Result<Vec<String>, String> {
    let values = match value {
        None => return Ok(vec!["tcp".to_string(), "udp".to_string()]),
        Some(Value::String(value)) => vec![value.as_str()],
        Some(Value::Array(values)) if !values.is_empty() => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .ok_or_else(|| "ebpf network entries must be strings".to_string())
            })
            .collect::<Result<Vec<_>, _>>()?,
        _ => return Err("ebpf network must be a non-empty string or array".to_string()),
    };
    let mut result = Vec::new();
    for value in values {
        if !matches!(value, "tcp" | "udp") {
            return Err(format!("unknown ebpf network {value:?}"));
        }
        if result.iter().any(|existing| existing == value) {
            return Err(format!("duplicate ebpf network {value:?}"));
        }
        result.push(value.to_string());
    }
    Ok(result)
}

fn strict_dns_mode(value: Option<&Value>) -> Result<String, String> {
    match value {
        None => Ok("respect_policy".to_string()),
        Some(Value::String(value))
            if matches!(value.as_str(), "hijack" | "respect_policy" | "off") =>
        {
            Ok(value.clone())
        }
        _ => Err("ebpf dns_mode must be hijack, respect_policy, or off".to_string()),
    }
}

fn strict_optional_string(value: Option<&Value>, field: &str) -> Result<Option<String>, String> {
    match value {
        None => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(format!("{field} must be a string")),
    }
}

fn strict_optional_bool(value: Option<&Value>, field: &str) -> Result<Option<bool>, String> {
    match value {
        None => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(format!("{field} must be a boolean")),
    }
}

fn strict_shared_interfaces(value: Option<&Value>) -> Result<Vec<String>, String> {
    let values = match value {
        None => return Ok(Vec::new()),
        Some(Value::String(value)) => vec![value.as_str()],
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .ok_or_else(|| "shared.interface entries must be strings".to_string())
            })
            .collect::<Result<Vec<_>, _>>()?,
        _ => return Err("shared.interface must be a string or array".to_string()),
    };
    let mut interfaces = Vec::new();
    for interface in values {
        if !valid_interface_name(interface) {
            return Err(format!("invalid shared.interface {interface:?}"));
        }
        if interfaces.iter().any(|existing| existing == interface) {
            return Err(format!("duplicate shared.interface {interface:?}"));
        }
        interfaces.push(interface.to_string());
    }
    Ok(interfaces)
}

fn valid_interface_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 15
        && !matches!(value, "." | "..")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

fn configured_tun_is_canonical(names: &[String]) -> bool {
    !names.is_empty() && names.iter().all(|name| name == "magicnet0")
}

fn ebpf_capability_probe(
    program: &str,
    mode: &str,
    cgroup: Option<&str>,
    interface: Option<&str>,
) -> ReadOnlyCommandResult {
    let args = ebpf_probe_args(mode, cgroup, interface);
    read_only_command_result_with_timeout(program, &args, Duration::from_secs(3))
}

fn ebpf_probe_args<'a>(
    mode: &'a str,
    cgroup: Option<&'a str>,
    interface: Option<&'a str>,
) -> Vec<&'a str> {
    let mut args = vec![
        "tools",
        "ebpf",
        "status",
        "--mode",
        mode,
        "--network",
        "tcp,udp",
    ];
    if let Some(cgroup) = cgroup {
        args.extend(["--cgroup", cgroup]);
    }
    if let Some(interface) = interface {
        args.extend(["--interface", interface]);
    }
    args.push("--json");
    args
}

fn traffic_loop_guard_check(app: &App) -> (bool, String) {
    let selection = match transparent_mode(app) {
        Ok(selection) => selection,
        Err(reason) => return (false, format!("mode=invalid reason={reason}")),
    };
    let config = match read_singbox_config(app) {
        Ok(config) => config,
        Err(reason) => return (false, reason),
    };
    let loopback_servers = loopback_proxy_servers(&config);
    match selection.mode {
        TransparentMode::Tun => {
            let tun = config
                .get("inbounds")
                .and_then(Value::as_array)
                .and_then(|items| {
                    items
                        .iter()
                        .find(|item| item.get("type").and_then(Value::as_str) == Some("tun"))
                });
            let Some(tun) = tun else {
                return (false, "mode=tun TUN inbound missing".to_string());
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
            let ok = root_excluded
                && excludes_ipv4_loopback
                && excludes_ipv6_loopback
                && loopback_servers.is_empty();
            (
                ok,
                format!(
                    "mode=tun exclude_uid_0={} ipv4_loopback_excluded={} ipv6_loopback_excluded={} loopback_proxy_servers={}",
                    root_excluded as u8,
                    excludes_ipv4_loopback as u8,
                    excludes_ipv6_loopback as u8,
                    display_list(&loopback_servers)
                ),
            )
        }
        TransparentMode::Ebpf => {
            let managed_ok = managed_inbound(&config)
                .is_ok_and(|inbound| inbound.get("type").and_then(Value::as_str) == Some("ebpf"));
            let ok = managed_ok && loopback_servers.is_empty();
            (
                ok,
                format!(
                    "mode=ebpf managed_inbound={} self_protection=socket_cookie loopback_proxy_servers={}",
                    if managed_ok { "ebpf" } else { "invalid" },
                    display_list(&loopback_servers)
                ),
            )
        }
    }
}

fn loopback_proxy_servers(config: &Value) -> Vec<String> {
    config
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
        .collect()
}

fn display_list(values: &[String]) -> String {
    if values.is_empty() {
        "none".to_string()
    } else {
        values.join(",")
    }
}

fn network_policy_check(app: &App) -> (bool, String) {
    let selection = match transparent_mode(app) {
        Ok(selection) => selection,
        Err(reason) => return (false, format!("mode=invalid reason={reason}")),
    };
    let config = match read_singbox_config(app) {
        Ok(config) => config,
        Err(reason) => return (false, reason),
    };
    let strategy = config
        .get("dns")
        .and_then(|dns| dns.get("strategy"))
        .and_then(Value::as_str)
        .unwrap_or("unset");
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
    match selection.mode {
        TransparentMode::Tun => {
            tun_network_policy(&config, strategy, strategy_ok, guard_ok, ipv6_guard)
        }
        TransparentMode::Ebpf => {
            ebpf_network_policy(&config, strategy, strategy_ok, guard_ok, ipv6_guard)
        }
    }
}

fn tun_network_policy(
    config: &Value,
    strategy: &str,
    strategy_ok: bool,
    guard_ok: bool,
    ipv6_guard: bool,
) -> (bool, String) {
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
    let address_ok = strategy == "ipv4_only" || ipv6_address;
    let ok = strategy_ok
        && stack == "mixed"
        && (1280..=1500).contains(&mtu)
        && valid_udp_timeout(udp_timeout)
        && guard_ok
        && address_ok;
    (
        ok,
        format!(
            "mode=tun strategy={strategy} stack={stack} mtu={mtu} udp_timeout={udp_timeout} ipv6_address={} ipv6_guard={}",
            ipv6_address as u8, ipv6_guard as u8
        ),
    )
}

fn ebpf_network_policy(
    config: &Value,
    strategy: &str,
    strategy_ok: bool,
    guard_ok: bool,
    ipv6_guard: bool,
) -> (bool, String) {
    let effective = managed_inbound(config).and_then(|inbound| {
        if inbound.get("type").and_then(Value::as_str) != Some("ebpf") {
            return Err("managed tun-in is not ebpf".to_string());
        }
        effective_ebpf_config(inbound)
    });
    let Ok(effective) = effective else {
        return (
            false,
            format!(
                "mode=ebpf strategy={strategy} managed_inbound=invalid ipv6_guard={} reason={}",
                ipv6_guard as u8,
                effective.unwrap_err()
            ),
        );
    };
    let active_ipv6 = match effective.mode {
        EbpfMode::Local => effective.local_ipv6,
        EbpfMode::Shared => effective.shared_ipv6,
        EbpfMode::Hybrid => effective.local_ipv6 && effective.shared_ipv6,
    };
    let ipv6_ok = if strategy == "ipv4_only" {
        !active_ipv6
    } else {
        active_ipv6
    };
    let ok = strategy_ok && guard_ok && valid_udp_timeout(&effective.udp_timeout) && ipv6_ok;
    (
        ok,
        format!(
            "mode=ebpf strategy={strategy} ebpf_mode={} network={} udp_timeout={} local_ipv6={} shared_ipv6={} ipv6_guard={}",
            effective.mode.as_str(),
            effective.network.join(","),
            effective.udp_timeout,
            effective.local_ipv6 as u8,
            effective.shared_ipv6 as u8,
            ipv6_guard as u8
        ),
    )
}

fn valid_udp_timeout(value: &str) -> bool {
    matches!(value, "1m" | "3m" | "5m" | "10m" | "15m" | "30m")
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
    let argv = read_proc_argv(&proc_dir.join("cmdline")).unwrap_or_default();
    supervisor_cmdline_matches(&app.moddir, name, &argv)
}

fn supervisor_cmdline_matches(moddir: &Path, name: &str, argv: &[String]) -> bool {
    let module = moddir.to_string_lossy();
    match name {
        "magicnet-config" => {
            cmdline_has_script(
                argv,
                &format!("{module}/.state/fswatch/magicnet-config.loop.sh"),
            ) || cmdline_has_command(argv, &format!("{module}/cli"), &["config", "apply"])
        }
        "magicnet-wifi-policy" => {
            cmdline_has_command(argv, &format!("{module}/cli"), &["wifi", "watch"])
                || cmdline_has_command(
                    argv,
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
mod mode_aware_tests {
    use super::{
        dataplane_check, dns_capture_rule_summary, ebpf_probe_args, effective_ebpf_config,
        network_policy_check, parse_transparent_mode, read_only_command_result_with_timeout,
        traffic_loop_guard_check, transparent_mode, TransparentMode, TransparentModeSource,
    };
    use crate::App;
    use serde_json::json;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn test_root(label: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!("magicnet-{label}-{stamp}"));
        fs::create_dir_all(root.join(".config/magicnet"))?;
        fs::create_dir_all(root.join(".config/sing-box"))?;
        Ok(root)
    }

    #[test]
    fn missing_mode_file_defaults_to_tun() -> Result<(), Box<dyn std::error::Error>> {
        let root = test_root("mode-default")?;
        let selection = transparent_mode(&App::for_test(root.clone()))?;

        assert_eq!(
            (selection.mode, selection.source),
            (TransparentMode::Tun, TransparentModeSource::Default)
        );
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn explicit_ebpf_mode_is_accepted() -> Result<(), Box<dyn std::error::Error>> {
        let selection = parse_transparent_mode("MAGICNET_TRANSPARENT_MODE=ebpf\n")?;

        assert_eq!(selection.mode, TransparentMode::Ebpf);
        Ok(())
    }

    #[test]
    fn unknown_mode_assignment_is_rejected() {
        let error = parse_transparent_mode("OTHER_MODE=tun\n").unwrap_err();

        assert!(error.contains("unknown mode assignment"));
    }

    #[test]
    fn duplicate_mode_assignment_is_rejected() {
        let error = parse_transparent_mode(
            "MAGICNET_TRANSPARENT_MODE=tun\nMAGICNET_TRANSPARENT_MODE=ebpf\n",
        )
        .unwrap_err();

        assert!(error.contains("duplicate mode assignment"));
    }

    #[test]
    fn unknown_mode_value_is_rejected() {
        let error = parse_transparent_mode("MAGICNET_TRANSPARENT_MODE=auto\n").unwrap_err();

        assert!(error.contains("unknown transparent mode"));
    }

    #[test]
    fn local_probe_uses_required_non_destructive_arguments() {
        assert_eq!(
            ebpf_probe_args("local", None, None),
            [
                "tools",
                "ebpf",
                "status",
                "--mode",
                "local",
                "--network",
                "tcp,udp",
                "--json"
            ]
        );
    }

    #[test]
    fn hybrid_probe_validates_each_interface_with_all_mode() {
        assert_eq!(
            ebpf_probe_args("all", None, Some("wlan0")),
            [
                "tools",
                "ebpf",
                "status",
                "--mode",
                "all",
                "--network",
                "tcp,udp",
                "--interface",
                "wlan0",
                "--json"
            ]
        );
    }

    #[test]
    fn shared_interface_accepts_listable_string() -> Result<(), String> {
        let effective = effective_ebpf_config(&json!({
            "type": "ebpf",
            "mode": "shared",
            "shared": {"interface": "wlan0"}
        }))?;

        assert_eq!(effective.shared_interfaces, ["wlan0"]);
        Ok(())
    }

    #[test]
    fn shared_interface_rejects_command_like_name() {
        let error = effective_ebpf_config(&json!({
            "type": "ebpf",
            "mode": "shared",
            "shared": {"interface": ["wlan0;id"]}
        }))
        .unwrap_err();

        assert!(error.contains("invalid shared.interface"));
    }

    #[test]
    fn nonzero_probe_exit_is_not_capability_success() {
        let result = read_only_command_result_with_timeout(
            "/bin/sh",
            &["-c", "exit 7"],
            Duration::from_secs(1),
        );

        assert!(!result.success);
    }

    #[test]
    fn ebpf_dataplane_does_not_require_magicnet0() -> Result<(), Box<dyn std::error::Error>> {
        let root = test_root("ebpf-dataplane")?;
        fs::create_dir_all(root.join("bin"))?;
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=ebpf\n",
        )?;
        fs::write(
            root.join(".config/sing-box/config.json"),
            r#"{"inbounds":[{"type":"ebpf","tag":"tun-in","mode":"local","local":{"dns_mode":"hijack"}}]}"#,
        )?;
        let binary = root.join("bin/sing-box");
        fs::write(&binary, "#!/bin/sh\nexit 0\n")?;
        let mut permissions = fs::metadata(&binary)?.permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&binary, permissions)?;
        let app = App::for_test(root.clone());
        let result = dataplane_check(&app, &transparent_mode(&app));

        assert!(result.0, "{}", result.1);
        assert!(result.1.contains("shared=pending"), "{}", result.1);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn ebpf_dataplane_rejects_non_hijacked_local_dns() -> Result<(), Box<dyn std::error::Error>> {
        let root = test_root("ebpf-dns-mode")?;
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=ebpf\n",
        )?;
        fs::write(
            root.join(".config/sing-box/config.json"),
            r#"{"inbounds":[{"type":"ebpf","tag":"tun-in","mode":"local","local":{"dns_mode":"respect_policy"}}]}"#,
        )?;
        let app = App::for_test(root.clone());
        let result = dataplane_check(&app, &transparent_mode(&app));

        assert!(!result.0, "{}", result.1);
        assert!(
            result.1.contains("local DNS must use hijack"),
            "{}",
            result.1
        );
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn ebpf_loop_guard_uses_managed_inbound_self_protection(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let root = test_root("ebpf-loop")?;
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=ebpf\n",
        )?;
        fs::write(
            root.join(".config/sing-box/config.json"),
            r#"{
              "inbounds":[{"type":"ebpf","tag":"tun-in","mode":"local"}],
              "outbounds":[{"type":"vless","tag":"node","server":"example.com"}]
            }"#,
        )?;
        let result = traffic_loop_guard_check(&App::for_test(root.clone()));

        assert!(result.0, "{}", result.1);
        assert!(result.1.contains("self_protection=socket_cookie"));
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn ebpf_network_policy_does_not_require_tun_fields() -> Result<(), Box<dyn std::error::Error>> {
        let root = test_root("ebpf-network")?;
        fs::write(
            root.join(".config/magicnet/transparent-mode.conf"),
            "MAGICNET_TRANSPARENT_MODE=ebpf\n",
        )?;
        fs::write(
            root.join(".config/sing-box/config.json"),
            r#"{
              "dns":{"strategy":"prefer_ipv4"},
              "inbounds":[{"type":"ebpf","tag":"tun-in","mode":"local"}],
              "route":{"rules":[]}
            }"#,
        )?;
        let result = network_policy_check(&App::for_test(root.clone()));

        assert!(result.0, "{}", result.1);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn dns_capture_runtime_rejects_uid0_bypass() {
        assert_eq!(
            dns_capture_rule_summary(true, true, true, true),
            (false, "uid0-bypass-leak")
        );
    }

    #[test]
    fn dns_capture_runtime_requires_udp_and_tcp_redirects() {
        assert_eq!(
            dns_capture_rule_summary(false, true, true, true),
            (true, "redirected")
        );
        assert_eq!(
            dns_capture_rule_summary(false, false, true, true),
            (false, "output-jump-missing")
        );
        assert_eq!(
            dns_capture_rule_summary(false, true, false, true),
            (false, "udp-redirect-missing")
        );
        assert_eq!(
            dns_capture_rule_summary(false, true, true, false),
            (false, "tcp-redirect-missing")
        );
        assert_eq!(
            dns_capture_rule_summary(false, true, false, false),
            (false, "redirects-missing")
        );
    }
}

#[cfg(test)]
#[path = "../tests/internal/diagnostics.rs"]
mod tests;
