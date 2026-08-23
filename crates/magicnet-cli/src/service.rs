use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::{
    diagnostics::supervisor_pid, run_magicnet_function, singbox_pid_summary, stop_owned_singbox,
    write_text_file, App,
};

const START_SUPERVISORS_COMMAND: &str = "magicnet_supervisors_start_detached";
const START_KERNEL_COMMAND: &str =
    "MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2 magicnet_start_kernel && magicnet_supervisors_start_detached";
const STOP_RUNTIME_CLEANUP_COMMAND: &str = r#"[ "${MAGICNET_PRESERVE_HOTSPOT_WATCHDOG:-0}" = 1 ] || magicnet_hotspot_watchdog_stop >/dev/null 2>&1 || true; magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true; magicnet_disable_dns_capture || true; magicnet_disable_dns_leak_guard || true"#;
const REPAIR_COMMAND: &str =
    "magicnet_apply_runtime_config; MAGICNET_ALLOW_DISRUPTIVE_RECOVERY=1 magicnet_ensure_kernel";
const SELECTED_CORE_CONF: &str = ".config/magicnet/current-core.conf";
const TRANSPARENT_MODE_CONF: &str = ".config/magicnet/transparent-mode.conf";
const CONFIG_APPLY_LOCK: &str = ".state/config-apply.lock";
const LIFECYCLE_LOCK_TIMEOUT: Duration = Duration::from_secs(2);
const CONFIG_LOCK_POLL_INTERVAL: Duration = Duration::from_millis(25);
const MAX_SERVICE_LOG_READ_BYTES: u64 = 1024 * 1024;

struct ConfigApplyGuard(fs::File);

impl Drop for ConfigApplyGuard {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn open_config_apply_lock(app: &App) -> Result<File, String> {
    let path = app.moddir.join(CONFIG_APPLY_LOCK);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("create config apply lock directory: {err}"))?;
    }
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .map_err(|err| format!("open config apply lock: {err}"))
}

fn config_apply_lock(app: &App) -> Result<ConfigApplyGuard, String> {
    let file = open_config_apply_lock(app)?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(format!(
            "lock config apply: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(ConfigApplyGuard(file))
}

fn config_apply_lock_bounded(app: &App, timeout: Duration) -> Result<ConfigApplyGuard, String> {
    let file = open_config_apply_lock(app)?;
    let deadline = Instant::now() + timeout;
    loop {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(ConfigApplyGuard(file));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::WouldBlock {
            return Err(format!("lock config apply: {error}"));
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(format!(
                "config apply is still busy after {} ms; retry the lifecycle action",
                timeout.as_millis()
            ));
        }
        thread::sleep(CONFIG_LOCK_POLL_INTERVAL.min(deadline.saturating_duration_since(now)));
    }
}

pub(crate) fn service_status(app: &App) {
    let singbox = singbox_pid_summary(app);
    println!("MagicNet");
    println!("  sing-box: {singbox}");
    println!(
        "  fswatch:  {}",
        supervisor_pid(app, "fswatch", "magicnet-config")
    );
    println!(
        "  Wi-Fi policy: {}",
        supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy")
    );
    println!("  Selected: {}", selected_core(app));
    println!("  Transparent: {}", transparent_mode(app));
    println!("  API:      {}", app.api);
    println!("  WebUI:    {}", singbox_webui(app));
    let local_source = app.moddir.join(".config/sing-box/subscription.local");
    if fs::metadata(&local_source)
        .map(|metadata| metadata.len() > 0)
        .unwrap_or(false)
    {
        println!("  Sub source: local file");
    } else {
        println!(
            "  Sub source: {}",
            app.moddir
                .join(".config/sing-box/subscription.url")
                .display()
        );
    }
}

pub(crate) fn singbox_webui(app: &App) -> String {
    let ui = fs::read_to_string(app.moddir.join(".config/sing-box/config.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|config| {
            config
                .pointer("/experimental/clash_api/external_ui")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "ui".to_string());
    let (hostname, port) = api_host_port(&app.api);
    format!(
        "{}/{}/#/setup?hostname={hostname}&port={port}",
        app.api,
        ui.trim_matches('/')
    )
}

fn api_host_port(api: &str) -> (String, String) {
    let authority = api.strip_prefix("http://").unwrap_or_default();
    if let Some(rest) = authority.strip_prefix('[') {
        if let Some((host, port)) = rest.split_once("]:") {
            return (host.to_string(), port.to_string());
        }
    } else if let Some((host, port)) = authority.rsplit_once(':') {
        if !host.contains(':') {
            return (host.to_string(), port.to_string());
        }
    }
    ("127.0.0.1".to_string(), "9090".to_string())
}

pub(crate) fn service_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            service_status(app);
            Ok(())
        }
        "start" => start_service(app),
        "ensure" => run_magicnet_function(app, "magicnet_ensure_kernel"),
        "stop" => stop_service(app),
        "restart" => restart(app, args.get(1).map(String::as_str).unwrap_or("current")),
        "toggle" => match args.get(1).map(String::as_str).unwrap_or_default() {
            "sing-box" | "singbox" => {
                if singbox_pid_summary(app) == "stopped" {
                    start_service(app)
                } else {
                    stop_service(app)
                }
            }
            _ => Err("Usage: cli service toggle sing-box".to_string()),
        },
        _ => Err("Usage: cli service {status|start|ensure|stop|restart [current|sing-box]|toggle sing-box|logs [core] [lines]}".to_string()),
    }
}

