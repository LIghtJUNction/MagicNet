use std::fs;
use std::path::PathBuf;
use std::process::Command;

use crate::{clean_lines, command_text_timeout, mcp, pid_summary, read_kv, App};

pub(crate) fn health(app: &App) -> Result<(), String> {
    let singbox = pid_summary("sing-box");
    let mihomo = pid_summary("mihomo");
    print_check(
        "Core",
        &running(&singbox, &mihomo),
        format!("sing-box={singbox}, mihomo={mihomo}"),
    );
    let (tun_ok, tun_detail) = tun_check(app);
    print_check("TUN", &tun_ok, tun_detail);
    let (tproxy_ok, tproxy_detail) = tproxy_check(app, &singbox, &mihomo);
    print_check("TProxy", &tproxy_ok, tproxy_detail);
    let (dns_ok, dns_detail) = dns_leak_check(app, &singbox, &mihomo);
    print_check("DNS Leak", &dns_ok, dns_detail);
    let (api_ok, api_detail) = api_probe(&app.api);
    print_check("Clash API", &api_ok, api_detail);
    print_check(
        "Subscription",
        &has_subscription(app),
        "subscription config present".to_string(),
    );
    let (_, mcp_bind, mcp_port, mcp_pid) = mcp::status(app);
    print_check(
        "MCP",
        &mcp_pid.ne("stopped"),
        format!("pid={mcp_pid}, url=http://{mcp_bind}:{mcp_port}/mcp"),
    );
    let watchdog_pid = supervisor_pid(app, "watchdog", "magicnet-kernel");
    print_check(
        "Watchdog",
        &watchdog_pid.ne("stopped"),
        watchdog_detail(app),
    );
    print_check(
        "WebUI",
        &app.moddir.join("webroot/index.html").exists(),
        app.moddir.join("webroot").display().to_string(),
    );
    Ok(())
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
    println!("MagicNet support bundle");
    println!("module={}", app.moddir.display());
    println!();
    println!("[service]");
    crate::service_status(app);
    println!();
    println!("[health]");
    health(app)?;
    println!();
    println!("[subscriptions]");
    for path in sensitive_paths(app) {
        println!(
            "{}={}",
            path.display(),
            if path.exists() {
                "<configured>"
            } else {
                "<missing>"
            }
        );
    }
    println!();
    println!("[routes]");
    sysroute_snapshot();
    println!();
    println!("[recent logs]");
    print_redacted_tail(app.log_dir.join("sing-box.log"));
    print_redacted_tail(app.log_dir.join("mihomo.log"));
    Ok(())
}

fn print_check(key: &str, ok: &bool, detail: String) {
    let status = if *ok { "ok" } else { "warn" };
    println!("[{status}] {key}: {}", redact(&detail));
}

fn running(a: &str, b: &str) -> bool {
    a != "stopped" || b != "stopped"
}

fn iface_detail(name: &str) -> String {
    command_text_timeout("ip", &["addr", "show", name], crate::SHORT_TIMEOUT)
}

fn tun_check(app: &App) -> (bool, String) {
    let mut names = configured_tun_names(app);
    for fallback in ["magicnet0", "utun", "Meta", "mihoyo"] {
        push_unique(&mut names, fallback.to_string());
    }
    let checked = names.join(",");
    for name in &names {
        if PathBuf::from(format!("/sys/class/net/{name}")).exists() {
            return (true, format!("{name}: {}", iface_detail(name)));
        }
    }
    (
        false,
        format!("No MagicNet TUN interface found. checked={checked}"),
    )
}

