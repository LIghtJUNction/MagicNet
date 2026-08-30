use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::{
    cmdline_has_command, cmdline_has_script, diagnostics::supervisor_pid,
    ebpf_runtime::inspect_ebpf_attachments, owned_singbox_pids, read_proc_argv,
    run_magicnet_function, singbox_pid_summary, stop_owned_singbox, write_text_file, App,
};

const START_SUPERVISORS_COMMAND: &str = "magicnet_supervisors_start_detached";
const START_KERNEL_COMMAND: &str =
    "MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2 magicnet_start_kernel && magicnet_supervisors_start_detached";
const STOP_RUNTIME_CLEANUP_COMMAND: &str =
    "magicnet_hotspot_watchdog_stop >/dev/null 2>&1 || true; magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true; magicnet_disable_dns_capture || true; magicnet_disable_dns_leak_guard || true";
const REPAIR_COMMAND: &str =
    "magicnet_apply_runtime_config; MAGICNET_ALLOW_DISRUPTIVE_RECOVERY=1 magicnet_ensure_kernel";
const SELECTED_CORE_CONF: &str = ".config/magicnet/current-core.conf";
const TRANSPARENT_MODE_CONF: &str = ".config/magicnet/transparent-mode.conf";
const TRANSPARENT_CONFIG: &str = ".config/sing-box/config.json";
const TRANSPARENT_TRANSACTION: &str = ".state/transparent-transaction";
const TRANSPARENT_RECENT_ERROR: &str = ".state/transparent-recent-error";
const TRANSPARENT_CAPABILITY: &str = ".state/transparent-ebpf/capability";
const TRANSPARENT_PROBE_REPORT: &str = ".state/transparent-ebpf/probe.json";
const TRANSPARENT_SHARED_PENDING: &str = ".state/transparent-ebpf/shared.pending";
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
    stop_all_direct(app, false)
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
            restart_current_core_preserving_config_apply(app)?;
        }
    }
    Ok(())
}

pub(crate) fn transparent_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => transparent_status(app),
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
    restart_with_options_unlocked(app, target, false)
}

pub(crate) fn restart_current_core(app: &App) -> Result<(), String> {
    restart(app, "current")
}

fn restart_current_core_preserving_config_apply(app: &App) -> Result<(), String> {
    restart_with_options_unlocked(app, "current", true)
}

