use std::fs;
use std::path::PathBuf;
use std::process::Command;

use crate::diagnostics_dns::dns_leak_check;
use crate::diagnostics_ebpf::{collect_ebpf_status, ebpf_profile, transparent_mode};
use crate::{clean_lines, command_text_timeout, mcp, pid_summary, App};

pub(crate) fn health(app: &App) -> Result<(), String> {
    let singbox = pid_summary("sing-box");
    print_check("Core", &running(&singbox), format!("sing-box={singbox}"));
    let mode = transparent_mode(app);
    let (tun_ok, tun_detail) = tun_check(app, mode);
    print_check("TUN", &tun_ok, tun_detail);
    let ebpf = collect_ebpf_status(app);
    print_check("eBPF", &ebpf.ok(), ebpf.health_detail());
    print_check("netd", &ebpf.netd_ok(), ebpf.netd_detail());
    let ecapture = app.moddir.join("bin/ecapture");
    print_check(
        "eCapture",
        &ecapture.is_file(),
        format!("binary={}", ecapture.display()),
    );
    let (dns_ok, dns_detail) = dns_leak_check(app, &singbox, mode);
    print_check("DNS Leak", &dns_ok, dns_detail);
    let (api_ok, api_detail) = api_probe(&app.api);
    print_check("Core API", &api_ok, api_detail);
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
    println!("[ebpf]");
    ebpf_status(app)?;
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
    Ok(())
}

pub(crate) fn ebpf_status(app: &App) -> Result<(), String> {
    let status = collect_ebpf_status(app);
    println!("MagicNet eBPF");
    println!("mode={}", status.mode);
    println!("profile={}", status.profile);
    println!("bpffs={}", ok_word(status.bpffs));
    println!("btf={}", ok_word(status.btf));
    println!("cgroup={}", ok_word(status.cgroup));
    println!("dns_cgroup={}", ok_word(status.dns_cgroup));
    println!("config_cgroup_bpf={}", ok_word(status.config_cgroup_bpf));
    println!("config_bpf_syscall={}", ok_word(status.config_bpf_syscall));
    println!("loader={}", ok_word(status.loader));
    println!("loader_executable={}", ok_word(status.loader_executable));
    println!("redirect={}", ok_word(status.redirect));
    println!(
        "allow_multi_permission={}",
        yes_no(status.allow_multi_permission)
    );
    println!("probe={}", status.probe_label());
    println!("cgroup_path={}", status.cgroup_path);
    println!("dns_cgroup_path={}", status.dns_cgroup_path);
    println!("loader_path={}", status.loader_path.display());
    println!("mixed_port={}", status.mixed_port);
    println!("dns_port={}", status.dns_port);
    println!("state_dir={}", status.state_dir.display());
    println!("state_file={}", present_word(status.state_present));
    println!("daemon_pid={}", status.daemon_pid);
    println!("daemon={}", status.daemon_label());
    for key in [
        "mode",
        "profile",
        "mixed_port",
        "dns_port",
        "bridge4_port",
        "bridge6_port",
        "dns_udp4",
        "dns_udp6",
        "netd_dns_connect4",
        "netd_dns_connect6",
        "netd_dns_udp4",
        "netd_dns_udp6",
        "root_dns_tcp4",
        "root_dns_tcp6",
        "root_dns_udp4",
        "root_dns_udp6",
    ] {
        if let Some(value) = status.state.get(key) {
            println!("state.{key}={value}");
        }
    }
    println!("netd={}", status.netd_summary());
    for name in ["connect4", "connect6", "udp4_dns", "udp6_dns"] {
        let pin_key = format!("{name}.netd_pin");
        if let Some(value) = status.netd.get(&pin_key) {
            println!("netd.{pin_key}={value}");
        }
        for scope in ["direct", "effective"] {
            for key in ["count", "attach_flags", "prog_ids"] {
                let map_key = format!("{name}.{scope}.{key}");
                if let Some(value) = status.netd.get(&map_key) {
                    println!("netd.{map_key}={value}");
                }
            }
        }
    }
    if !status.query_error.is_empty() {
        println!("netd.query_error={}", status.query_error);
    }
    Ok(())
}

fn print_check(key: &str, ok: &bool, detail: String) {
    let status = if *ok { "ok" } else { "warn" };
    println!("[{status}] {key}: {}", redact(&detail));
}

fn running(core: &str) -> bool {
    core != "stopped"
}

fn iface_detail(name: &str) -> String {
    command_text_timeout("ip", &["addr", "show", name], crate::SHORT_TIMEOUT)
}

fn tun_check(app: &App, mode: &str) -> (bool, String) {
    if mode == "ebpf" && ebpf_profile(app) != "tcp" {
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

fn configured_tun_names(app: &App) -> Vec<String> {
    let mut names = Vec::new();
    if let Ok(text) = fs::read_to_string(app.moddir.join(".config/sing-box/config.json")) {
        for line in text.lines() {
            if let Some(value) = json_string_value(line, "interface_name") {
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
    vec![app.moddir.join(".config/sing-box/subscription.url")]
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

fn ok_word(value: bool) -> &'static str {
    if value {
        "ok"
    } else {
        "missing"
    }
}

fn present_word(value: bool) -> &'static str {
    if value {
        "present"
    } else {
        "missing"
    }
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "ok"
    } else {
        "missing"
    }
}
