use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::{
    diagnostics::supervisor_pid, pid_summary, run_magicnet_function, write_text_file, App,
};

const START_SUPERVISORS_COMMAND: &str = "\"${MODDIR}/cli\" supervisor start all >/dev/null 2>&1";
const STOP_RUNTIME_CLEANUP_COMMAND: &str =
    "magicnet_disable_dns_capture || true; magicnet_disable_dns_leak_guard || true";
const SELECTED_CORE_CONF: &str = ".config/magicnet/current-core.conf";
const TRANSPARENT_MODE_CONF: &str = ".config/magicnet/transparent-mode.conf";

pub(crate) fn service_status(app: &App) {
    let singbox = pid_summary("sing-box");
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
        .and_then(|text| json_string_value(&text, "external_ui"))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "ui".to_string());
    format!(
        "{}/{}/#/setup?hostname=127.0.0.1&port=9090",
        app.api,
        ui.trim_matches('/')
    )
}

fn json_string_value(text: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let start = text.find(&needle)?;
    let after_key = &text[start + needle.len()..];
    let colon = after_key.find(':')?;
    let after_colon = after_key[colon + 1..].trim_start();
    let value = after_colon.strip_prefix('"')?;
    let end = value.find('"')?;
    Some(value[..end].to_string())
}

pub(crate) fn service_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            service_status(app);
            Ok(())
        }
        "start" => run_magicnet_function(
            app,
            "magicnet_start_kernel && \"${MODDIR}/cli\" supervisor start all >/dev/null 2>&1",
        ),
        "ensure" => run_magicnet_function(app, "magicnet_ensure_kernel"),
        "stop" => stop_all_direct(app),
        "restart" => restart(app, args.get(1).map(String::as_str).unwrap_or("current")),
        "toggle" => match args.get(1).map(String::as_str).unwrap_or_default() {
            "sing-box" | "singbox" => run_magicnet_function(app, "magicnet_action_toggle_singbox"),
            _ => Err("Usage: cli service toggle sing-box".to_string()),
        },
        _ => Err("Usage: cli service {status|start|ensure|stop|restart [current|sing-box]|toggle sing-box|logs [core] [lines]}".to_string()),
    }
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
        "apply" => run_magicnet_function(app, ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; if magicnet_singbox_update_lock_active; then echo '[error] subscription update in progress' >&2; false; else magicnet_apply_runtime_config; fi"),
        _ => Err("Usage: cli config apply".to_string()),
    }
}

pub(crate) fn transparent_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            println!("mode={}", transparent_mode(app));
            Ok(())
        }
        "set" => transparent_set(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "apply" => run_magicnet_function(app, "magicnet_transparent_apply"),
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
    run_magicnet_function(app, "magicnet_apply_runtime_config; magicnet_ensure_kernel")
}

pub(crate) fn service_logs(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or("sing-box");
    let lines = args
        .get(3)
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(120);
    let file = match target {
        "sing-box" | "singbox" | "core" => app.log_dir.join("sing-box.log"),
        other => app.log_dir.join(format!("{other}.log")),
    };
    let text = fs::read_to_string(&file)
        .map_err(|err| format!("log not found {}: {err}", file.display()))?;
    for line in tail_lines(&text, lines) {
        println!("{line}");
    }
    Ok(())
}

fn restart(app: &App, target: &str) -> Result<(), String> {
    stop_all_direct(app)?;
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

pub(crate) fn restart_current_core(app: &App) -> Result<(), String> {
    restart(app, "current")
}

fn restart_command(target: &str) -> &'static str {
    match target {
        "sing-box" | "singbox" => {
            "MAGICNET_DEFAULT_CORE=sing-box MAGICNET_STRICT_CORE=1 magicnet_start_kernel && \"${MODDIR}/cli\" supervisor start all >/dev/null 2>&1"
        }
        _ => unreachable!("restart validates the target before building the command"),
    }
}

fn stop_all_direct(app: &App) -> Result<(), String> {
    stop_supervisor_pidfile(app.moddir.join(".state/watchdog/magicnet-kernel.pid"));
    stop_supervisor_pidfile(app.moddir.join(".state/fswatch/magicnet-config.pid"));
    stop_supervisor_pidfile(app.moddir.join(".state/after-kernel-start.pid"));
    ignore_command(
        "pkill",
        &[
            "-f",
            &format!("{}/cli.*service ensure", app.moddir.display()),
        ],
    );
    ignore_command(
        "pkill",
        &["-f", &format!("{}/cli.*config apply", app.moddir.display())],
    );
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
    ignore_command("killall", &["sing-box"]);
    std::thread::sleep(Duration::from_secs(1));
    ignore_command("killall", &["-9", "sing-box"]);
    run_magicnet_function(app, stop_runtime_cleanup_command())?;
    Ok(())
}

fn stop_runtime_cleanup_command() -> &'static str {
    STOP_RUNTIME_CLEANUP_COMMAND
}

fn stop_supervisor_pidfile(path: PathBuf) {
    if let Ok(text) = fs::read_to_string(&path) {
        if let Ok(pid) = text.trim().parse::<i32>() {
            ignore_command("kill", &[&pid.to_string()]);
        }
    }
    let _ = fs::remove_file(path);
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
    write_transparent_mode(app, mode)?;
    stop_all_direct(app)?;
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
    use super::{normalize_transparent_mode, restart_command, stop_runtime_cleanup_command};

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
    fn restart_commands_restore_supervisors_after_core_start() {
        for target in ["sing-box", "singbox"] {
            let command = restart_command(target);
            assert!(command.contains("magicnet_start_kernel"));
            assert!(command.contains("supervisor start all"));
            assert!(!command.contains("2>&1 &"));
        }
    }

    #[test]
    fn stop_runtime_cleanup_disables_dns_capture_before_leak_guard() {
        assert_eq!(
            stop_runtime_cleanup_command(),
            "magicnet_disable_dns_capture || true; magicnet_disable_dns_leak_guard || true"
        );
    }
}