fn tproxy_check(app: &App, singbox: &str, mihomo: &str) -> (bool, String) {
    let mode = transparent_mode(app);
    let port = tproxy_port(app);
    let mark = tproxy_mark(app);
    let table = tproxy_table(app);

    if mode != "tproxy" {
        return (
            true,
            format!("mode={mode}, inactive, expected_port={port}, mark={mark}, table={table}"),
        );
    }

    let running_core = if singbox != "stopped" {
        "sing-box"
    } else if mihomo != "stopped" {
        "mihomo"
    } else {
        "stopped"
    };
    let kernel = tproxy_kernel_supported();
    let config = tproxy_configured_for_core(app, running_core, port);
    let listener = tproxy_listener(port);
    let iptables_chain = tproxy_iptables_chain(port);
    let socket_guard = tproxy_socket_guard();
    let prerouting = tproxy_prerouting_jump();
    let output = tproxy_output_jump();
    let loop_guard = tproxy_output_loop_guard();
    let rule = tproxy_policy_rule(&mark, &table);
    let route = tproxy_local_route(&table);
    let ipv6 = tproxy_ipv6_chain(port);
    let ok = kernel
        && config
        && listener
        && iptables_chain
        && socket_guard
        && prerouting
        && output
        && loop_guard
        && rule
        && route;

    (
        ok,
        format!(
            "mode=tproxy, core={running_core}, port={port}, mark={mark}, table={table}, kernel={}, config={}, listener={}, chain={}, socket_guard={}, prerouting={}, output={}, loop_guard={}, rule={}, route={}, ipv6_chain={}",
            yes_no(kernel),
            yes_no(config),
            yes_no(listener),
            yes_no(iptables_chain),
            yes_no(socket_guard),
            yes_no(prerouting),
            yes_no(output),
            yes_no(loop_guard),
            yes_no(rule),
            yes_no(route),
            yes_no(ipv6),
        ),
    )
}

fn dns_leak_check(app: &App, singbox: &str, mihomo: &str) -> (bool, String) {
    let mode = transparent_mode(app);
    let core = active_core(singbox, mihomo);
    let tproxy_dns = if mode == "tproxy" {
        tproxy_dns_capture(tproxy_port(app))
    } else {
        true
    };

    match core {
        "mihomo" => {
            let cfg = mihomo_dns_config(app, mode, tproxy_dns);
            (
                cfg.ok(),
                format!(
                    "core=mihomo, mode={mode}, fake_ip={}, listen_53={}, dns_hijack={}, remote_dns={}, tproxy_53={}",
                    yes_no(cfg.fake_ip),
                    yes_no(cfg.listen_53),
                    yes_no(cfg.hijack),
                    yes_no(cfg.remote_dns),
                    yes_no(tproxy_dns),
                ),
            )
        }
        "sing-box" => {
            let cfg = singbox_dns_config(app, mode, tproxy_dns);
            (
                cfg.ok(),
                format!(
                    "core=sing-box, mode={mode}, fakeip={}, hijack_dns={}, remote_dns_detour={}, store_fakeip={}, sniff_inbound={}, tproxy_53={}",
                    yes_no(cfg.fake_ip),
                    yes_no(cfg.hijack),
                    yes_no(cfg.remote_dns),
                    yes_no(cfg.store_fake_ip),
                    yes_no(cfg.sniff_inbound),
                    yes_no(tproxy_dns),
                ),
            )
        }
        _ => {
            let singbox = singbox_dns_config(app, mode, tproxy_dns);
            let mihomo = mihomo_dns_config(app, mode, tproxy_dns);
            (
                singbox.ok() || mihomo.ok(),
                format!(
                    "core=stopped, mode={mode}, sing-box={}, mihomo={}, tproxy_53={}",
                    yes_no(singbox.ok()),
                    yes_no(mihomo.ok()),
                    yes_no(tproxy_dns),
                ),
            )
        }
    }
}

#[derive(Clone, Copy)]
struct SingboxDnsConfig {
    fake_ip: bool,
    hijack: bool,
    remote_dns: bool,
    store_fake_ip: bool,
    sniff_inbound: bool,
    tproxy_dns: bool,
}

impl SingboxDnsConfig {
    fn ok(self) -> bool {
        self.fake_ip
            && self.hijack
            && self.remote_dns
            && self.store_fake_ip
            && self.sniff_inbound
            && self.tproxy_dns
    }
}

#[derive(Clone, Copy)]
struct MihomoDnsConfig {
    fake_ip: bool,
    listen_53: bool,
    hijack: bool,
    remote_dns: bool,
    tproxy_dns: bool,
}

impl MihomoDnsConfig {
    fn ok(self) -> bool {
        self.fake_ip && self.listen_53 && self.hijack && self.remote_dns && self.tproxy_dns
    }
}