fn start_service(app: &App) -> Result<(), String> {
    let _config_apply_guard = config_apply_lock_bounded(app, LIFECYCLE_LOCK_TIMEOUT)?;
    run_magicnet_function(app, START_KERNEL_COMMAND)
}

fn stop_service(app: &App) -> Result<(), String> {
    // A user-requested stop takes precedence over an fswatch apply.  Stop the
    // producer and its current worker before waiting for the process lock;
    // otherwise a lifecycle button can sit behind a full config restart.
    quiesce_config_apply(app);
    let _config_apply_guard = config_apply_lock_bounded(app, LIFECYCLE_LOCK_TIMEOUT)?;
    stop_all_direct(app, false, false)
}

fn quiesce_config_apply(app: &App) {
    stop_supervisor_pidfile(app, app.moddir.join(".state/fswatch/magicnet-config.pid"));
    ignore_command(
        "pkill",
        &["-f", &format!("{}/cli.*config apply", app.moddir.display())],
    );
}

pub(crate) fn supervisor_cmd(app: &App, args: &[String]) -> Result<(), String> {
    let action = args.first().map(String::as_str).unwrap_or("status");
    let target = args.get(1).map(String::as_str).unwrap_or("all");
    match action {
        "status" => {
            if matches!(target, "all" | "fswatch") {
                println!(
                    "fswatch={}",
                    supervisor_pid(app, "fswatch", "magicnet-config")
                );
            }
            if matches!(target, "all" | "wifi-policy") {
                println!(
                    "wifi-policy={}",
                    supervisor_pid(app, "wifi-policy", "magicnet-wifi-policy")
                );
            }
            Ok(())
        }
        "start" => supervisor_target(app, target, "start"),
        "stop" => supervisor_target(app, target, "stop"),
        "restart" => supervisor_target(app, target, "restart"),
        _ => Err(
            "Usage: cli supervisor {status|start|stop|restart} [fswatch|wifi-policy|all]"
                .to_string(),
        ),
    }
}

pub(crate) fn config_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or_default() {
        "apply" => apply_config(app),
        _ => Err("Usage: cli config apply".to_string()),
    }
}

pub(crate) fn apply_config(app: &App) -> Result<(), String> {
    apply_config_with_options(app, false)
}

pub(crate) fn apply_config_preserving_hotspot_watchdog(app: &App) -> Result<(), String> {
    apply_config_with_options(app, true)
}

