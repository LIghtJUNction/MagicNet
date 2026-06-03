use std::fs;
use std::path::PathBuf;

use crate::{pid_summary, read_kv, run_magicnet_function, write_text_file, App};

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
    println!("  sing-box-disabled: {}", bool_file(app.moddir.join(".disable_sing_box")) as u8);
    println!("  mihomo:   {mihomo}");
    println!("  watchdog: {}", pid_summary("watchdog"));
    println!("  fswatch:  {}", pid_summary("fswatch"));
    println!("  Selected: {}", selected_core(app));
    println!("  Transparent: {}", transparent_mode(app));
    println!("  Hotspot: {}", hotspot_mode(app));
    println!("  API:      {}", app.api);
    println!("  WebUI:    {webui}");
    println!("  Sub URL:  {}", app.moddir.join(".config/sing-box/subscription.url").display());
}

pub(crate) fn service_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            service_status(app);
            Ok(())
        }
        "start" => run_magicnet_function(app, "magicnet_start_kernel"),
        "ensure" => run_magicnet_function(app, "magicnet_ensure_kernel"),
        "stop" => run_magicnet_function(app, "magicnet_supervisors_stop; import __singbox__; singbox_stop 2>/dev/null || true; import __mihomo__; mihomo_stop 2>/dev/null || true; magicnet_refresh_status"),
        "restart" => restart(app, args.get(1).map(String::as_str).unwrap_or("current")),
        "toggle" => match args.get(1).map(String::as_str).unwrap_or_default() {
            "sing-box" | "singbox" => run_magicnet_function(app, "magicnet_action_toggle_singbox"),
            "mihomo" => run_magicnet_function(app, "magicnet_action_toggle_mihomo"),
            _ => Err("Usage: cli service toggle <sing-box|mihomo>".to_string()),
        },
        _ => Err("Usage: cli service {status|start|ensure|stop|restart [current|sing-box|mihomo]|toggle <sing-box|mihomo>|logs [core] [lines]}".to_string()),
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
        "sing-box" | "singbox" => singbox_cmd(app, args.get(1).map(String::as_str).unwrap_or("status")),
        _ => Err("Usage: cli core {status|selected|select <sing-box|mihomo>|sing-box {status|enable|disable|toggle}}".to_string()),
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
    match args.first().map(String::as_str).unwrap_or("reload") {
        "reload" => run_magicnet_function(app, "magicnet_enable_vpn_coexist"),
        _ => Err("Usage: cli vpn reload".to_string()),
    }
}

pub(crate) fn repair(app: &App) -> Result<(), String> {
    run_magicnet_function(app, "magicnet_apply_runtime_config; magicnet_ensure_kernel")
}

pub(crate) fn service_logs(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or("sing-box");
    let lines = args.get(3).and_then(|value| value.parse::<usize>().ok()).unwrap_or(120);
    let file = match target {
        "sing-box" | "singbox" | "core" => app.log_dir.join("sing-box.log"),
        "mihomo" => app.log_dir.join("mihomo.log"),
        other => app.log_dir.join(format!("{other}.log")),
    };
    let text = fs::read_to_string(&file).map_err(|err| format!("log not found {}: {err}", file.display()))?;
    for line in tail_lines(&text, lines) {
        println!("{line}");
    }
    Ok(())
}

fn restart(app: &App, target: &str) -> Result<(), String> {
    let target = if target == "current" { selected_core(app) } else { target.to_string() };
    match target.as_str() {
        "sing-box" | "singbox" => run_magicnet_function(app, "magicnet_supervisors_stop; import __mihomo__; mihomo_stop 2>/dev/null || true; import __singbox__; singbox_stop 2>/dev/null || true; magicnet_start_singbox; magicnet_after_kernel_start; magicnet_supervisors_start"),
        "mihomo" => run_magicnet_function(app, "magicnet_supervisors_stop; import __singbox__; singbox_stop 2>/dev/null || true; import __mihomo__; mihomo_stop 2>/dev/null || true; magicnet_start_mihomo; magicnet_after_kernel_start; magicnet_supervisors_start"),
        _ => run_magicnet_function(app, "magicnet_supervisors_stop; import __singbox__; singbox_stop 2>/dev/null || true; import __mihomo__; mihomo_stop 2>/dev/null || true; magicnet_start_kernel"),
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
    println!("[info] Selected current core: {normalized}");
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

fn singbox_cmd(app: &App, action: &str) -> Result<(), String> {
    let path = app.moddir.join(".disable_sing_box");
    match action {
        "status" => {
            core_status(app);
            Ok(())
        }
        "enable" => {
            let _ = fs::remove_file(path);
            println!("[info] sing-box enabled");
            Ok(())
        }
        "disable" => {
            write_text_file(path, "")?;
            println!("[info] sing-box disabled");
            Ok(())
        }
        "toggle" if path.exists() => singbox_cmd(app, "enable"),
        "toggle" => singbox_cmd(app, "disable"),
        _ => Err("Usage: cli core sing-box {status|enable|disable|toggle}".to_string()),
    }
}

fn transparent_mode(app: &App) -> &'static str {
    fs::read_to_string(app.moddir.join(".config/magicnet/transparent-mode.conf"))
        .ok()
        .filter(|text| text.lines().any(|line| line.trim() == "MAGICNET_TRANSPARENT_MODE=tproxy"))
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

fn core_status(app: &App) {
    println!("sing-box-disabled={}", bool_file(app.moddir.join(".disable_sing_box")) as u8);
    println!("selected={}", selected_core(app));
}

fn bool_file(path: PathBuf) -> bool {
    path.exists()
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