fn active_core<'a>(singbox: &str, mihomo: &str) -> &'a str {
    if singbox != "stopped" {
        "sing-box"
    } else if mihomo != "stopped" {
        "mihomo"
    } else {
        "stopped"
    }
}

fn singbox_dns_config(app: &App, mode: &str, tproxy_dns: bool) -> SingboxDnsConfig {
    let text =
        fs::read_to_string(app.moddir.join(".config/sing-box/config.json")).unwrap_or_default();
    let compact = compact_jsonish(&text);
    let sniff_tag = if mode == "tproxy" {
        "\"tproxy-in\""
    } else {
        "\"tun-in\""
    };
    SingboxDnsConfig {
        fake_ip: compact.contains("\"type\":\"fakeip\"") && compact.contains("\"tag\":\"fakeip\""),
        hijack: compact.contains("\"protocol\":\"dns\"")
            && compact.contains("\"action\":\"hijack-dns\""),
        remote_dns: compact.contains("\"detour\":\"proxy\"")
            && (compact.contains("\"server\":\"dns.google\"")
                || compact.contains("\"server\":\"cloudflare-dns.com\"")
                || compact.contains("\"server\":\"dns.adguard-dns.com\"")),
        store_fake_ip: compact.contains("\"store_fakeip\":true"),
        sniff_inbound: compact.contains(sniff_tag),
        tproxy_dns,
    }
}

fn mihomo_dns_config(app: &App, mode: &str, tproxy_dns: bool) -> MihomoDnsConfig {
    let text =
        fs::read_to_string(app.moddir.join(".config/mihomo/config.yaml")).unwrap_or_default();
    let compact = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.starts_with('#'))
        .collect::<Vec<_>>()
        .join(" ");
    MihomoDnsConfig {
        fake_ip: compact.contains("enhanced-mode: fake-ip")
            && compact.contains("store-fake-ip: true"),
        listen_53: compact.contains("listen: 0.0.0.0:53")
            || compact.contains("listen: :53")
            || compact.contains("listen: '[::]:53'")
            || compact.contains("listen: \"[::]:53\""),
        hijack: mode == "tun" && compact.contains("dns-hijack:") && compact.contains("any:53")
            || mode == "tproxy" && tproxy_dns,
        remote_dns: compact.contains("dns.google")
            || compact.contains("cloudflare-dns.com")
            || compact.contains("dns.adguard-dns.com")
            || compact.contains("https://")
            || compact.contains("tls://")
            || compact.contains("quic://"),
        tproxy_dns,
    }
}

fn tproxy_dns_capture(port: u16) -> bool {
    let script = format!(
        "iptables -t mangle -S MAGICNET_TPROXY 2>/dev/null | grep -F TPROXY | grep -F -- '--dport 53' | grep -F -- '--on-port {port}' >/dev/null"
    );
    shell_ok(&script)
}

fn transparent_mode(app: &App) -> &'static str {
    fs::read_to_string(app.moddir.join(".config/magicnet/transparent-mode.conf"))
        .ok()
        .filter(|text| {
            text.lines()
                .any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=tproxy")
        })
        .map(|_| "tproxy")
        .unwrap_or("tun")
}

fn tproxy_port(app: &App) -> u16 {
    if let Some(port) = read_kv(app.moddir.join(".config/magicnet/tproxy.conf"))
        .get("MAGICNET_TPROXY_PORT")
        .and_then(|value| value.parse::<u16>().ok())
    {
        return port;
    }
    fs::read_to_string(app.moddir.join(".config/mihomo/config.yaml"))
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| yaml_string_value(line, "tproxy-port"))
        })
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(9898)
}

fn tproxy_mark(app: &App) -> String {
    read_kv(app.moddir.join(".config/magicnet/tproxy.conf"))
        .get("MAGICNET_TPROXY_MARK")
        .cloned()
        .unwrap_or_else(|| "0x1".to_string())
}

fn tproxy_table(app: &App) -> String {
    read_kv(app.moddir.join(".config/magicnet/tproxy.conf"))
        .get("MAGICNET_TPROXY_TABLE")
        .cloned()
        .unwrap_or_else(|| "100".to_string())
}

fn tproxy_kernel_supported() -> bool {
    shell_ok("[ -d /sys/module/xt_TPROXY ] || { [ -r /proc/net/ip_tables_targets ] && grep -qx TPROXY /proc/net/ip_tables_targets; }")
}