fn apply_config_with_options(app: &App, preserve_hotspot_watchdog: bool) -> Result<(), String> {
    // Runtime materialization and the following core restart are one logical
    // operation.  The shell config lock only covers the writers themselves;
    // without this process-level guard two fswatch/WebUI invocations can both
    // pass that lock and then interleave stop/start, leaving DNS/TUN rules
    // attached to different core generations.
    let _config_apply_guard = config_apply_lock(app)?;
    run_magicnet_function(app, ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; if magicnet_singbox_update_lock_active; then echo '[error] subscription update in progress' >&2; false; else magicnet_apply_runtime_config; fi")?;

    // sing-box snapshots config.json and local rule sets at startup.  Restart
    // only when those effective inputs changed.  Fswatch may invoke this for
    // unrelated files under .config; an unconditional restart tears down
    // background mail/message sockets even when the running policy is already
    // current.  A missing or unreadable fingerprint remains fail-safe and
    // takes the restart path.
    if singbox_pid_summary(app) != "stopped" {
        let runtime_unchanged =
            run_magicnet_function(app, "magicnet_singbox_runtime_fingerprint_matches").is_ok();
        if !runtime_unchanged {
            restart_current_core_preserving_config_apply(app, preserve_hotspot_watchdog)?;
        }
    }
    Ok(())
}

pub(crate) fn transparent_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            println!("mode={}", transparent_mode(app));
            Ok(())
        }
        "set" => transparent_set(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "apply" => {
            run_magicnet_function(app, "magicnet_transparent_apply")?;
            restart_current_core(app)
        }
        _ => Err(transparent_usage()),
    }
}

pub(crate) fn core_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            core_status(app);
            Ok(())
        }
        "selected" => {
            println!("{}", selected_core(app));
            Ok(())
        }
        "select" => select_core(app, args.get(1).map(String::as_str).unwrap_or_default()),
        _ => Err("Usage: cli core {status|selected|select sing-box}".to_string()),
    }
}

pub(crate) fn repair(app: &App) -> Result<(), String> {
    run_magicnet_function(app, REPAIR_COMMAND)
}