fn restart_with_options_unlocked(
    app: &App,
    target: &str,
    preserve_config_apply: bool,
) -> Result<(), String> {
    stop_all_direct(app, preserve_config_apply)?;
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

fn stop_all_direct(app: &App, preserve_config_apply: bool) -> Result<(), String> {
    // Discovery is a fail-closed gate. A temporary pidof/proc-reader failure
    // must leave the old core, supervisors, TUN, and DNS policy untouched.
    let owned_singbox = owned_singbox_pids(app)?;

    stop_supervisor_pidfile(app, app.moddir.join(".state/watchdog/magicnet-kernel.pid"));
    stop_supervisor_pidfile(
        app,
        app.moddir
            .join(".state/watchdog/magicnet-hotspot-route.pid"),
    );
    stop_supervisor_pidfile(app, app.moddir.join(".state/fswatch/magicnet-config.pid"));
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
    // MagicNet stop/restart. If a stop-wait lookup becomes indeterminate,
    // restore optional supervisors and preserve all network runtime state.
    if let Err(err) = stop_owned_singbox(app, owned_singbox) {
        let _ = run_magicnet_function(app, START_SUPERVISORS_COMMAND);
        return Err(err);
    }
    run_magicnet_function(app, stop_runtime_cleanup_command())?;
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
    let argv = read_proc_argv(Path::new(&format!("/proc/{pid}/cmdline"))).unwrap_or_default();
    supervisor_cmdline_matches(&app.moddir, path, &argv)
}

fn supervisor_cmdline_matches(moddir: &Path, path: &Path, argv: &[String]) -> bool {
    let module = moddir.to_string_lossy();
    match path.file_name().and_then(|name| name.to_str()) {
        Some("magicnet-kernel.pid") => {
            cmdline_has_script(
                argv,
                &format!("{module}/.state/watchdog/magicnet-kernel.loop.sh"),
            ) || cmdline_has_command(argv, &format!("{module}/cli"), &["service", "ensure"])
        }
        Some("magicnet-config.pid") => {
            cmdline_has_script(
                argv,
                &format!("{module}/.state/fswatch/magicnet-config.loop.sh"),
            ) || cmdline_has_command(argv, &format!("{module}/cli"), &["config", "apply"])
        }
        Some("magicnet-hotspot-route.pid") => cmdline_has_script(
            argv,
            &format!("{module}/.state/watchdog/magicnet-hotspot-route.loop.sh"),
        ),
        _ => false,
    }
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
    run_magicnet_function(app, "magicnet_recover_interrupted_transparent_transaction")?;
    let old_mode = read_transparent_mode(app)?;
    prepare_transparent_transaction(app, &old_mode, mode)?;

    let mut old_stop_started = false;
    let transition = (|| -> Result<(), String> {
        write_transparent_mode(app, mode)?;
        set_transparent_phase(app, "target-written")?;
        set_transparent_phase(app, "preflight")?;
        run_magicnet_function(app, "magicnet_prepare_singbox_candidate_unlocked")?;
        set_transparent_phase(app, "candidate-prepared")?;
        old_stop_started = true;
        set_transparent_phase(app, "stopping-old")?;
        stop_all_direct(app, false)?;
        set_transparent_phase(app, "old-stopped")?;
        set_transparent_phase(app, "candidate-starting")?;
        run_magicnet_function(
            app,
            "MAGICNET_TRANSPARENT_TRANSACTION_ACTIVE=1 MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2 magicnet_start_kernel",
        )?;
        run_magicnet_function(app, "magicnet_transparent_verify_running")?;
        set_transparent_phase(app, "verified")?;
        start_supervisors(app)?;
        Ok(())
    })();

    if let Err(error) = transition {
        let phase = transparent_transition_phase(app).unwrap_or_else(|| "unknown".to_string());
        let recent = format!("transition to {mode} failed at {phase}");
        let _ = write_text_file(
            app,
            Path::new(TRANSPARENT_RECENT_ERROR),
            &format!("{recent}\n"),
        );
        let rollback = if old_stop_started {
            rollback_transparent_transaction(app, &old_mode)
        } else {
            rollback_transparent_preflight(app, &old_mode)
        };
        return match rollback {
            Ok(()) => Err(format!("{recent}; previous mode restored: {error}")),
            Err(rollback_error) => Err(format!(
                "{recent}; rollback is pending recovery: {error}; {rollback_error}"
            )),
        };
    }

    fs::remove_dir_all(app.moddir.join(TRANSPARENT_TRANSACTION))
        .map_err(|error| format!("commit transparent transaction: {error}"))?;
    match fs::remove_file(app.moddir.join(TRANSPARENT_RECENT_ERROR)) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("clear transparent transition error: {error}")),
    }
    println!("[info] Transparent mode set to {mode}");
    Ok(())
}

fn normalize_transparent_mode(mode: &str) -> Result<&'static str, String> {
    match mode {
        "tun" => Ok("tun"),
        "ebpf" => Ok("ebpf"),
        _ => Err("Usage: cli transparent set {tun|ebpf}".to_string()),
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

struct TransparentModeState {
    mode: String,
    file_present: bool,
}

fn read_transparent_mode(app: &App) -> Result<TransparentModeState, String> {
    let path = app.moddir.join(TRANSPARENT_MODE_CONF);
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(TransparentModeState {
                mode: "tun".to_string(),
                file_present: false,
            });
        }
        Err(error) => return Err(format!("read transparent mode: {error}")),
    };
    let mut value = None;
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let candidate = line
            .strip_prefix("MAGICNET_TRANSPARENT_MODE=")
            .ok_or_else(|| {
                "transparent mode configuration contains an unknown assignment".to_string()
            })?;
        if value.replace(candidate).is_some() {
            return Err("transparent mode configuration contains duplicate values".to_string());
        }
    }
    let value = value.ok_or_else(|| {
        "transparent mode configuration must contain exactly one value".to_string()
    })?;
    let mode = normalize_transparent_mode(value)?;
    Ok(TransparentModeState {
        mode: mode.to_string(),
        file_present: true,
    })
}

