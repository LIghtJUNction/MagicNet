use std::fs;
use std::process::Command;

use crate::{decode_base64, diagnostics::redact, run_magicnet_function, write_text_file, App};

pub(crate) fn api_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or_default() {
        "ui" => {
            api_ui(app, args.get(1).map(String::as_str).unwrap_or("current"));
            Ok(())
        }
        "groups" => curl(app, "/providers/proxies"),
        "conns" => curl(app, "/connections"),
        "stats" => curl(app, "/traffic"),
        "close-all" => curl_delete(app, "/connections"),
        _ => Err("Usage: cli api {ui [current|mihomo|sing-box|all]|groups|conns|stats|close-all}".to_string()),
    }
}

pub(crate) fn webui_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            webui_status(app);
            Ok(())
        }
        "install-local" => install_local(app, args),
        _ => Err("Usage: cli webui {status|install-local <download-url> [name]}".to_string()),
    }
}

pub(crate) fn backup_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("export") {
        "export" => {
            let password = args.get(1).map(String::as_str).unwrap_or("");
            let text = backup_text(app, password);
            println!("{}", crate::encode_base64(text.as_bytes()));
            Ok(())
        }
        "restore" => {
            let _password = args.get(1).map(String::as_str).unwrap_or("");
            let payload = args.get(2).map(String::as_str).unwrap_or_default();
            if payload.is_empty() {
                return Err("Usage: cli backup restore [password|-] <base64>".to_string());
            }
            let bytes = decode_base64(payload)?;
            let text = String::from_utf8(bytes).map_err(|err| format!("backup is not UTF-8: {err}"))?;
            restore_backup(app, &text)?;
            run_magicnet_function(app, "magicnet_apply_runtime_config")?;
            println!("[info] Backup restored");
            Ok(())
        }
        _ => Err("Usage: cli backup {export [password]|restore [password|-] <base64>}".to_string()),
    }
}

fn curl(app: &App, path: &str) -> Result<(), String> {
    run_curl(&["-fsS", "--max-time", "4", &format!("{}{}", app.api, path)])
}

fn curl_delete(app: &App, path: &str) -> Result<(), String> {
    run_curl(&["-fsS", "-X", "DELETE", "--max-time", "4", &format!("{}{}", app.api, path)])
}

fn run_curl(args: &[&str]) -> Result<(), String> {
    let output = Command::new("curl")
        .args(args)
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    print!("{}", String::from_utf8_lossy(&output.stdout));
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn webui_status(app: &App) {
    let local_dir = app.moddir.join(".config/sing-box/zashboard");
    println!("local_dir={}", local_dir.display());
    println!("local_ready={}", local_dir.join("index.html").exists() as u8);
    println!("sing-box={}", app.singbox_webui);
    println!("mihomo={}", app.mihomo_webui);
    println!(
        "version={}",
        fs::read_to_string(app.moddir.join("zashboard.version"))
            .unwrap_or_else(|_| "unknown".to_string())
            .lines()
            .next()
            .unwrap_or("unknown")
    );
}

fn api_ui(app: &App, target: &str) {
    match target {
        "sing-box" | "singbox" => println!("{}", app.singbox_webui),
        "mihomo" | "clash" => println!("{}", app.mihomo_webui),
        "all" => {
            println!("mihomo={}", app.mihomo_webui);
            println!("sing-box={}", app.singbox_webui);
        }
        _ if crate::pid_summary("sing-box") != "stopped" => println!("{}", app.singbox_webui),
        _ => println!("{}", app.mihomo_webui),
    }
}

fn install_local(app: &App, args: &[String]) -> Result<(), String> {
    let url = args.get(1).map(String::as_str).unwrap_or_default();
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("Usage: cli webui install-local <download-url> [name]".to_string());
    }
    let name = args.get(2).map(String::as_str).unwrap_or("zashboard");
    let tmp = app.moddir.join(".tmp/webui-panel.zip");
    let target = app.moddir.join(".config/sing-box/zashboard");
    if let Some(parent) = tmp.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    let status = Command::new("curl")
        .args(["-fL", "--max-time", "60", "-o"])
        .arg(&tmp)
        .arg(url)
        .status()
        .map_err(|err| format!("download panel: {err}"))?;
    if !status.success() {
        return Err("download panel failed".to_string());
    }
    let backup = target.with_extension("bak");
    let _ = fs::remove_dir_all(&backup);
    if target.exists() {
        let _ = fs::rename(&target, &backup);
    }
    fs::create_dir_all(&target).map_err(|err| format!("mkdir {}: {err}", target.display()))?;
    let status = Command::new("unzip")
        .arg("-oq")
        .arg(&tmp)
        .arg("-d")
        .arg(&target)
        .status()
        .map_err(|err| format!("unzip panel: {err}"))?;
    if !status.success() || !contains_index(&target) {
        let _ = fs::remove_dir_all(&target);
        let _ = fs::rename(&backup, &target);
        return Err("panel zip does not contain index.html".to_string());
    }
    write_text_file(app.moddir.join("zashboard.version"), &format!("{name}\n"))?;
    run_magicnet_function(app, "magicnet_singbox_apply_zashboard; magicnet_mihomo_apply_zashboard")?;
    println!("[info] Installed local panel {name}");
    Ok(())
}

fn contains_index(dir: &std::path::Path) -> bool {
    if dir.join("index.html").exists() {
        return true;
    }
    fs::read_dir(dir)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| entry.path().is_dir() && contains_index(&entry.path()))
}

fn backup_text(app: &App, password: &str) -> String {
    let mut out = String::new();
    out.push_str("MagicNet backup v1\n");
    out.push_str(&format!("password_set={}\n", (!password.is_empty()) as u8));
    for rel in backup_files() {
        let path = app.moddir.join(rel);
        out.push_str(&format!("\n--- {rel}\n"));
        let text = fs::read_to_string(path).unwrap_or_default();
        out.push_str(&redact(&text));
        out.push('\n');
    }
    out
}

fn restore_backup(app: &App, text: &str) -> Result<(), String> {
    let mut current: Option<String> = None;
    let mut buf = String::new();
    for line in text.lines() {
        if let Some(path) = line.strip_prefix("--- ") {
            flush_restore(app, current.take(), &buf)?;
            current = Some(path.to_string());
            buf.clear();
        } else if current.is_some() {
            buf.push_str(line);
            buf.push('\n');
        }
    }
    flush_restore(app, current, &buf)
}

fn flush_restore(app: &App, rel: Option<String>, text: &str) -> Result<(), String> {
    let Some(rel) = rel else {
        return Ok(());
    };
    if !backup_files().contains(&rel.as_str()) {
        return Ok(());
    }
    write_text_file(app.moddir.join(rel), text)
}

fn backup_files() -> &'static [&'static str] {
    &[
        ".config/magicnet/app-mode.conf",
        ".config/magicnet/app-proxy.list",
        ".config/magicnet/app-bypass.list",
        ".config/magicnet/block.conf",
        ".config/magicnet/block-domain-suffix.list",
        ".config/magicnet/block-allow-rules.list",
        ".config/magicnet/capture.conf",
        ".config/magicnet/capture-app.list",
        ".config/magicnet/capture-domain-suffix.list",
    ]
}
