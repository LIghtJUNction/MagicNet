use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use crate::{
    diagnostics::supervisor_pid, pid_summary, read_kv, run_magicnet_function, write_text_file, App,
};

pub(crate) fn service_status(app: &App) {
    let singbox = pid_summary("sing-box");
    let mihomo = pid_summary("mihomo");
    let webui = if singbox != "stopped" {
        &app.singbox_webui
    } else if mihomo != "stopped" {
        &app.mihomo_webui
    } else {
        &app.mihomo_webui
    };
    println!("MagicNet");
    println!("  sing-box: {singbox}");
    println!("  mihomo:   {mihomo}");
    println!(
        "  watchdog: {}",
        supervisor_pid(app, "watchdog", "magicnet-kernel")
    );
    println!(
        "  fswatch:  {}",
        supervisor_pid(app, "fswatch", "magicnet-config")
    );
    println!("  Selected: {}", selected_core(app));
    println!("  Transparent: {}", transparent_mode(app));
    println!("  Hotspot: {}", hotspot_mode(app));
    println!("  VPN Coexist: {}", vpn_mode(app));
    println!("  API:      {}", app.api);
    println!("  WebUI:    {webui}");
    println!(
        "  Sub URL:  {}",
        app.moddir
            .join(".config/sing-box/subscription.url")
            .display()
    );
}

pub(crate) fn service_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            service_status(app);
            Ok(())
        }
        "start" => run_magicnet_function(app, "magicnet_start_kernel && magicnet_supervisors_start"),
        "ensure" => run_magicnet_function(app, "magicnet_ensure_kernel"),
        "stop" => stop_all_direct(app),
        "restart" => restart(app, args.get(1).map(String::as_str).unwrap_or("current")),
        "toggle" => match args.get(1).map(String::as_str).unwrap_or_default() {
            "sing-box" | "singbox" => run_magicnet_function(app, "magicnet_action_toggle_singbox"),
            "mihomo" => run_magicnet_function(app, "magicnet_action_toggle_mihomo"),
            _ => Err("Usage: cli service toggle <sing-box|mihomo>".to_string()),
        },
        _ => Err("Usage: cli service {status|start|ensure|stop|restart [current|sing-box|mihomo]|toggle <sing-box|mihomo>|logs [core] [lines]}".to_string()),
    }
}

pub(crate) fn supervisor_cmd(app: &App, args: &[String]) -> Result<(), String> {
    let action = args.first().map(String::as_str).unwrap_or("status");
    let target = args.get(1).map(String::as_str).unwrap_or("all");
    match action {
        "status" => {
            if matches!(target, "all" | "watchdog") {
                println!(
                    "watchdog={}",
                    supervisor_pid(app, "watchdog", "magicnet-kernel")
                );
            }
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
        _ => Err(
            "Usage: cli supervisor {status|start|stop|restart} [watchdog|fswatch|all]".to_string(),
        ),
    }
}

pub(crate) fn watchdog_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => supervisor_cmd(app, &[String::from("status"), String::from("watchdog")]),
        "start" => run_magicnet_function(app, "magicnet_watchdog_start"),
        "stop" => run_magicnet_function(app, "magicnet_watchdog_stop"),
        "restart" => run_magicnet_function(app, "magicnet_watchdog_stop; magicnet_watchdog_start"),
        _ => Err("Usage: cli watchdog {status|start|stop|restart}".to_string()),
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
        _ => Err("Usage: cli transparent {status|set <tun|tproxy>|apply}".to_string()),
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
        _ => Err("Usage: cli core {status|selected|select <sing-box|mihomo>}".to_string()),
    }
}

pub(crate) fn hotspot_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            println!("mode={}", hotspot_mode(app));
            Ok(())
        }
        "set" => hotspot_set(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "reload" | "apply" => match hotspot_mode(app).as_str() {
            "direct" => run_magicnet_function(app, "magicnet_disable_hotspot_forward"),
            _ => run_magicnet_function(app, "magicnet_enable_hotspot_forward"),
        },
        _ => Err("Usage: cli hotspot {status|set <proxy|direct>|reload}".to_string()),
    }
}

pub(crate) fn vpn_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            println!("mode={}", vpn_mode(app));
            Ok(())
        }
        "set" => vpn_set(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "reload" | "apply" => match vpn_mode(app).as_str() {
            "off" => run_magicnet_function(app, "magicnet_disable_vpn_coexist"),
            _ => run_magicnet_function(app, "magicnet_enable_vpn_coexist"),
        },
        _ => Err("Usage: cli vpn {status|set <on|off>|reload}".to_string()),
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
        "mihomo" => app.log_dir.join("mihomo.log"),
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
    run_magicnet_function(app, restart_command(target.as_str()))
}