fn tproxy_configured_for_core(app: &App, core: &str, port: u16) -> bool {
    match core {
        "sing-box" => singbox_has_tproxy_inbound(app, port),
        "mihomo" => mihomo_has_tproxy_port(app, port),
        _ => singbox_has_tproxy_inbound(app, port) || mihomo_has_tproxy_port(app, port),
    }
}

fn singbox_has_tproxy_inbound(app: &App, port: u16) -> bool {
    fs::read_to_string(app.moddir.join(".config/sing-box/config.json"))
        .map(|text| {
            let compact = compact_jsonish(&text);
            compact.contains("\"type\":\"tproxy\"")
                && compact.contains(&format!("\"listen_port\":{port}"))
        })
        .unwrap_or(false)
}

fn mihomo_has_tproxy_port(app: &App, port: u16) -> bool {
    fs::read_to_string(app.moddir.join(".config/mihomo/config.yaml"))
        .map(|text| {
            text.lines().any(|line| {
                yaml_string_value(line, "tproxy-port").and_then(|value| value.parse::<u16>().ok())
                    == Some(port)
            })
        })
        .unwrap_or(false)
}

fn tproxy_listener(port: u16) -> bool {
    let script = format!("ss -lnptu 2>/dev/null | grep -Eq '(^|[[:space:]])(\\[::\\]|\\*|0\\.0\\.0\\.0|127\\.0\\.0\\.1|::):{port}([[:space:]]|$)'");
    shell_ok(&script)
}

fn tproxy_iptables_chain(port: u16) -> bool {
    let script = format!(
        "iptables -t mangle -S MAGICNET_TPROXY 2>/dev/null | grep -F TPROXY | grep -F -- '--on-port {port}' >/dev/null"
    );
    shell_ok(&script)
}

fn tproxy_prerouting_jump() -> bool {
    shell_ok(
        "iptables -t mangle -S PREROUTING 2>/dev/null | grep -F -- '-j MAGICNET_TPROXY' >/dev/null",
    )
}

fn tproxy_socket_guard() -> bool {
    shell_ok(
        "iptables -t mangle -S MAGICNET_TPROXY 2>/dev/null | head -5 | grep -F -- '-m socket -j RETURN' >/dev/null",
    )
}

fn tproxy_output_jump() -> bool {
    shell_ok(
        "iptables -t mangle -S OUTPUT 2>/dev/null | grep -F -- '-j MAGICNET_TPROXY_OUTPUT' >/dev/null",
    )
}

fn tproxy_output_loop_guard() -> bool {
    shell_ok(
        "iptables -t mangle -S MAGICNET_TPROXY_OUTPUT 2>/dev/null | head -5 | grep -F -- '--uid-owner 0 -j RETURN' >/dev/null",
    ) && shell_ok(
        "iptables -t mangle -S MAGICNET_TPROXY_OUTPUT 2>/dev/null | head -8 | grep -F -- '-d 127.0.0.0/8 -j RETURN' >/dev/null",
    )
}

fn tproxy_policy_rule(mark: &str, table: &str) -> bool {
    let mark_decimal = parse_hex_u32(mark).map(|value| value.to_string());
    let mut patterns = vec![
        format!("fwmark {mark} lookup {table}"),
        format!("fwmark {mark} table {table}"),
    ];
    if let Some(decimal) = mark_decimal {
        patterns.push(format!("fwmark {decimal} lookup {table}"));
        patterns.push(format!("fwmark {decimal} table {table}"));
    }
    let rules = command_stdout("ip", &["rule", "show"]);
    patterns.iter().any(|pattern| rules.contains(pattern))
}

fn tproxy_local_route(table: &str) -> bool {
    let route = command_stdout("ip", &["route", "show", "table", table]);
    route.contains("local default dev lo")
}

fn tproxy_ipv6_chain(port: u16) -> bool {
    let script = format!(
        "command -v ip6tables >/dev/null 2>&1 && ip6tables -t mangle -S MAGICNET_TPROXY 2>/dev/null | grep -F TPROXY | grep -F -- '--on-port {port}' >/dev/null"
    );
    shell_ok(&script)
}