pub(crate) fn service_logs(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or("sing-box");
    let lines = args
        .get(3)
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(120);
    let file = match service_log_path(app, target) {
        Ok(file) => file,
        Err(error) if error.starts_with("log file unavailable:") => {
            println!("[info] no log available yet for target={target}");
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    let text = read_bounded_log_tail(&file)
        .map_err(|err| format!("log not found {}: {err}", file.display()))?;
    for line in tail_lines(&text, lines.clamp(1, 1000)) {
        println!("{line}");
    }
    Ok(())
}

fn latest_webui_log_path(log_root: &Path) -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    for entry in fs::read_dir(log_root).map_err(|err| format!("log file unavailable: {err}"))? {
        let entry = entry.map_err(|err| format!("log file unavailable: {err}"))?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if !name.starts_with("webui-") || !name.ends_with(".log") {
            continue;
        }
        let file_type = entry
            .file_type()
            .map_err(|err| format!("log file unavailable: {err}"))?;
        if !file_type.is_file() {
            continue;
        }
        let modified = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .unwrap_or(std::time::UNIX_EPOCH);
        candidates.push((modified, entry.path()));
    }
    candidates
        .into_iter()
        .max_by(|left, right| left.cmp(right))
        .map(|(_, path)| path)
        .ok_or_else(|| "log file unavailable: no WebUI task logs".to_string())
}

fn service_log_path(app: &App, target: &str) -> Result<PathBuf, String> {
    let target = if target.trim().is_empty() {
        "sing-box"
    } else {
        target.trim()
    };
    let name = match target {
        "webui" | "background" => None,
        "sing-box" | "singbox" | "core" => Some("sing-box.log".to_string()),
        "mcp" | "mcp-server" => Some("mcp-server.log".to_string()),
        "fswatch" => Some("fswatch.log".to_string()),
        "kernel" => Some("magicnet-kernel.log".to_string()),
        "service" => Some("service.log".to_string()),
        other if safe_log_name(other) => Some(if other.ends_with(".log") {
            other.to_string()
        } else {
            format!("{other}.log")
        }),
        _ => return Err("invalid service log target".to_string()),
    };

    let module_root =
        fs::canonicalize(&app.moddir).map_err(|err| format!("module root unavailable: {err}"))?;
    let log_root = fs::canonicalize(&app.log_dir)
        .map_err(|err| format!("log directory unavailable: {err}"))?;
    if !log_root.starts_with(&module_root) || !log_root.is_dir() {
        return Err("log directory escapes module directory".to_string());
    }
    let requested = match name {
        Some(name) => log_root.join(name),
        None => latest_webui_log_path(&log_root)?,
    };
    let resolved =
        fs::canonicalize(&requested).map_err(|err| format!("log file unavailable: {err}"))?;
    if !resolved.starts_with(&log_root) || !resolved.is_file() {
        return Err("log file escapes module log directory".to_string());
    }
    Ok(resolved)
}

fn safe_log_name(value: &str) -> bool {
    !value.is_empty()
        && !value.contains("..")
        && !value.contains('/')
        && !value.contains('\\')
        && value
            .chars()
            .all(|char| char.is_ascii_alphanumeric() || matches!(char, '-' | '_' | '.'))
}

fn read_bounded_log_tail(path: &Path) -> std::io::Result<String> {
    let mut file = File::open(path)?;
    let length = file.metadata()?.len();
    let start = length.saturating_sub(MAX_SERVICE_LOG_READ_BYTES);
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::with_capacity((length - start) as usize);
    file.read_to_end(&mut bytes)?;
    if start > 0 {
        if let Some(index) = bytes.iter().position(|byte| *byte == b'\n') {
            bytes.drain(..=index);
        }
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn restart(app: &App, target: &str) -> Result<(), String> {
    quiesce_config_apply(app);
    let _config_apply_guard = config_apply_lock_bounded(app, LIFECYCLE_LOCK_TIMEOUT)?;
    restart_with_options_unlocked(app, target, false, false)
}

pub(crate) fn restart_current_core(app: &App) -> Result<(), String> {
    restart(app, "current")
}

fn restart_current_core_preserving_config_apply(
    app: &App,
    preserve_hotspot_watchdog: bool,
) -> Result<(), String> {
    restart_with_options_unlocked(app, "current", true, preserve_hotspot_watchdog)
}

fn restart_with_options_unlocked(
    app: &App,
    target: &str,
    preserve_config_apply: bool,
    preserve_hotspot_watchdog: bool,
) -> Result<(), String> {
    stop_all_direct(app, preserve_config_apply, preserve_hotspot_watchdog)?;
    let target = if target == "current" {
        selected_core(app)
    } else {
        target.to_string()
    };
    if !matches!(target.as_str(), "sing-box" | "singbox") {
        return Err("Usage: cli service restart [current|sing-box]".to_string());
    }
    run_magicnet_function(app, restart_command(target.as_str()))
}

fn restart_command(target: &str) -> &'static str {
    match target {
        "sing-box" | "singbox" => {
            "MAGICNET_DEFAULT_CORE=sing-box MAGICNET_STRICT_CORE=1 MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2 magicnet_start_kernel && magicnet_supervisors_start_detached"
        }
        _ => unreachable!("restart validates the target before building the command"),
    }
}

fn stop_all_direct(
    app: &App,
    preserve_config_apply: bool,
    preserve_hotspot_watchdog: bool,
) -> Result<(), String> {
    stop_supervisor_pidfile(app, app.moddir.join(".state/watchdog/magicnet-kernel.pid"));
    if !preserve_hotspot_watchdog {
        stop_supervisor_pidfile(
            app,
            app.moddir
                .join(".state/watchdog/magicnet-hotspot-route.pid"),
        );
    }
    stop_supervisor_pidfile(app, app.moddir.join(".state/fswatch/magicnet-config.pid"));
    stop_supervisor_pidfile(app, app.moddir.join(".state/after-kernel-start.pid"));
    ignore_command(
        "pkill",
        &[
            "-f",
            &format!("{}/cli.*supervisor start all", app.moddir.display()),
        ],
    );
    ignore_command(
        "pkill",
        &[
            "-f",
            &format!("{}/cli.*service ensure", app.moddir.display()),
        ],
    );
    // `config apply` can be the command currently performing this restart
    // (fswatch invokes it after a config change).  Killing every matching
    // command would kill the caller before it can launch the new core.  The
    // watcher pidfile is already stopped above; leave this command alive only
    // for that bounded restart path.
    if !preserve_config_apply {
        ignore_command(
            "pkill",
            &["-f", &format!("{}/cli.*config apply", app.moddir.display())],
        );
    }
    ignore_command(
        "pkill",
        &["-f", &format!("{}/cli wifi watch", app.moddir.display())],
    );
    ignore_command(
        "pkill",
        &[
            "-f",
            &format!("{}/bin/magicnet-cli wifi watch", app.moddir.display()),
        ],
    );
    let _ = fs::remove_file(
        app.moddir
            .join(".state/wifi-policy/magicnet-wifi-policy.pid"),
    );
    // Only stop the sing-box process launched from this module. A separate
    // VPN/core may legitimately use the same process name and must survive a
    // MagicNet stop/restart.
    stop_owned_singbox(app);
    let cleanup_command = if preserve_hotspot_watchdog {
        format!(
            "MAGICNET_PRESERVE_HOTSPOT_WATCHDOG=1 {}",
            stop_runtime_cleanup_command()
        )
    } else {
        stop_runtime_cleanup_command().to_string()
    };
    run_magicnet_function(app, &cleanup_command)?;
    Ok(())
}

fn stop_runtime_cleanup_command() -> &'static str {
    STOP_RUNTIME_CLEANUP_COMMAND
}

fn stop_supervisor_pidfile(app: &App, path: PathBuf) {
    if let Ok(text) = fs::read_to_string(&path) {
        if let Ok(pid) = text.trim().parse::<u32>() {
            if supervisor_pidfile_matches(app, &path, pid) {
                ignore_command("kill", &[&pid.to_string()]);
            }
        }
    }
    let _ = fs::remove_file(path);
}

fn supervisor_pidfile_matches(app: &App, path: &Path, pid: u32) -> bool {
    let cmdline = fs::read(format!("/proc/{pid}/cmdline"))
        .ok()
        .map(|bytes| String::from_utf8_lossy(&bytes).replace('\0', " "))
        .unwrap_or_default();
    supervisor_cmdline_matches(&app.moddir, path, &cmdline)
}

fn supervisor_cmdline_matches(moddir: &Path, path: &Path, cmdline: &str) -> bool {
    let module = moddir.to_string_lossy();
    match path.file_name().and_then(|name| name.to_str()) {
        Some("magicnet-kernel.pid") => {
            cmdline_has_script(
                cmdline,
                &format!("{module}/.state/watchdog/magicnet-kernel.loop.sh"),
            ) || cmdline_has_module_command(cmdline, &module, &["service", "ensure"])
        }
        Some("magicnet-config.pid") => {
            cmdline_has_script(
                cmdline,
                &format!("{module}/.state/fswatch/magicnet-config.loop.sh"),
            ) || cmdline_has_module_command(cmdline, &module, &["config", "apply"])
        }
        Some("magicnet-hotspot-route.pid") => cmdline_has_script(
            cmdline,
            &format!("{module}/.state/watchdog/magicnet-hotspot-route.loop.sh"),
        ),
        // There is no current producer for this legacy pidfile.  Requiring a
        // known command is safer than killing a reused PID from old state.
        Some("after-kernel-start.pid") => false,
        _ => false,
    }
}

fn cmdline_has_script(cmdline: &str, script: &str) -> bool {
    cmdline
        .split_whitespace()
        .collect::<Vec<_>>()
        .windows(2)
        .any(|pair| {
            matches!(
                pair[0].rsplit('/').next(),
                Some("sh" | "ash" | "dash" | "bash" | "ksh" | "mksh")
            ) && pair[1] == script
        })
}

fn cmdline_has_module_command(cmdline: &str, module: &str, args: &[&str]) -> bool {
    let tokens = cmdline.split_whitespace().collect::<Vec<_>>();
    tokens.windows(args.len() + 1).any(|window| {
        window[0] == format!("{module}/cli") && window[1..].iter().copied().eq(args.iter().copied())
    })
}

fn ignore_command(program: &str, args: &[&str]) {
    let _ = Command::new(program).args(args).status();
}

fn supervisor_target(app: &App, target: &str, action: &str) -> Result<(), String> {
    match (target, action) {
        ("all", "start") => run_magicnet_function(app, "magicnet_supervisors_start"),
        ("all", "stop") => run_magicnet_function(app, "magicnet_supervisors_stop"),
        ("all", "restart") => {
            run_magicnet_function(app, "magicnet_supervisors_stop; magicnet_supervisors_start")
        }
        ("fswatch", "start") => run_magicnet_function(app, "magicnet_fswatch_start"),
        ("fswatch", "stop") => run_magicnet_function(app, "magicnet_fswatch_stop"),
        ("fswatch", "restart") => {
            run_magicnet_function(app, "magicnet_fswatch_stop; magicnet_fswatch_start")
        }
        ("wifi-policy", "start") => run_magicnet_function(app, "magicnet_wifi_policy_start"),
        ("wifi-policy", "stop") => run_magicnet_function(app, "magicnet_wifi_policy_stop"),
        ("wifi-policy", "restart") => {
            run_magicnet_function(app, "magicnet_wifi_policy_stop; magicnet_wifi_policy_start")
        }
        _ => Err(
            "Usage: cli supervisor {status|start|stop|restart} [fswatch|wifi-policy|all]"
                .to_string(),
        ),
    }
}

fn select_core(app: &App, core: &str) -> Result<(), String> {
    let normalized = match core {
        "sing-box" | "singbox" => "sing-box",
        _ => return Err("Usage: cli core select sing-box".to_string()),
    };
    write_text_file(
        app,
        Path::new(SELECTED_CORE_CONF),
        &format!("MAGICNET_DEFAULT_CORE={normalized}\n"),
    )?;
    println!("[info] 默认核心已设为: {normalized}");
    Ok(())
}

fn transparent_set(app: &App, mode: &str) -> Result<(), String> {
    let mode = normalize_transparent_mode(mode)?;
    let _config_apply_guard = config_apply_lock(app)?;
    write_transparent_mode(app, mode)?;
    stop_all_direct(app, false, false)?;
    run_magicnet_function(app, "magicnet_transparent_apply")?;
    run_magicnet_function(app, "magicnet_start_kernel")?;
    start_supervisors(app)?;
    println!("[info] Transparent mode set to {mode}");
    Ok(())
}

fn normalize_transparent_mode(mode: &str) -> Result<&'static str, String> {
    match mode {
        "tun" => Ok("tun"),
        _ => Err("Usage: cli transparent set tun".to_string()),
    }
}

