use std::collections::BTreeMap;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

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
    let (dns_ok, dns_detail) = dns_leak_check(app, &singbox);
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
    println!("bpffs={}", ok_word(status.bpffs));
    println!("btf={}", ok_word(status.btf));
    println!("cgroup={}", ok_word(status.cgroup));
    println!("dns_cgroup={}", ok_word(status.dns_cgroup));
    println!("config_cgroup_bpf={}", ok_word(status.config_cgroup_bpf));
    println!("config_bpf_syscall={}", ok_word(status.config_bpf_syscall));
    println!("loader={}", ok_word(status.loader));
    println!("loader_executable={}", ok_word(status.loader_executable));
    println!("redirect={}", ok_word(status.redirect));
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
        "mixed_port",
        "dns_port",
        "connect4",
        "connect6",
        "sockops",
        "dns_udp4",
        "dns_udp6",
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

#[derive(Debug)]
struct EbpfStatus {
    mode: &'static str,
    bpffs: bool,
    btf: bool,
    cgroup: bool,
    dns_cgroup: bool,
    config_cgroup_bpf: bool,
    config_bpf_syscall: bool,
    loader: bool,
    loader_executable: bool,
    redirect: bool,
    probe: bool,
    cgroup_path: String,
    dns_cgroup_path: String,
    loader_path: PathBuf,
    mixed_port: String,
    dns_port: String,
    state_dir: PathBuf,
    state_present: bool,
    daemon_pid: String,
    daemon_live: bool,
    state: BTreeMap<String, String>,
    netd: BTreeMap<String, String>,
    query_error: String,
}

impl EbpfStatus {
    fn ok(&self) -> bool {
        if self.mode == "tun" {
            return true;
        }
        let runtime_ok = self.mode != "ebpf" || (self.daemon_live && self.state_is_attached());
        self.bpffs
            && self.cgroup
            && self.dns_cgroup
            && self.config_cgroup_bpf
            && self.config_bpf_syscall
            && self.loader_executable
            && self.redirect
            && self.probe
            && runtime_ok
    }

    fn netd_ok(&self) -> bool {
        if !self.query_error.is_empty() {
            return false;
        }
        ["connect4", "connect6"].iter().all(|name| {
            self.netd
                .get(&format!("{name}.netd_pin"))
                .map(|value| value == "present")
                .unwrap_or(false)
                && self
                    .netd
                    .get(&format!("{name}.direct.count"))
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(0)
                    >= 1
        })
    }

    fn state_is_attached(&self) -> bool {
        ["connect4", "connect6", "sockops"].iter().all(|key| {
            self.state
                .get(*key)
                .map(|value| value == "attached")
                .unwrap_or(false)
        })
    }

    fn probe_label(&self) -> &'static str {
        probe_state(self.loader_executable, self.probe)
    }

    fn daemon_label(&self) -> &'static str {
        if self.daemon_live && self.state_is_attached() {
            "running"
        } else if self.daemon_live {
            "pid-live-state-incomplete"
        } else if self.daemon_pid != "stopped" {
            "stale"
        } else {
            "stopped"
        }
    }

    fn health_detail(&self) -> String {
        format!(
            "mode={}, daemon={}, bpffs={}, btf={}, cgroup={}, dns_cgroup={}, config={}, syscall={}, loader={}, redirect={}, probe={}, mixed_port={}, dns_port={}, state={}",
            self.mode,
            self.daemon_label(),
            yes_no(self.bpffs),
            yes_no(self.btf),
            yes_no(self.cgroup),
            yes_no(self.dns_cgroup),
            yes_no(self.config_cgroup_bpf),
            yes_no(self.config_bpf_syscall),
            yes_no(self.loader_executable),
            yes_no(self.redirect),
            self.probe_label(),
            self.mixed_port,
            self.dns_port,
            present_word(self.state_present),
        )
    }

    fn netd_detail(&self) -> String {
        if !self.query_error.is_empty() {
            return format!("query=failed, {}", self.query_error);
        }
        self.netd_summary()
    }

    fn netd_summary(&self) -> String {
        let mut parts = Vec::new();
        for name in ["connect4", "connect6", "udp4_dns", "udp6_dns"] {
            let pin = self
                .netd
                .get(&format!("{name}.netd_pin"))
                .map(String::as_str)
                .unwrap_or("missing");
            let flags = self
                .netd
                .get(&format!("{name}.direct.attach_flags"))
                .map(String::as_str)
                .unwrap_or("unknown");
            let count = self
                .netd
                .get(&format!("{name}.direct.count"))
                .map(String::as_str)
                .unwrap_or("unknown");
            parts.push(format!("{name}:pin={pin},flags={flags},count={count}"));
        }
        parts.join("; ")
    }
}