fn shell_ok(script: &str) -> bool {
    Command::new("sh")
        .args(["-c", script])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn command_stdout(program: &str, args: &[&str]) -> String {
    Command::new(program)
        .args(args)
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).to_string())
        .unwrap_or_default()
}

fn compact_jsonish(text: &str) -> String {
    text.chars()
        .filter(|ch| !ch.is_ascii_whitespace())
        .collect()
}

fn parse_hex_u32(value: &str) -> Option<u32> {
    value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .and_then(|hex| u32::from_str_radix(hex, 16).ok())
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "ok"
    } else {
        "missing"
    }
}

fn configured_tun_names(app: &App) -> Vec<String> {
    let mut names = Vec::new();
    if let Ok(text) = fs::read_to_string(app.moddir.join(".config/sing-box/config.json")) {
        for line in text.lines() {
            if let Some(value) = json_string_value(line, "interface_name") {
                push_unique(&mut names, value);
            }
        }
    }
    if let Ok(text) = fs::read_to_string(app.moddir.join(".config/mihomo/config.yaml")) {
        for line in text.lines() {
            if let Some(value) = yaml_string_value(line, "device") {
                push_unique(&mut names, value);
            }
        }
    }
    names
}

fn json_string_value(line: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let (_, rest) = line.split_once(&needle)?;
    let (_, value) = rest.split_once(':')?;
    let value = value.trim().trim_end_matches(',').trim();
    value
        .strip_prefix('"')?
        .strip_suffix('"')
        .map(ToOwned::to_owned)
}

fn yaml_string_value(line: &str, key: &str) -> Option<String> {
    let line = line.trim();
    let value = line.strip_prefix(&format!("{key}:"))?;
    let value = value.trim().trim_matches('"').trim_matches('\'');
    (!value.is_empty()).then(|| value.to_string())
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !value.is_empty() && !values.iter().any(|item| item == &value) {
        values.push(value);
    }
}

fn watchdog_detail(app: &App) -> String {
    let pid = supervisor_pid(app, "watchdog", "magicnet-kernel");
    let fswatch = supervisor_pid(app, "fswatch", "magicnet-config");
    let log = fs::read_to_string(app.log_dir.join("watchdog.log"))
        .ok()
        .and_then(|text| {
            text.lines()
                .rev()
                .find(|line| !line.trim().is_empty())
                .map(ToOwned::to_owned)
        })
        .unwrap_or_else(|| "no watchdog.log".to_string());
    format!("watchdog={pid}, fswatch={fswatch}, latest={}", redact(&log))
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
        .filter(|pid| PathBuf::from(format!("/proc/{pid}")).exists())
        .map(|pid| pid.to_string())
        .unwrap_or_else(|| "stopped".to_string())
}

fn has_subscription(app: &App) -> bool {
    sensitive_paths(app)
        .into_iter()
        .any(|path| !clean_lines(path).is_empty())
}

fn sensitive_paths(app: &App) -> Vec<PathBuf> {
    vec![
        app.moddir.join(".config/sing-box/subscription.url"),
        app.moddir.join(".config/mihomo/subscription.url"),
    ]
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
    let output = std::process::Command::new("ip")
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

fn print_redacted_tail(path: PathBuf) {
    println!("{}:", path.display());
    let text = fs::read_to_string(path).unwrap_or_default();
    for line in text
        .lines()
        .rev()
        .take(40)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        println!("{}", redact(line));
    }
}

pub(crate) fn redact(text: &str) -> String {
    text.split_whitespace()
        .map(|part| {
            if part.starts_with("http://") || part.starts_with("https://") {
                if is_local_url(part) {
                    part.to_string()
                } else {
                    "<redacted-url>".to_string()
                }
            } else if part.to_ascii_lowercase().contains("password")
                || part.to_ascii_lowercase().contains("token")
                || part.to_ascii_lowercase().contains("secret")
            {
                "<redacted-secret>".to_string()
            } else {
                part.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn is_local_url(value: &str) -> bool {
    let Some(host) = value
        .trim_start_matches("http://")
        .trim_start_matches("https://")
        .split(['/', ':', '?', '#'])
        .next()
    else {
        return false;
    };
    matches!(host, "127.0.0.1" | "localhost" | "::1" | "[::1]")
}