fn start_supervisors(app: &App) -> Result<(), String> {
    run_magicnet_function(app, START_SUPERVISORS_COMMAND)
}

fn write_transparent_mode(app: &App, mode: &str) -> Result<(), String> {
    write_text_file(
        app,
        Path::new(TRANSPARENT_MODE_CONF),
        &format!("MAGICNET_TRANSPARENT_MODE={mode}\n"),
    )
}

fn transparent_mode(app: &App) -> String {
    fs::read_to_string(app.moddir.join(TRANSPARENT_MODE_CONF))
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let (_, value) = line.split_once('=')?;
                match value.trim().trim_matches('"').trim_matches('\'') {
                    "proxy" | "external" | "external-tun" | "hybrid" => Some("tun".to_string()),
                    "tun" => Some("tun".to_string()),
                    _ => None,
                }
            })
        })
        .unwrap_or_else(|| "tun".to_string())
}

fn transparent_usage() -> String {
    "Usage: cli transparent {status|set tun|apply}".to_string()
}

fn core_status(app: &App) {
    println!("selected={}", selected_core(app));
}

fn selected_core(app: &App) -> String {
    fs::read_to_string(selected_core_path(app))
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let (_, value) = line.split_once('=')?;
                match value.trim().trim_matches('"').trim_matches('\'') {
                    "sing-box" | "singbox" => Some("sing-box".to_string()),
                    _ => None,
                }
            })
        })
        .unwrap_or_else(|| "sing-box".to_string())
}

