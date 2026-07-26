use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{read_kv, App};

const DEFAULT_BIND: &str = "127.0.0.1";
const DEFAULT_PORT: &str = "8766";
const MAX_SECRET_BYTES: usize = 256;
const MCP_CONF: &str = ".config/magicnet/mcp.conf";

#[derive(Clone, Debug, PartialEq, Eq)]
struct McpConfig {
    enabled: bool,
    bind: IpAddr,
    port: u16,
    secret: String,
}

impl Default for McpConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            bind: IpAddr::V4(Ipv4Addr::LOCALHOST),
            port: DEFAULT_PORT.parse().expect("default MCP port is valid"),
            secret: String::new(),
        }
    }
}

impl McpConfig {
    fn from_fields(enabled: &str, bind: &str, port: &str, secret: &str) -> Result<Self, String> {
        Ok(Self {
            enabled: parse_enabled(enabled)?,
            bind: parse_bind(bind)?,
            port: parse_port(port)?,
            secret: validate_secret(secret)?.to_string(),
        })
    }

    fn address(&self) -> SocketAddr {
        SocketAddr::new(self.bind, self.port)
    }

    fn url(&self) -> String {
        format!("http://{}/mcp", self.address())
    }

    fn enabled_value(&self) -> &'static str {
        if self.enabled {
            "1"
        } else {
            "0"
        }
    }

    fn validate_for_write(&self) -> Result<(), String> {
        // Every field is checked at the write sink. The first three are typed
        // in memory, while the secret remains shell-sensitive text.
        parse_enabled(self.enabled_value())?;
        parse_bind(&self.bind.to_string())?;
        parse_port(&self.port.to_string())?;
        validate_secret(&self.secret)?;
        Ok(())
    }
}

pub(crate) fn mcp(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            let config = load(app);
            println!("enabled={}", config.enabled_value());
            println!("bind={}", config.bind);
            println!("port={}", config.port);
            println!("secret_set={}", (!config.secret.is_empty()) as u8);
            if let Some(pid) = live_pid(pid_path(app)) {
                println!("pid={pid}");
                println!("url={}", config.url());
            } else {
                println!("pid=stopped");
                if let Some(owner) = port_owner(config.address()) {
                    println!("port_owner={owner}");
                }
            }
            Ok(())
        }
        "enable" => {
            let mut config = load(app);
            config.enabled = true;
            apply_endpoint_args(&mut config, args)?;
            ensure_secret(&mut config);
            write_conf(app, &config)?;
            start(app)
        }
        "disable" => {
            let mut config = load(app);
            config.enabled = false;
            write_conf(app, &config)?;
            stop(app)
        }
        "set" => {
            let mut config = load(app);
            apply_endpoint_args(&mut config, args)?;
            ensure_secret(&mut config);
            write_conf(app, &config)?;
            println!("[info] MCP endpoint set: {}", config.url());
            Ok(())
        }
        "secret" => {
            let mut config = load(app);
            ensure_secret(&mut config);
            write_conf(app, &config)?;
            println!("{}", config.secret);
            Ok(())
        }
        "rotate-secret" => {
            let mut config = load(app);
            config.secret = generate_secret();
            write_conf(app, &config)?;
            if live_pid(pid_path(app)).is_some() {
                let _ = stop(app);
                start(app)?;
            }
            println!("[info] MCP secret rotated");
            Ok(())
        }
        "start" => start(app),
        "stop" => stop(app),
        "restart" => {
            let _ = stop(app);
            start(app)
        }
        "logs" => {
            let lines = args
                .get(1)
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(120);
            print_log_tail(app, "mcp-server.log", lines)
        }
        _ => Err("Usage: cli mcp {status|enable [bind] [port]|disable|set [bind] [port]|secret|rotate-secret|start|stop|restart|logs [lines]}".to_string()),
    }
}

pub(crate) fn status(app: &App) -> (String, String, String, String) {
    let config = load(app);
    let pid = live_pid(pid_path(app))
        .map(|value| value.to_string())
        .unwrap_or_else(|| "stopped".to_string());
    (
        config.enabled_value().to_string(),
        config.bind.to_string(),
        config.port.to_string(),
        pid,
    )
}

fn conf_path(app: &App) -> PathBuf {
    app.moddir.join(MCP_CONF)
}