fn prepare_transparent_transaction(
    app: &App,
    old_mode: &TransparentModeState,
    target_mode: &str,
) -> Result<(), String> {
    let journal = app.moddir.join(TRANSPARENT_TRANSACTION);
    if journal.exists() {
        return Err("transparent transaction recovery did not clear the journal".to_string());
    }
    let staging = app.moddir.join(format!(
        "{}.new.{}",
        TRANSPARENT_TRANSACTION,
        std::process::id()
    ));
    if staging.exists() {
        fs::remove_dir_all(&staging)
            .map_err(|error| format!("clear transparent journal staging: {error}"))?;
    }
    fs::create_dir_all(&staging).map_err(|error| format!("create transparent journal: {error}"))?;
    fs::set_permissions(&staging, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("protect transparent journal: {error}"))?;
    write_private_file(
        &staging.join("old-mode"),
        format!("{}\n", old_mode.mode).as_bytes(),
    )?;
    write_private_file(
        &staging.join("old-mode-present"),
        if old_mode.file_present {
            b"1\n"
        } else {
            b"0\n"
        },
    )?;
    write_private_file(
        &staging.join("target-mode"),
        format!("{target_mode}\n").as_bytes(),
    )?;
    write_private_file(&staging.join("phase"), b"prepared\n")?;
    let config = app.moddir.join(TRANSPARENT_CONFIG);
    if config.is_file() {
        let bytes =
            fs::read(&config).map_err(|error| format!("snapshot transparent config: {error}"))?;
        write_private_file(&staging.join("old-config.json"), &bytes)?;
        write_private_file(&staging.join("old-config-present"), b"1\n")?;
    } else {
        write_private_file(&staging.join("old-config-present"), b"0\n")?;
    }
    fs::rename(&staging, &journal)
        .map_err(|error| format!("publish transparent journal: {error}"))?;
    Ok(())
}

fn write_private_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    fs::write(path, bytes).map_err(|error| format!("write {}: {error}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("protect {}: {error}", path.display()))
}

fn set_transparent_phase(app: &App, phase: &str) -> Result<(), String> {
    write_text_file(
        app,
        Path::new(".state/transparent-transaction/phase"),
        &format!("{phase}\n"),
    )
}

fn transparent_transition_phase(app: &App) -> Option<String> {
    let phase = fs::read_to_string(app.moddir.join(TRANSPARENT_TRANSACTION).join("phase"))
        .ok()?
        .trim()
        .to_string();
    if !phase.is_empty()
        && phase
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        Some(phase)
    } else {
        None
    }
}

fn restore_transaction_snapshot(app: &App, old_mode: &TransparentModeState) -> Result<(), String> {
    if old_mode.file_present {
        write_transparent_mode(app, &old_mode.mode)?;
    } else {
        match fs::remove_file(app.moddir.join(TRANSPARENT_MODE_CONF)) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("restore absent transparent mode: {error}")),
        }
    }
    let journal = app.moddir.join(TRANSPARENT_TRANSACTION);
    let config_present = fs::read_to_string(journal.join("old-config-present"))
        .map_err(|error| format!("read transparent config snapshot marker: {error}"))?;
    let config = app.moddir.join(TRANSPARENT_CONFIG);
    match config_present.trim() {
        "1" => {
            let bytes = fs::read(journal.join("old-config.json"))
                .map_err(|error| format!("read transparent config snapshot: {error}"))?;
            let temporary = config.with_extension(format!("json.tmp.{}", std::process::id()));
            write_private_file(&temporary, &bytes)?;
            fs::rename(&temporary, &config)
                .map_err(|error| format!("restore transparent config: {error}"))?;
        }
        "0" => match fs::remove_file(&config) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("restore absent transparent config: {error}")),
        },
        _ => return Err("invalid transparent config snapshot marker".to_string()),
    }
    Ok(())
}