fn selected_core_path(app: &App) -> PathBuf {
    app.moddir.join(SELECTED_CORE_CONF)
}

fn tail_lines(text: &str, lines: usize) -> Vec<&str> {
    let all: Vec<&str> = text.lines().collect();
    let start = all.len().saturating_sub(lines);
    all[start..].to_vec()
}

#[cfg(test)]
mod tests {
    use super::{
        api_host_port, config_apply_lock, config_apply_lock_bounded, normalize_transparent_mode,
        restart_command, safe_log_name, service_log_path, stop_runtime_cleanup_command,
        supervisor_cmdline_matches, REPAIR_COMMAND, START_KERNEL_COMMAND,
    };
    use crate::App;
    use std::fs;
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    fn fixture_app(name: &str) -> (App, PathBuf) {
        let root =
            std::env::temp_dir().join(format!("magicnet-service-{name}-{}", std::process::id()));
        let log_dir = root.join(".log");
        fs::create_dir_all(&log_dir).unwrap();
        let app = App {
            moddir: root.clone(),
            api: String::new(),
            log_dir,
        };
        (app, root)
    }

    #[test]
    fn transparent_mode_only_accepts_tun() {
        assert_eq!(normalize_transparent_mode("tun").unwrap(), "tun");
        assert!(normalize_transparent_mode("proxy").is_err());
        assert!(normalize_transparent_mode("external").is_err());
        assert!(normalize_transparent_mode("external-tun").is_err());
        assert!(normalize_transparent_mode("hybrid").is_err());
        assert!(normalize_transparent_mode("tproxy").is_err());
    }