fn restart_command(target: &str) -> &'static str {
    match target {
        "sing-box" | "singbox" => {
            "MAGICNET_DEFAULT_CORE=sing-box MAGICNET_STRICT_CORE=1 magicnet_start_kernel && magicnet_supervisors_start"
        }
        "mihomo" => {
            "MAGICNET_DEFAULT_CORE=mihomo MAGICNET_STRICT_CORE=1 magicnet_start_kernel && magicnet_supervisors_start"
        }
        _ => "magicnet_start_kernel && magicnet_supervisors_start",
    }
}

fn stop_all_direct(app: &App) -> Result<(), String> {
    stop_supervisor_pidfile(app.moddir.join(".state/watchdog/magicnet-kernel.pid"));
    stop_supervisor_pidfile(app.moddir.join(".state/fswatch/magicnet-config.pid"));
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
    ignore_command("killall", &["mihomo"]);
    std::thread::sleep(Duration::from_secs(1));
    ignore_command("killall", &["-9", "sing-box"]);
    ignore_command("killall", &["-9", "mihomo"]);
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
        ("watchdog", "start") => run_magicnet_function(app, "magicnet_watchdog_start"),
        ("watchdog", "stop") => run_magicnet_function(app, "magicnet_watchdog_stop"),
        ("watchdog", "restart") => {
            run_magicnet_function(app, "magicnet_watchdog_stop; magicnet_watchdog_start")
        }
        ("fswatch", "start") => run_magicnet_function(app, "magicnet_fswatch_start"),
        ("fswatch", "stop") => run_magicnet_function(app, "magicnet_fswatch_stop"),
        ("fswatch", "restart") => {
            run_magicnet_function(app, "magicnet_fswatch_stop; magicnet_fswatch_start")
        }
        _ => Err(
            "Usage: cli supervisor {status|start|stop|restart} [watchdog|fswatch|all]".to_string(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::restart_command;

    #[test]
    fn restart_commands_restore_supervisors_after_core_start() {
        for target in ["sing-box", "singbox", "mihomo", "auto"] {
            let command = restart_command(target);
            assert!(command.contains("magicnet_start_kernel"));
            assert!(command.ends_with("&& magicnet_supervisors_start"));
        }
    }
}

fn select_core(app: &App, core: &str) -> Result<(), String> {
    let normalized = match core {
        "sing-box" | "singbox" => "sing-box",
        "mihomo" | "clash" => "mihomo",
        _ => return Err("Usage: cli core select <sing-box|mihomo>".to_string()),
    };
    write_text_file(
        selected_core_path(app),
        &format!("MAGICNET_DEFAULT_CORE={normalized}\n"),
    )?;
    println!("[info] 默认核心已设为: {normalized}");
    Ok(())
}

fn transparent_set(app: &App, mode: &str) -> Result<(), String> {
    if !matches!(mode, "tun" | "tproxy") {
        return Err("Usage: cli transparent set <tun|tproxy>".to_string());
    }
    write_text_file(
        app.moddir.join(".config/magicnet/transparent-mode.conf"),
        &format!("MAGICNET_TRANSPARENT_MODE={mode}\n"),
    )?;
    run_magicnet_function(app, "magicnet_transparent_apply")?;
    println!("[info] Transparent mode set to {mode}");
    Ok(())
}

fn hotspot_set(app: &App, mode: &str) -> Result<(), String> {
    let value = match mode {
        "proxy" => "1",
        "direct" => "0",
        _ => return Err("Usage: cli hotspot set <proxy|direct>".to_string()),
    };
    write_text_file(
        app.moddir.join(".config/magicnet/hotspot.conf"),
        &format!("MAGIC_HOTSPOT_FORWARD={value}\n"),
    )?;
    hotspot_cmd(app, &[String::from("reload")])?;
    println!("[info] Hotspot mode set to {mode}");
    Ok(())
}

fn vpn_set(app: &App, mode: &str) -> Result<(), String> {
    let value = match mode {
        "on" | "enable" | "enabled" | "1" | "true" => "1",
        "off" | "disable" | "disabled" | "0" | "false" => "0",
        _ => return Err("Usage: cli vpn set <on|off>".to_string()),
    };
    write_text_file(
        app.moddir.join(".config/magicnet/vpn.conf"),
        &format!("MAGIC_VPN_COEXIST={value}\n"),
    )?;
    vpn_cmd(app, &[String::from("reload")])?;
    println!(
        "[info] VPN coexistence set to {}",
        if value == "1" { "on" } else { "off" }
    );
    Ok(())
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

fn hotspot_mode(app: &App) -> String {
    let conf = read_kv(app.moddir.join(".config/magicnet/hotspot.conf"));
    if conf.get("MAGIC_HOTSPOT_FORWARD").map(String::as_str) == Some("0") {
        "direct".to_string()
    } else {
        "proxy".to_string()
    }
}

fn vpn_mode(app: &App) -> String {
    let conf = read_kv(app.moddir.join(".config/magicnet/vpn.conf"));
    if conf.get("MAGIC_VPN_COEXIST").map(String::as_str) == Some("0") {
        "off".to_string()
    } else {
        "on".to_string()
    }
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
                    "mihomo" | "clash" => Some("mihomo".to_string()),
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