fn pid_path(app: &App) -> PathBuf {
    env::var("KAM_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| app.moddir.clone())
        .join(".state/magicnet-mcp.pid")
}

fn load(app: &App) -> McpConfig {
    load_config(&read_kv(conf_path(app)))
}

fn load_config(conf: &HashMap<String, String>) -> McpConfig {
    // Legacy values are untrusted because mcp.conf is shell-sourced. A single
    // malformed field yields a fully safe, deterministic configuration rather
    // than being copied into the next write.
    McpConfig::from_fields(
        conf.get("MAGICNET_MCP_ENABLED")
            .map(String::as_str)
            .unwrap_or("0"),
        conf.get("MAGICNET_MCP_BIND")
            .map(String::as_str)
            .unwrap_or(DEFAULT_BIND),
        conf.get("MAGICNET_MCP_PORT")
            .map(String::as_str)
            .unwrap_or(DEFAULT_PORT),
        conf.get("MAGICNET_MCP_SECRET")
            .map(String::as_str)
            .unwrap_or_default(),
    )
    .unwrap_or_default()
}

fn write_conf(app: &App, config: &McpConfig) -> Result<(), String> {
    config.validate_for_write()?;
    crate::write_secret_file(
        app,
        Path::new(MCP_CONF),
        &format!(
            "MAGICNET_MCP_ENABLED={}\nMAGICNET_MCP_BIND={}\nMAGICNET_MCP_PORT={}\nMAGICNET_MCP_SECRET={}\n",
            config.enabled_value(),
            config.bind,
            config.port,
            config.secret
        ),
    )
}

fn start(app: &App) -> Result<(), String> {
    let mut config = load(app);
    ensure_secret(&mut config);
    // Persist only the sanitized typed configuration. This also repairs a
    // legacy unsafe mcp.conf before the server is launched.
    write_conf(app, &config)?;
    if let Some(pid) = live_pid(pid_path(app)) {
        println!("[info] MCP server already running: {pid}");
        return mcp(app, &[String::from("status")]);
    }
    let address = config.address();
    if let Err(err) = TcpListener::bind(address) {
        let owner = port_owner(address).unwrap_or_else(|| "unknown owner".to_string());
        return Err(format!("MCP port unavailable: {address}: {err}; {owner}",));
    }
    let target = app.moddir.join("bin/magicnet-mcp-server");
    if !target.exists() {
        return Err(format!("MCP server missing: {}", target.display()));
    }
    fs::create_dir_all(app.log_dir.clone()).map_err(|err| format!("mkdir log dir: {err}"))?;
    if let Some(parent) = pid_path(app).parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir state dir: {err}"))?;
    }
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(app.log_dir.join("mcp-server.log"))
        .map_err(|err| format!("open mcp log: {err}"))?;
    let log_err = log
        .try_clone()
        .map_err(|err| format!("clone mcp log: {err}"))?;
    let child = Command::new(&target)
        .env("MODDIR", &app.moddir)
        .env("MAGICNET_MCP_BIND", config.bind.to_string())
        .env("MAGICNET_MCP_PORT", config.port.to_string())
        .env("MAGICNET_MCP_SECRET", &config.secret)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
        .map_err(|err| format!("start MCP server: {err}"))?;
    let pid = child.id();
    fs::write(pid_path(app), format!("{pid}\n")).map_err(|err| format!("write pid: {err}"))?;
    thread::sleep(Duration::from_millis(350));
    if Path::new("/proc").join(pid.to_string()).exists() {
        println!("[info] MCP server started: {}", config.url());
        Ok(())
    } else {
        Err(format!(
            "MCP server failed to start; see {}",
            app.log_dir.join("mcp-server.log").display()
        ))
    }
}

fn apply_endpoint_args(config: &mut McpConfig, args: &[String]) -> Result<(), String> {
    if let Some(bind) = args.get(1) {
        config.bind = parse_bind(bind)?;
    }
    if let Some(port) = args.get(2) {
        config.port = parse_port(port)?;
    }
    Ok(())
}

fn ensure_secret(config: &mut McpConfig) {
    if config.secret.is_empty() {
        config.secret = generate_secret();
    }
}