fn rollback_transparent_preflight(
    app: &App,
    old_mode: &TransparentModeState,
) -> Result<(), String> {
    set_transparent_phase(app, "rolling-back")?;
    restore_transaction_snapshot(app, old_mode)?;
    fs::remove_dir_all(app.moddir.join(TRANSPARENT_TRANSACTION))
        .map_err(|error| format!("finish transparent preflight rollback: {error}"))
}

fn rollback_transparent_transaction(
    app: &App,
    old_mode: &TransparentModeState,
) -> Result<(), String> {
    set_transparent_phase(app, "rolling-back")?;
    stop_all_direct(app, false)?;
    restore_transaction_snapshot(app, old_mode)?;
    set_transparent_phase(app, "old-restored")?;
    run_magicnet_function(
        app,
        "unset MAGICNET_FAKE_SINGBOX_START_FAIL MAGICNET_FAKE_EBPF_PROBE_FAIL MAGICNET_FAKE_SINGBOX_CHECK_FAIL; MAGICNET_TRANSPARENT_TRANSACTION_ACTIVE=1 MAGICNET_TRANSPARENT_RESTORED_CONFIG=1 MAGICNET_SUB_CONFIG_LOCK_TIMEOUT=2 magicnet_start_kernel",
    )?;
    run_magicnet_function(app, "magicnet_transparent_verify_running")?;
    start_supervisors(app)?;
    fs::remove_dir_all(app.moddir.join(TRANSPARENT_TRANSACTION))
        .map_err(|error| format!("finish transparent rollback: {error}"))
}

