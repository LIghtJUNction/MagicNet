use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use crate::{
    diagnostics::supervisor_pid, pid_summary, run_magicnet_function, write_text_file, App,
};

const START_SUPERVISORS_COMMAND: &str = "\"${MODDIR}/cli\" supervisor start all >/dev/null 2>&1 &";

pub(crate) fn service_status(app: &App) {
    let singbox = pid_summary("sing-box");
    println!("MagicNet");
    println!("  sing-box: {singbox}");
    println!(
        "  fswatch:  {}",
        supervisor_pid(app, "fswatch", "magicnet-config")
    );
    println!("  Selected: {}", selected_core(app));
    println!("  Transparent: {}", transparent_mode(app));
    println!("  API:      {}", app.api);
    println!("  WebUI:    {}", singbox_webui(app));
    println!(
        "  Sub URL:  {}",
        app.moddir
            .join(".config/sing-box/subscription.url")
            .display()
    );
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
            "magicnet_start_kernel && { \"${MODDIR}/cli\" supervisor start all >/dev/null 2>&1 & }",
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
            Ok(())
        }
        "start" => supervisor_target(app, target, "start"),
        "stop" => supervisor_target(app, target, "stop"),
        "restart" => supervisor_target(app, target, "restart"),
        _ => Err("Usage: cli supervisor {status|start|stop|restart} [fswatch|all]".to_string()),
    }
}

pub(crate) fn config_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or_default() {
        "apply" => run_magicnet_function(app, "magicnet_apply_runtime_config"),
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
        _ => Err(
            "Usage: cli transparent {status|set <proxy|external-tun|hybrid|tun>|apply}".to_string(),
        ),
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

fn restart_command(target: &str) -> &'static str {
    match target {
        "sing-box" | "singbox" => {
            "MAGICNET_DEFAULT_CORE=sing-box MAGICNET_STRICT_CORE=1 magicnet_start_kernel && { \"${MODDIR}/cli\" supervisor start all >/dev/null 2>&1 & }"
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
    ignore_command("killall", &["sing-box"]);
    std::thread::sleep(Duration::from_secs(1));
    ignore_command("killall", &["-9", "sing-box"]);
    run_magicnet_function(app, "magicnet_disable_dns_leak_guard || true")?;
    Ok(())
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
        _ => Err("Usage: cli supervisor {status|start|stop|restart} [fswatch|all]".to_string()),
    }
}

fn select_core(app: &App, core: &str) -> Result<(), String> {
    let normalized = match core {
        "sing-box" | "singbox" => "sing-box",
        _ => return Err("Usage: cli core select sing-box".to_string()),
    };
    write_text_file(
        selected_core_path(app),
        &format!("MAGICNET_DEFAULT_CORE={normalized}\n"),
    )?;
    println!("[info] 默认核心已设为: {normalized}");
    Ok(())
}

fn transparent_set(app: &App, mode: &str) -> Result<(), String> {
    let mode = normalize_transparent_mode(mode)?;
    write_transparent_mode(app, mode)?;
    stop_all_direct(app)?;
    if let Err(err) = run_magicnet_function(app, "magicnet_transparent_apply") {
        return Err(err);
    }
    if let Err(err) = run_magicnet_function(app, "magicnet_start_kernel") {
        return Err(err);
    }
    start_supervisors(app)?;
    println!("[info] Transparent mode set to {mode}");
    Ok(())
}

fn normalize_transparent_mode(mode: &str) -> Result<&'static str, String> {
    match mode {
        "proxy" => Ok("proxy"),
        "external-tun" | "external" => Ok("external-tun"),
        "hybrid" => Ok("hybrid"),
        "tun" => Ok("tun"),
        _ => Err("Usage: cli transparent set <proxy|external-tun|hybrid|tun>".to_string()),
    }
}

fn start_supervisors(app: &App) -> Result<(), String> {
    run_magicnet_function(app, START_SUPERVISORS_COMMAND)
}

fn write_transparent_mode(app: &App, mode: &str) -> Result<(), String> {
    write_text_file(
        app.moddir.join(".config/magicnet/transparent-mode.conf"),
        &format!("MAGICNET_TRANSPARENT_MODE={mode}\n"),
    )
}

fn transparent_mode(app: &App) -> String {
    fs::read_to_string(app.moddir.join(".config/magicnet/transparent-mode.conf"))
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let (_, value) = line.split_once('=')?;
                match value.trim().trim_matches('"').trim_matches('\'') {
                    "proxy" => Some("proxy".to_string()),
                    "external-tun" | "external" => Some("external-tun".to_string()),
                    "hybrid" => Some("hybrid".to_string()),
                    "tun" => Some("tun".to_string()),
                    _ => None,
                }
            })
        })
        .unwrap_or_else(|| "tun".to_string())
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
    app.moddir.join(".config/magicnet/current-core.conf")
}

fn tail_lines(text: &str, lines: usize) -> Vec<&str> {
    let all: Vec<&str> = text.lines().collect();
    let start = all.len().saturating_sub(lines);
    all[start..].to_vec()
}

#[cfg(test)]
mod tests {
    use super::{normalize_transparent_mode, restart_command};

    #[test]
    fn transparent_modes_accept_orchestrator_modes() {
        assert_eq!(normalize_transparent_mode("proxy").unwrap(), "proxy");
        assert_eq!(
            normalize_transparent_mode("external").unwrap(),
            "external-tun"
        );
        assert_eq!(
            normalize_transparent_mode("external-tun").unwrap(),
            "external-tun"
        );
        assert_eq!(normalize_transparent_mode("hybrid").unwrap(), "hybrid");
        assert_eq!(normalize_transparent_mode("tun").unwrap(), "tun");
        assert!(normalize_transparent_mode("tproxy").is_err());
    }

    #[test]
    fn restart_commands_restore_supervisors_after_core_start() {
        for target in ["sing-box", "singbox"] {
            let command = restart_command(target);
            assert!(command.contains("magicnet_start_kernel"));
            assert!(command.contains("supervisor start all"));
            assert!(command.contains("& }"));
        }
    }
}