fn generate_secret() -> String {
    let mut bytes = [0_u8; 32];
    if fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .is_err()
    {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or_default();
        bytes[..16].copy_from_slice(&nanos.to_le_bytes());
        bytes[16..24].copy_from_slice(&(std::process::id() as u64).to_le_bytes());
        bytes[24..32].copy_from_slice(&(conf_path_fallback_hash() as u64).to_le_bytes());
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn conf_path_fallback_hash() -> usize {
    let text = format!(
        "{:?}{:?}",
        env::current_exe().ok(),
        env::args().collect::<Vec<_>>()
    );
    text.bytes().fold(0usize, |acc, byte| {
        acc.wrapping_mul(131).wrapping_add(byte as usize)
    })
}

fn stop(app: &App) -> Result<(), String> {
    if let Some(pid) = live_pid(pid_path(app)) {
        let _ = Command::new("kill").arg(pid.to_string()).status();
        thread::sleep(Duration::from_millis(250));
        if Path::new("/proc").join(pid.to_string()).exists() {
            let _ = Command::new("kill").arg("-9").arg(pid.to_string()).status();
        }
    }
    let _ = fs::remove_file(pid_path(app));
    println!("[info] MCP server stopped");
    Ok(())
}

fn live_pid(pid_file: PathBuf) -> Option<i32> {
    let text = fs::read_to_string(pid_file).ok()?;
    let pid = text.trim().parse::<i32>().ok()?;
    let proc_dir = Path::new("/proc").join(pid.to_string());
    if !proc_dir.exists() {
        return None;
    }
    let cmdline = fs::read(proc_dir.join("cmdline")).unwrap_or_default();
    let cmdline = String::from_utf8_lossy(&cmdline).replace('\0', " ");
    if cmdline.contains("magicnet-mcp-server") {
        return Some(pid);
    }
    let exe = fs::read_link(proc_dir.join("exe"))
        .ok()
        .map(|path| path.display().to_string())
        .unwrap_or_default();
    exe.contains("magicnet-mcp-server").then_some(pid)
}

fn parse_enabled(enabled: &str) -> Result<bool, String> {
    match enabled {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err("invalid MCP enabled value".to_string()),
    }
}

fn parse_port(port: &str) -> Result<u16, String> {
    match port.parse::<u16>() {
        Ok(0) | Err(_) => Err("invalid MCP port".to_string()),
        Ok(port) => Ok(port),
    }
}

/// `bind` is written unquoted into the `.`-sourced `mcp.conf`, so it must be a
/// bare IP literal — that leaves no room for shell metacharacters to smuggle a
/// command that would run as root when the conf is sourced at boot.
fn parse_bind(bind: &str) -> Result<IpAddr, String> {
    bind.parse::<std::net::IpAddr>()
        .map_err(|_| "invalid MCP bind address (expected an IP literal)".to_string())
}

fn validate_secret(secret: &str) -> Result<&str, String> {
    if secret.len() <= MAX_SECRET_BYTES && crate::shell_inert_conf_value(secret) {
        Ok(secret)
    } else {
        Err("invalid MCP secret".to_string())
    }
}

fn port_owner(address: SocketAddr) -> Option<String> {
    let output = Command::new("ss").arg("-lntp").output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let bind = address.ip().to_string();
    let needle = format!(":{}", address.port());
    text.lines()
        .find(|line| {
            line.contains(&needle)
                && (line.contains(&bind)
                    || address.ip().is_unspecified()
                    || line.contains("0.0.0.0")
                    || line.contains("[::]"))
        })
        .map(|line| line.trim().to_string())
}

fn print_log_tail(app: &App, file_name: &str, lines: usize) -> Result<(), String> {
    let file = app.log_dir.join(file_name);
    let text = fs::read_to_string(&file)
        .map_err(|err| format!("log not found {}: {err}", file.display()))?;
    let lines = lines.clamp(1, 1000);
    let all = text.lines().collect::<Vec<_>>();
    let start = all.len().saturating_sub(lines);
    for line in &all[start..] {
        println!("{line}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipv6_endpoint_uses_a_socket_address_and_bracketed_url() {
        let config = McpConfig::from_fields("1", "::1", "8766", "safe-secret").unwrap();

        assert_eq!(config.address().to_string(), "[::1]:8766");
        assert_eq!(config.url(), "http://[::1]:8766/mcp");
    }

    #[test]
    fn sourced_mcp_conf_rejects_unsafe_fields() {
        assert!(McpConfig::from_fields("enabled", "127.0.0.1", "8766", "safe").is_err());
        assert!(McpConfig::from_fields("1", "localhost", "8766", "safe").is_err());
        assert!(McpConfig::from_fields("1", "127.0.0.1", "0", "safe").is_err());
        assert!(McpConfig::from_fields("1", "127.0.0.1", "8766", "unsafe;command").is_err());
    }

    #[test]
    fn unsafe_legacy_config_recovers_to_safe_defaults() {
        let conf = HashMap::from([
            ("MAGICNET_MCP_ENABLED".to_string(), "yes".to_string()),
            (
                "MAGICNET_MCP_BIND".to_string(),
                "127.0.0.1$(command)".to_string(),
            ),
            ("MAGICNET_MCP_PORT".to_string(), "0".to_string()),
            (
                "MAGICNET_MCP_SECRET".to_string(),
                "unsafe;command".to_string(),
            ),
        ]);

        assert_eq!(load_config(&conf), McpConfig::default());
    }
}