    #[test]
    fn lifecycle_commands_detach_optional_supervisors_after_core_start() {
        assert!(START_KERNEL_COMMAND.contains("MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2"));
        assert!(START_KERNEL_COMMAND.contains("magicnet_start_kernel"));
        assert!(START_KERNEL_COMMAND.contains("magicnet_supervisors_start_detached"));
        for target in ["sing-box", "singbox"] {
            let command = restart_command(target);
            assert!(command.contains("MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2"));
            assert!(command.contains("magicnet_start_kernel"));
            assert!(command.contains("magicnet_supervisors_start_detached"));
            assert!(!command.contains("supervisor start all >/dev/null"));
        }
    }

    #[test]
    fn stop_runtime_cleanup_preserves_hotspot_when_requested_and_orders_dns_cleanup() {
        assert_eq!(
            stop_runtime_cleanup_command(),
            r#"[ "${MAGICNET_PRESERVE_HOTSPOT_WATCHDOG:-0}" = 1 ] || magicnet_hotspot_watchdog_stop >/dev/null 2>&1 || true; magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true; magicnet_disable_dns_capture || true; magicnet_disable_dns_leak_guard || true"#
        );
    }

    #[test]
    fn repair_explicitly_opts_into_disruptive_recovery() {
        assert!(REPAIR_COMMAND.contains("MAGICNET_ALLOW_DISRUPTIVE_RECOVERY=1"));
        assert!(REPAIR_COMMAND.contains("magicnet_ensure_kernel"));
    }

