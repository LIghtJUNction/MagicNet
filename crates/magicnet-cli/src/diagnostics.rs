use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::{clean_lines, command_text_timeout, mcp, pid_summary, App};

pub(crate) fn health(app: &App) -> Result<(), String> {
    let singbox = pid_summary("sing-box");
    let mihomo = pid_summary("mihomo");
    print_check(
        "Core",
        &running(&singbox, &mihomo),
        format!("sing-box={singbox}, mihomo={mihomo}"),
    );
    let mode = transparent_mode(app);
    let (tun_ok, tun_detail) = tun_check(app, &mode);
    print_check("TUN", &tun_ok, tun_detail);
    let (ebpf_ok, ebpf_detail) = ebpf_check(app);
    print_check("eBPF", &ebpf_ok, ebpf_detail);
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

fn tun_check(app: &App, mode: &str) -> (bool, String) {
    if mode == "ebpf" {
        return (true, "mode=ebpf, inactive".to_string());
    }
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

fn ebpf_check(app: &App) -> (bool, String) {
    let mode = transparent_mode(app);
    let bpffs =
        shell_ok("[ -d /sys/fs/bpf ] && mount 2>/dev/null | grep -q ' on /sys/fs/bpf type bpf '");
    let cgroup = shell_ok("[ -d /sys/fs/cgroup ]");
    let config = shell_ok("zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_CGROUP_BPF=y'")
        || shell_ok("[ ! -r /proc/config.gz ]");
    let syscall = shell_ok("zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_BPF_SYSCALL=y'")
        || shell_ok("[ ! -r /proc/config.gz ]");
    let loader_path = app.moddir.join("bin/magicnet-ebpf");
    let loader = loader_path.exists();
    let probe = if bpffs && cgroup && config && syscall && loader {
        Command::new(&loader_path)
            .args(["probe", "--cgroup", "/sys/fs/cgroup/apps"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    } else {
        false
    };

    if mode != "ebpf" {
        return (true, format!("mode={mode}, inactive, bpffs={}, cgroup={}, config={}, syscall={}, loader={}, probe={}", yes_no(bpffs), yes_no(cgroup), yes_no(config), yes_no(syscall), yes_no(loader), probe_state(loader, probe)));
    }
    let ok = bpffs && cgroup && config && syscall && loader && probe;
    (
        ok,
        format!(
            "mode=ebpf, bpffs={}, cgroup={}, config={}, syscall={}, loader={}, probe={}",
            yes_no(bpffs),
            yes_no(cgroup),
            yes_no(config),
            yes_no(syscall),
            yes_no(loader),
            probe_state(loader, probe)
        ),
    )
}

fn dns_leak_check(app: &App, singbox: &str, mihomo: &str) -> (bool, String) {
    let mode = transparent_mode(app);
    let core = active_core(singbox, mihomo);
    let transparent_dns = true;

    match core {
        "mihomo" => {
            let cfg = mihomo_dns_config(app, mode, transparent_dns);
            (
                cfg.ok(),
                format!(
                    "core=mihomo, mode={mode}, fake_ip={}, listen_53={}, dns_hijack={}, remote_dns={}",
                    yes_no(cfg.fake_ip),
                    yes_no(cfg.listen_53),
                    yes_no(cfg.hijack),
                    yes_no(cfg.remote_dns),
                ),
            )
        }
        "sing-box" => {
            let cfg = singbox_dns_config(app, mode, transparent_dns);
            (
                cfg.ok(),
                format!(
                    "core=sing-box, mode={mode}, fakeip={}, hijack_dns={}, remote_dns_detour={}, store_fakeip={}, sniff_inbound={}, strategy={}",
                    yes_no(cfg.fake_ip),
                    yes_no(cfg.hijack),
                    yes_no(cfg.remote_dns),
                    yes_no(cfg.store_fake_ip),
                    yes_no(cfg.sniff_inbound),
                    cfg.strategy,
                ),
            )
        }
        _ => {
            let singbox = singbox_dns_config(app, mode, transparent_dns);
            let mihomo = mihomo_dns_config(app, mode, transparent_dns);
            (
                singbox.ok() || mihomo.ok(),
                format!(
                    "core=stopped, mode={mode}, sing-box={}, mihomo={}",
                    yes_no(singbox.ok()),
                    yes_no(mihomo.ok()),
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
    strategy: &'static str,
    ipv6_fallback_ready: bool,
    transparent_dns: bool,
}

impl SingboxDnsConfig {
    fn ok(self) -> bool {
        let fallback_ok = !self.ipv6_fallback_ready || self.strategy == "ipv4_only";
        self.fake_ip
            && self.hijack
            && self.remote_dns
            && self.store_fake_ip
            && self.sniff_inbound
            && fallback_ok
            && self.transparent_dns
    }
}

#[derive(Clone, Copy)]
struct MihomoDnsConfig {
    fake_ip: bool,
    listen_53: bool,
    hijack: bool,
    remote_dns: bool,
    transparent_dns: bool,
}

impl MihomoDnsConfig {
    fn ok(self) -> bool {
        self.fake_ip && self.listen_53 && self.hijack && self.remote_dns && self.transparent_dns
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

fn singbox_dns_config(app: &App, mode: &str, transparent_dns: bool) -> SingboxDnsConfig {
    let text =
        fs::read_to_string(app.moddir.join(".config/sing-box/config.json")).unwrap_or_default();
    let compact = compact_jsonish(&text);
    let strategy = singbox_dns_strategy(&compact);
    let ipv6_fallback_ready = false;
    let sniff_rule = if mode == "ebpf" {
        "\"inbound\":[\"mixed-in\",\"magicnet-ebpf-dns4-in\",\"magicnet-ebpf-dns6-in\"]"
    } else {
        "\"inbound\":[\"mixed-in\",\"tun-in\"]"
    };
    SingboxDnsConfig {
        fake_ip: compact.contains("\"type\":\"fakeip\"") && compact.contains("\"tag\":\"fakeip\""),
        hijack: compact.contains("\"protocol\":\"dns\"")
            && compact.contains("\"action\":\"hijack-dns\""),
        remote_dns: has_remote_dns_detour(&compact),
        store_fake_ip: compact.contains("\"store_fakeip\":true"),
        sniff_inbound: compact.contains(sniff_rule),
        strategy,
        ipv6_fallback_ready,
        transparent_dns,
    }
}

fn singbox_dns_strategy(compact: &str) -> &'static str {
    if compact.contains("\"strategy\":\"ipv4_only\"") {
        "ipv4_only"
    } else if compact.contains("\"strategy\":\"prefer_ipv4\"") {
        "prefer_ipv4"
    } else if compact.contains("\"strategy\":\"prefer_ipv6\"") {
        "prefer_ipv6"
    } else if compact.contains("\"strategy\":\"ipv6_only\"") {
        "ipv6_only"
    } else {
        "unset"
    }
}

fn has_remote_dns_detour(compact: &str) -> bool {
    compact.contains("\"detour\":\"proxy\"")
        && (compact.contains("\"server\":\"dns.google\"")
            || compact.contains("\"server\":\"cloudflare-dns.com\"")
            || compact.contains("\"server\":\"dns.adguard-dns.com\"")
            || compact.contains("\"server_name\":\"dns.google\"")
            || compact.contains("\"server_name\":\"cloudflare-dns.com\"")
            || compact.contains("\"server_name\":\"dns.adguard-dns.com\""))
}

fn mihomo_dns_config(app: &App, mode: &str, transparent_dns: bool) -> MihomoDnsConfig {
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
            || mode == "ebpf" && transparent_dns,
        remote_dns: compact.contains("dns.google")
            || compact.contains("cloudflare-dns.com")
            || compact.contains("dns.adguard-dns.com")
            || compact.contains("https://")
            || compact.contains("tls://")
            || compact.contains("quic://"),
        transparent_dns,
    }
}

fn transparent_mode(app: &App) -> &'static str {
    fs::read_to_string(app.moddir.join(".config/magicnet/transparent-mode.conf"))
        .ok()
        .and_then(|text| {
            if text
                .lines()
                .any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=ebpf")
            {
                Some("ebpf")
            } else if text
                .lines()
                .any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=auto")
            {
                Some("auto")
            } else if text
                .lines()
                .any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=tun")
            {
                Some("tun")
            } else {
                None
            }
        })
        .unwrap_or("auto")
}

fn shell_ok(script: &str) -> bool {
    Command::new("sh")
        .args(["-c", script])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn compact_jsonish(text: &str) -> String {
    text.chars()
        .filter(|ch| !ch.is_ascii_whitespace())
        .collect()
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "ok"
    } else {
        "missing"
    }
}

fn probe_state(loader: bool, probe: bool) -> &'static str {
    if probe {
        "ok"
    } else if loader {
        "blocked"
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
    let pid_path = path.clone();
    fs::read_to_string(path)
        .ok()
        .and_then(|text| text.trim().parse::<u32>().ok())
        .filter(|pid| supervisor_pid_matches(app, *pid, name))
        .map(|pid| pid.to_string())
        .unwrap_or_else(|| {
            let _ = fs::remove_file(pid_path);
            "stopped".to_string()
        })
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
    let moddir = app.moddir.display().to_string();
    cmdline.contains(name)
        || (cmdline.contains("service ensure") && cmdline.contains(&moddir))
        || (cmdline.contains("config apply") && cmdline.contains(&moddir))
        || cmdline.contains(&moddir)
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

#[cfg(test)]
mod tests {
    use super::{compact_jsonish, has_remote_dns_detour};

    #[test]
    fn remote_dns_detour_accepts_tls_server_name() {
        let config = r#"
        {
          "dns": {
            "servers": [
              {
                "type": "https",
                "tag": "doh-google",
                "detour": "proxy",
                "server": "8.8.8.8",
                "server_port": 443,
                "tls": {
                  "server_name": "dns.google"
                }
              }
            ]
          }
        }
        "#;

        assert!(has_remote_dns_detour(&compact_jsonish(config)));
    }

    #[test]
    fn remote_dns_detour_requires_proxy_detour() {
        let config = r#"
        {
          "dns": {
            "servers": [
              {
                "type": "https",
                "tag": "doh-google",
                "server": "dns.google"
              }
            ]
          }
        }
        "#;

        assert!(!has_remote_dns_detour(&compact_jsonish(config)));
    }
}