fn collect_ebpf_status(app: &App) -> EbpfStatus {
    let mode = transparent_mode(app);
    let cgroup_path = if PathBuf::from("/sys/fs/cgroup/apps").is_dir() {
        "/sys/fs/cgroup/apps".to_string()
    } else {
        "/sys/fs/cgroup".to_string()
    };
    let dns_cgroup_path = "/sys/fs/cgroup".to_string();
    let bpffs =
        shell_ok("[ -d /sys/fs/bpf ] && mount 2>/dev/null | grep -q ' on /sys/fs/bpf type bpf '");
    let btf = PathBuf::from("/sys/kernel/btf/vmlinux").is_file()
        || shell_ok("zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_DEBUG_INFO_BTF=y'")
        || shell_ok("[ ! -r /proc/config.gz ]");
    let config_cgroup_bpf =
        shell_ok("zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_CGROUP_BPF=y'")
            || shell_ok("[ ! -r /proc/config.gz ]");
    let config_bpf_syscall =
        shell_ok("zcat /proc/config.gz 2>/dev/null | grep -qx 'CONFIG_BPF_SYSCALL=y'")
            || shell_ok("[ ! -r /proc/config.gz ]");
    let loader_path = app.moddir.join("bin/magicnet-ebpf");
    let loader = loader_path.exists();
    let loader_executable = is_executable(&loader_path);
    let redirect = loader_executable && command_success(&loader_path, &["supports-redirect"]);
    let probe = if bpffs
        && PathBuf::from(&cgroup_path).is_dir()
        && PathBuf::from(&dns_cgroup_path).is_dir()
        && config_cgroup_bpf
        && config_bpf_syscall
        && loader_executable
    {
        command_success(
            &loader_path,
            &[
                "probe",
                "--cgroup",
                &cgroup_path,
                "--dns-cgroup",
                &dns_cgroup_path,
            ],
        )
    } else {
        false
    };
    let state_dir = app.moddir.join(".state/ebpf");
    let state_file = state_dir.join("magicnet-ebpf.state");
    let state = read_state_file(&state_file);
    let state_present = state_file.is_file();
    let daemon_pid = read_pid(state_dir.join("guard.pid"));
    let daemon_live = daemon_pid
        .parse::<u32>()
        .map(proc_pid_exists)
        .unwrap_or(false);
    let (netd, query_error) = collect_netd_status(&loader_path, loader_executable);
    let (mixed_port, dns_port) = singbox_ports(app);

    EbpfStatus {
        mode,
        bpffs,
        btf,
        cgroup: PathBuf::from(&cgroup_path).is_dir(),
        dns_cgroup: PathBuf::from(&dns_cgroup_path).is_dir(),
        config_cgroup_bpf,
        config_bpf_syscall,
        loader,
        loader_executable,
        redirect,
        probe,
        cgroup_path,
        dns_cgroup_path,
        loader_path,
        mixed_port,
        dns_port,
        state_dir,
        state_present,
        daemon_pid,
        daemon_live,
        state,
        netd,
        query_error,
    }
}

fn dns_leak_check(app: &App, singbox: &str) -> (bool, String) {
    let mode = transparent_mode(app);
    let transparent_dns = true;

    let cfg = singbox_dns_config(app, mode, transparent_dns);
    let core = if singbox != "stopped" {
        "sing-box"
    } else {
        "stopped"
    };
    (
        cfg.ok(),
        format!(
            "core={core}, mode={mode}, fakeip={}, hijack_dns={}, remote_dns_detour={}, store_fakeip={}, sniff_inbound={}, ebpf_dns_inbound={}, strategy={}",
            yes_no(cfg.fake_ip),
            yes_no(cfg.hijack),
            yes_no(cfg.remote_dns),
            yes_no(cfg.store_fake_ip),
            yes_no(cfg.sniff_inbound),
            yes_no(cfg.ebpf_dns_inbound),
            cfg.strategy,
        ),
    )
}