    #[test]
    fn config_apply_lock_is_exclusive_and_releases_on_drop() {
        let (app, root) = fixture_app("config-apply-lock");
        let lock_path = root.join(".state/config-apply.lock");
        let guard = config_apply_lock(&app).expect("create config apply lock");
        let probe = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&lock_path)
            .expect("open config apply lock probe");
        assert_eq!(
            unsafe {
                libc::flock(
                    std::os::fd::AsRawFd::as_raw_fd(&probe),
                    libc::LOCK_EX | libc::LOCK_NB,
                )
            },
            -1,
            "a second config apply must not enter while the first owns the lock"
        );
        drop(probe);
        let started = Instant::now();
        let error = config_apply_lock_bounded(&app, Duration::from_millis(30))
            .err()
            .expect("bounded lifecycle lock must not wait behind config apply forever");
        assert!(error.contains("config apply is still busy"));
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(guard);
        let reacquired = config_apply_lock(&app).expect("reacquire config apply lock");
        drop(reacquired);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn service_log_targets_reject_path_traversal() {
        assert!(!safe_log_name("../../etc/passwd"));
        assert!(!safe_log_name("../outside.log"));
        assert!(!safe_log_name("nested/outside.log"));
        assert!(safe_log_name("custom.log"));
        assert!(safe_log_name("custom-name_2.log"));
    }

    #[test]
    fn service_log_path_rejects_symlink_escape() {
        let (app, root) = fixture_app("symlink");
        let outside = root.join("outside.log");
        fs::write(&outside, "do not expose\n").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, app.log_dir.join("custom.log")).unwrap();
        #[cfg(unix)]
        assert!(service_log_path(&app, "custom").is_err());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn service_log_path_selects_latest_webui_task_log() {
        let (app, root) = fixture_app("latest-webui");
        let older = app.log_dir.join("webui-start-old.log");
        let newer = app.log_dir.join("webui-start-new.log");
        fs::write(&older, "older\n").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        fs::write(&newer, "newer\n").unwrap();
        fs::write(app.log_dir.join("service.log"), "unrelated\n").unwrap();

        assert_eq!(
            service_log_path(&app, "webui").unwrap(),
            fs::canonicalize(&newer).unwrap()
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn service_log_path_reports_missing_webui_task_log() {
        let (app, root) = fixture_app("missing-webui");
        let error = service_log_path(&app, "webui").unwrap_err();
        assert!(error.starts_with("log file unavailable:"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn webui_setup_uses_the_configured_api_endpoint() {
        assert_eq!(
            api_host_port("http://127.0.0.1:19090"),
            ("127.0.0.1".to_string(), "19090".to_string())
        );
        assert_eq!(
            api_host_port("http://[::1]:19090"),
            ("::1".to_string(), "19090".to_string())
        );
        assert_eq!(
            api_host_port("invalid"),
            ("127.0.0.1".to_string(), "9090".to_string())
        );
    }

    #[test]
    fn supervisor_pidfiles_require_the_matching_module_command() {
        let module = PathBuf::from("/data/adb/modules/MagicNet");
        let kernel = module.join(".state/watchdog/magicnet-kernel.pid");
        let fswatch = module.join(".state/fswatch/magicnet-config.pid");
        let hotspot = module.join(".state/watchdog/magicnet-hotspot-route.pid");
        assert!(supervisor_cmdline_matches(
            &module,
            &kernel,
            "/system/bin/sh /data/adb/modules/MagicNet/.state/watchdog/magicnet-kernel.loop.sh"
        ));
        assert!(supervisor_cmdline_matches(
            &module,
            &fswatch,
            "/data/adb/modules/MagicNet/cli config apply"
        ));
        assert!(supervisor_cmdline_matches(
            &module,
            &hotspot,
            "/system/bin/sh /data/adb/modules/MagicNet/.state/watchdog/magicnet-hotspot-route.loop.sh"
        ));
        assert!(!supervisor_cmdline_matches(
            &module,
            &fswatch,
            "/system/bin/sh /data/adb/modules/Other/.state/fswatch/magicnet-config.loop.sh"
        ));
        assert!(!supervisor_cmdline_matches(
            &module,
            &kernel,
            "sleep 600 /data/adb/modules/MagicNet/.state/watchdog/magicnet-kernel.loop.sh"
        ));
        assert!(!supervisor_cmdline_matches(
            &module,
            &module.join(".state/after-kernel-start.pid"),
            "/data/adb/modules/MagicNet/cli config apply"
        ));
    }
}
