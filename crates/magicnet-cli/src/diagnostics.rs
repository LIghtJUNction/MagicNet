use std::fs;
use std::path::PathBuf;

use crate::{clean_lines, command_text_timeout, pid_summary, App};

pub(crate) fn health(app: &App) -> Result<(), String> {
    let singbox = pid_summary("sing-box");
    let mihomo = pid_summary("mihomo");
    print_check("Core", &running(&singbox, &mihomo), format!("sing-box={singbox}, mihomo={mihomo}"));
    let (tun_ok, tun_detail) = tun_check(app);
    print_check("TUN", &tun_ok, tun_detail);
    print_check("Clash API", &http_probe("http://127.0.0.1:9090"), app.api.clone());
    print_check("Subscription", &has_subscription(app), "subscription config present".to_string());
    print_check("MCP", &pid_summary("magicnet-mcp-server").ne("stopped"), pid_summary("magicnet-mcp-server"));
    print_check("Watchdog", &pid_summary("watchdog").ne("stopped"), watchdog_detail(app));
    print_check("WebUI", &app.moddir.join("webroot/index.html").exists(), app.moddir.join("webroot").display().to_string());
    Ok(())
}

pub(crate) fn topology(app: &App) -> Result<(), String> {
    println!("MagicNet network topology");
    println!("module={}", app.moddir.display());
    println!();
    println!("[interfaces]");
    println!("{}", command_text_timeout("ip", &["-o", "addr", "show"], crate::SHORT_TIMEOUT));
    println!();
    println!("[routes]");
    sysroute_snapshot();
    println!();
    println!("[forwarding]");
    println!("{}", command_text_timeout("sh", &["-c", "iptables -t nat -S 2>/dev/null | head -80"], crate::SHORT_TIMEOUT));
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
        println!("{}={}", path.display(), if path.exists() { "<configured>" } else { "<missing>" });
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
    (false, format!("No MagicNet TUN interface found. checked={checked}"))
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
    value.strip_prefix('"')?.strip_suffix('"').map(ToOwned::to_owned)
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
    let pid = pid_summary("watchdog");
    let fswatch = pid_summary("fswatch");
    let log = fs::read_to_string(app.log_dir.join("watchdog.log"))
        .ok()
        .and_then(|text| text.lines().rev().find(|line| !line.trim().is_empty()).map(ToOwned::to_owned))
        .unwrap_or_else(|| "no watchdog.log".to_string());
    format!("watchdog={pid}, fswatch={fswatch}, latest={}", redact(&log))
}

fn http_probe(url: &str) -> bool {
    command_text_timeout("curl", &["-fsS", "--max-time", "2", url], crate::SHORT_TIMEOUT)
        .contains('{')
}

fn has_subscription(app: &App) -> bool {
    sensitive_paths(app).into_iter().any(|path| !clean_lines(path).is_empty())
}

fn sensitive_paths(app: &App) -> Vec<PathBuf> {
    vec![
        app.moddir.join(".config/sing-box/subscription.url"),
        app.moddir.join(".config/mihomo/subscription.url"),
    ]
}

fn sysroute_snapshot() {
    println!("ip rule:");
    println!("{}", command_text_timeout("ip", &["rule", "show"], crate::SHORT_TIMEOUT));
    println!("ip route:");
    println!("{}", command_text_timeout("ip", &["route", "show", "table", "all"], crate::SHORT_TIMEOUT));
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
    for line in text.lines().rev().take(40).collect::<Vec<_>>().into_iter().rev() {
        println!("{}", redact(line));
    }
}

pub(crate) fn redact(text: &str) -> String {
    text.split_whitespace()
        .map(|part| {
            if part.starts_with("http://") || part.starts_with("https://") {
                "<redacted-url>".to_string()
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