#[derive(Clone, Copy)]
struct SingboxDnsConfig {
    fake_ip: bool,
    hijack: bool,
    remote_dns: bool,
    store_fake_ip: bool,
    sniff_inbound: bool,
    ebpf_dns_inbound: bool,
    strategy: &'static str,
    ipv6_fallback_ready: bool,
    transparent_dns: bool,
    require_ebpf_dns_inbound: bool,
}

impl SingboxDnsConfig {
    fn ok(self) -> bool {
        let fallback_ok = !self.ipv6_fallback_ready || self.strategy == "ipv4_only";
        let ebpf_dns_ok = !self.require_ebpf_dns_inbound || self.ebpf_dns_inbound;
        self.fake_ip
            && self.hijack
            && self.remote_dns
            && self.store_fake_ip
            && self.sniff_inbound
            && ebpf_dns_ok
            && fallback_ok
            && self.transparent_dns
    }
}

fn singbox_dns_config(app: &App, mode: &str, transparent_dns: bool) -> SingboxDnsConfig {
    let text =
        fs::read_to_string(app.moddir.join(".config/sing-box/config.json")).unwrap_or_default();
    let compact = compact_jsonish(&text);
    let strategy = singbox_dns_strategy(&compact);
    let ipv6_fallback_ready = false;
    let require_ebpf_dns_inbound = mode != "tun";
    let sniff_inbound = sniff_rule_has(&compact, "mixed-in")
        && (mode == "ebpf" || sniff_rule_has(&compact, "tun-in"))
        && (!require_ebpf_dns_inbound
            || (sniff_rule_has(&compact, "magicnet-ebpf-dns4-in")
                && sniff_rule_has(&compact, "magicnet-ebpf-dns6-in")));
    SingboxDnsConfig {
        fake_ip: compact.contains("\"type\":\"fakeip\"") && compact.contains("\"tag\":\"fakeip\""),
        hijack: compact.contains("\"protocol\":\"dns\"")
            && compact.contains("\"action\":\"hijack-dns\""),
        remote_dns: has_remote_dns_detour(&compact),
        store_fake_ip: compact.contains("\"store_fakeip\":true"),
        sniff_inbound,
        ebpf_dns_inbound: has_ebpf_dns_inbounds(&compact),
        strategy,
        ipv6_fallback_ready,
        transparent_dns,
        require_ebpf_dns_inbound,
    }
}

fn sniff_rule_has(compact: &str, tag: &str) -> bool {
    compact.contains("\"action\":\"sniff\"") && compact.contains(&format!("\"{tag}\""))
}

fn has_ebpf_dns_inbounds(compact: &str) -> bool {
    compact.contains("\"tag\":\"magicnet-ebpf-dns4-in\"")
        && compact.contains("\"listen\":\"127.0.0.1\"")
        && compact.contains("\"tag\":\"magicnet-ebpf-dns6-in\"")
        && compact.contains("\"listen\":\"::1\"")
        && compact.contains("\"listen_port\":")
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

fn command_success(program: &PathBuf, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn is_executable(path: &PathBuf) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        fs::metadata(path)
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
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

fn read_state_file(path: &PathBuf) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let text = fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        map.insert(key.trim().to_string(), value.trim().to_string());
    }
    map
}

fn read_pid(path: PathBuf) -> String {
    fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_string())
        .filter(|pid| !pid.is_empty() && pid.bytes().all(|byte| byte.is_ascii_digit()))
        .unwrap_or_else(|| "stopped".to_string())
}

fn proc_pid_exists(pid: u32) -> bool {
    PathBuf::from(format!("/proc/{pid}")).exists()
}