fn transparent_status(app: &App) -> Result<(), String> {
    let configured = read_transparent_mode(app)?.mode;
    let config = fs::read_to_string(app.moddir.join(TRANSPARENT_CONFIG))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let inbound = config
        .as_ref()
        .and_then(|value| value.get("inbounds"))
        .and_then(Value::as_array)
        .and_then(|inbounds| {
            inbounds
                .iter()
                .find(|inbound| inbound.get("tag").and_then(Value::as_str) == Some("tun-in"))
        });
    let effective = match inbound
        .and_then(|value| value.get("type"))
        .and_then(Value::as_str)
    {
        Some("tun") => "tun",
        Some("ebpf") => "ebpf",
        _ => configured.as_str(),
    };
    let pids = owned_singbox_pids(app)?;
    let running = !pids.is_empty();
    let pid = if running {
        pids.join(",")
    } else {
        "none".to_string()
    };
    let ebpf_mode = inbound
        .and_then(|value| value.get("mode"))
        .and_then(Value::as_str)
        .unwrap_or("local");
    let shared_interface_values = inbound
        .and_then(|value| value.get("shared"))
        .and_then(|value| value.get("interface"))
        .and_then(Value::as_array)
        .map(|interfaces| {
            interfaces
                .iter()
                .filter_map(Value::as_str)
                .filter(|interface| {
                    !interface.is_empty()
                        && interface.bytes().all(|byte| {
                            byte.is_ascii_alphanumeric()
                                || matches!(byte, b'_' | b'-' | b'.' | b':')
                        })
                })
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let shared_interfaces = if shared_interface_values.is_empty() {
        "none".to_string()
    } else {
        shared_interface_values.join(",")
    };
    let cgroup_path = inbound
        .and_then(|value| value.get("local"))
        .and_then(|value| value.get("cgroup_path"))
        .and_then(Value::as_str)
        .filter(|path| Path::new(path).is_absolute())
        .unwrap_or("/sys/fs/cgroup");
    let network = match inbound.and_then(|value| value.get("network")) {
        Some(Value::String(value)) if matches!(value.as_str(), "tcp" | "udp") => {
            vec![value.clone()]
        }
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(Value::as_str)
            .filter(|value| matches!(*value, "tcp" | "udp"))
            .map(str::to_string)
            .collect::<Vec<_>>(),
        _ => Vec::new(),
    };
    let network = if network.is_empty() {
        vec!["tcp".to_string(), "udp".to_string()]
    } else {
        network
    };
    let capability = if effective == "tun" {
        "not-required".to_string()
    } else {
        fs::read_to_string(app.moddir.join(TRANSPARENT_CAPABILITY))
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| matches!(value.as_str(), "ok" | "failed"))
            .unwrap_or_else(|| "unknown".to_string())
    };
    let probe_fresh = effective != "ebpf"
        || !running
        || run_magicnet_function(app, "magicnet_ebpf_refresh_active_report").is_ok();
    let probe_report = probe_fresh
        .then(|| fs::read_to_string(app.moddir.join(TRANSPARENT_PROBE_REPORT)).ok())
        .flatten()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let local_expected = matches!(ebpf_mode, "local" | "hybrid");
    let shared_expected = matches!(ebpf_mode, "shared" | "hybrid");
    let attachments = (effective == "ebpf" && running)
        .then(|| {
            probe_report.as_ref().map(|report| {
                inspect_ebpf_attachments(
                    app,
                    report,
                    local_expected,
                    cgroup_path,
                    &network,
                    &shared_interface_values,
                )
            })
        })
        .flatten();
    let local_cgroup = if effective != "ebpf" || !local_expected {
        "inactive"
    } else if !running {
        "configured"
    } else if attachments
        .as_ref()
        .is_some_and(|evidence| evidence.local_attached)
    {
        "attached"
    } else if attachments.is_some() {
        "missing"
    } else {
        "unknown"
    };
    let shared_tc = if effective != "ebpf" {
        "inactive"
    } else if !shared_expected {
        if app.moddir.join(TRANSPARENT_SHARED_PENDING).is_file() {
            "pending"
        } else {
            "inactive"
        }
    } else if shared_interface_values.is_empty() {
        "missing"
    } else if !running {
        "configured"
    } else if attachments
        .as_ref()
        .is_some_and(|evidence| evidence.shared_attached)
    {
        "attached"
    } else if attachments.is_some() {
        "missing"
    } else {
        "unknown"
    };
    let shared_tc_interfaces = if shared_interface_values.is_empty() {
        "none".to_string()
    } else if let Some(evidence) = &attachments {
        evidence
            .shared_interfaces
            .iter()
            .map(|(interface, attached)| {
                format!(
                    "{interface}:{}",
                    if *attached { "attached" } else { "missing" }
                )
            })
            .collect::<Vec<_>>()
            .join(",")
    } else {
        shared_interface_values
            .iter()
            .map(|interface| format!("{interface}:unknown"))
            .collect::<Vec<_>>()
            .join(",")
    };
    let recent_error = fs::read_to_string(app.moddir.join(TRANSPARENT_RECENT_ERROR))
        .ok()
        .and_then(|value| {
            let value = value.trim();
            if value.starts_with("transition to ")
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b' ' | b'-'))
            {
                Some(value.to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "none".to_string());
    let transition = transparent_transition_phase(app).unwrap_or_else(|| "idle".to_string());

    println!("mode={effective}");
    println!("configured_mode={configured}");
    println!(
        "effective_mode={}",
        if effective == "ebpf" {
            ebpf_mode
        } else {
            effective
        }
    );
    println!("pid={pid}");
    println!("capability={capability}");
    println!("local_cgroup={local_cgroup}");
    println!("shared_tc={shared_tc}");
    println!("shared_interfaces={shared_interfaces}");
    println!("shared_tc_interfaces={shared_tc_interfaces}");
    println!(
        "attachment_detail={}",
        attachments
            .as_ref()
            .map(|evidence| evidence.detail.as_str())
            .unwrap_or("not-inspected")
    );
    println!("recent_error={recent_error}");
    println!("transition={transition}");
    Ok(())
}

fn transparent_mode(app: &App) -> String {
    read_transparent_mode(app)
        .map(|state| state.mode)
        .unwrap_or_else(|_| "invalid".to_string())
}

fn transparent_usage() -> String {
    "Usage: cli transparent {status|set {tun|ebpf}|apply}".to_string()
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
#[path = "../tests/internal/service.rs"]
mod tests;