fn collect_netd_status(
    loader_path: &PathBuf,
    loader_executable: bool,
) -> (BTreeMap<String, String>, String) {
    let mut map = BTreeMap::new();
    for (name, path) in [
        (
            "connect4",
            "/sys/fs/bpf/netd_shared/prog_netd_connect4_inet4_connect",
        ),
        (
            "connect6",
            "/sys/fs/bpf/netd_shared/prog_netd_connect6_inet6_connect",
        ),
        (
            "udp4_dns",
            "/sys/fs/bpf/netd_shared/prog_netd_sendmsg4_udp4_sendmsg",
        ),
        (
            "udp6_dns",
            "/sys/fs/bpf/netd_shared/prog_netd_sendmsg6_udp6_sendmsg",
        ),
    ] {
        map.insert(
            format!("{name}.netd_pin"),
            if PathBuf::from(path).exists() {
                "present"
            } else {
                "missing"
            }
            .to_string(),
        );
    }

    if !loader_executable {
        return (map, "loader missing".to_string());
    }

    let output = Command::new(loader_path)
        .args(["query", "--cgroup", "/sys/fs/cgroup"])
        .output();
    let output = match output {
        Ok(output) => output,
        Err(err) => return (map, format!("run query: {err}")),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    for line in stdout.lines() {
        parse_netd_query_line(&mut map, line);
    }
    if output.status.success() {
        (map, String::new())
    } else {
        let detail = stderr.trim();
        (
            map,
            if detail.is_empty() {
                format!(
                    "query exited with status {}",
                    output.status.code().unwrap_or(1)
                )
            } else {
                detail.to_string()
            },
        )
    }
}

fn parse_netd_query_line(map: &mut BTreeMap<String, String>, line: &str) {
    let line = line.trim();
    let Some((left, right)) = line.split_once(':') else {
        return;
    };
    let Some((name, scope)) = left.split_once('.') else {
        return;
    };
    if right.contains("count=") {
        for part in right.split(',') {
            let part = part.trim();
            if let Some(value) = part.strip_prefix("count=") {
                map.insert(format!("{name}.{scope}.count"), value.trim().to_string());
            } else if let Some(value) = part.strip_prefix("attach_flags=") {
                map.insert(
                    format!("{name}.{scope}.attach_flags"),
                    value.trim().to_string(),
                );
            }
        }
        return;
    }
    if let Some((index, value)) = left.split_once('[') {
        let Some((name, scope)) = index.split_once('.') else {
            return;
        };
        let Some(prog_id) = right.trim().strip_prefix("prog_id=") else {
            return;
        };
        let key = format!("{name}.{scope}.prog_ids");
        let existing = map.get(&key).cloned().unwrap_or_default();
        let suffix = value.trim_end_matches(']');
        let item = format!("{suffix}:{}", prog_id.trim());
        map.insert(
            key,
            if existing.is_empty() {
                item
            } else {
                format!("{existing},{item}")
            },
        );
    }
}

fn singbox_ports(app: &App) -> (String, String) {
    let text =
        fs::read_to_string(app.moddir.join(".config/sing-box/config.json")).unwrap_or_default();
    let json: serde_json::Value = match serde_json::from_str(&text) {
        Ok(json) => json,
        Err(_) => return ("unknown".to_string(), "1053".to_string()),
    };
    let mixed = json
        .get("inbounds")
        .and_then(|value| value.as_array())
        .and_then(|inbounds| {
            inbounds.iter().find_map(|inbound| {
                let kind = inbound.get("type").and_then(|value| value.as_str())?;
                if kind != "mixed" {
                    return None;
                }
                inbound.get("listen_port").and_then(|value| value.as_u64())
            })
        })
        .map(|port| port.to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let dns = json
        .get("inbounds")
        .and_then(|value| value.as_array())
        .and_then(|inbounds| {
            inbounds.iter().find_map(|inbound| {
                let tag = inbound.get("tag").and_then(|value| value.as_str())?;
                if tag != "magicnet-ebpf-dns4-in" && tag != "magicnet-ebpf-dns6-in" {
                    return None;
                }
                inbound.get("listen_port").and_then(|value| value.as_u64())
            })
        })
        .map(|port| port.to_string())
        .unwrap_or_else(|| "1053".to_string());
    (mixed, dns)
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
