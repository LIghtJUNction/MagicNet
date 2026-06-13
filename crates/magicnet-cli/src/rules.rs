mod block;
mod certs;

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

use crate::{clean_lines, read_kv, run_magicnet_function, write_kv, write_text_file, App};

pub(crate) use block::block_cmd;
pub(crate) use certs::cert_cmd;

pub(crate) fn route_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => {
            route_list(app);
            Ok(())
        }
        "add-domain" | "remove-domain" => route_domain(app, args),
        "apply" => run_magicnet_function(app, "magicnet_route_apply"),
        _ => Err("Usage: cli route {list|add-domain <proxy|direct|block> <domain-suffix>|remove-domain <proxy|direct|block> <domain-suffix>|apply}".to_string()),
    }
}

fn route_list(app: &App) {
    for target in ["proxy", "direct", "block"] {
        println!("{target} domain suffixes:");
        print_lines(route_file(app, target).unwrap());
    }
}

fn route_domain(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    let domain = args.get(2).map(String::as_str).unwrap_or_default();
    if domain.is_empty() {
        return Err("Usage: cli route {add-domain|remove-domain} <proxy|direct|block> <domain-suffix>".to_string());
    }
    if domain.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return Err(format!("invalid domain suffix: {domain}"));
    }
    update_line(route_file(app, target)?, domain, args[0] == "add-domain")?;
    run_magicnet_function(app, "magicnet_route_apply")?;
    println!("[info] Route rule updated");
    Ok(())
}

fn route_file(app: &App, target: &str) -> Result<PathBuf, String> {
    match target {
        "proxy" | "direct" | "block" => {
            Ok(conf_dir(app).join(format!("route-{target}-domain-suffix.list")))
        }
        _ => Err("Target must be proxy, direct, or block".to_string()),
    }
}

pub(crate) fn capture_cmd(app: &App, args: &[String]) -> Result<(), String> {
    let dir = conf_dir(app);
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => {
            capture_list(app);
            Ok(())
        }
        "set" => capture_set(app, args),
        "enable" | "disable" => capture_toggle(app, args[0].as_str()),
        "add-app" | "remove-app" | "add-domain" | "remove-domain" => capture_rule(app, args),
        "apply" => run_magicnet_function(app, "magicnet_capture_apply"),
        _ => Err("Usage: cli capture {list|set <host> <port> [name]|enable|disable|add-app <package>|remove-app <package>|add-domain <suffix>|remove-domain <suffix>|apply}".to_string()),
    }
    .map(|_| {
        let _ = fs::create_dir_all(dir);
    })
}

pub(crate) fn app_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => {
            app_list(app);
            Ok(())
        }
        "mode" => app_mode(app, args),
        "add" => app_add(app, args),
        "add-many" => app_add_many(app, args),
        "remove" => app_remove(app, args),
        "packages" => app_packages(args),
        "apply" => run_magicnet_function(app, "magicnet_app_policy_apply"),
        _ => Err("Usage: cli app {list|packages [query]|mode <blacklist|whitelist>|add <package> [proxy|bypass]|add-many <proxy|bypass> <package...>|remove <package>|apply}".to_string()),
    }
}

fn capture_list(app: &App) {
    let conf = read_kv(app.moddir.join(".config/magicnet/capture.conf"));
    println!(
        "enabled={}",
        conf.get("MAGICNET_CAPTURE_ENABLED")
            .map(String::as_str)
            .unwrap_or("0")
    );
    println!(
        "host={}",
        conf.get("MAGICNET_CAPTURE_HOST")
            .map(String::as_str)
            .unwrap_or("192.168.1.100")
    );
    println!(
        "port={}",
        conf.get("MAGICNET_CAPTURE_PORT")
            .map(String::as_str)
            .unwrap_or("8888")
    );
    println!(
        "name={}",
        conf.get("MAGICNET_CAPTURE_NAME")
            .map(String::as_str)
            .unwrap_or("MagicNet-Capture")
    );
    println!("apps:");
    print_lines(app.moddir.join(".config/magicnet/capture-app.list"));
    println!("domain suffixes:");
    print_lines(
        app.moddir
            .join(".config/magicnet/capture-domain-suffix.list"),
    );
}

fn capture_set(app: &App, args: &[String]) -> Result<(), String> {
    let host = args.get(1).map(String::as_str).unwrap_or_default();
    let port = args.get(2).map(String::as_str).unwrap_or_default();
    let name = args
        .get(3)
        .map(String::as_str)
        .unwrap_or("MagicNet-Capture");
    if host.is_empty() || port.parse::<u16>().is_err() {
        return Err("Usage: cli capture set <host> <port> [name]".to_string());
    }
    let conf = read_kv(conf_dir(app).join("capture.conf"));
    write_kv(
        conf_dir(app).join("capture.conf"),
        &[
            (
                "MAGICNET_CAPTURE_ENABLED",
                conf.get("MAGICNET_CAPTURE_ENABLED")
                    .cloned()
                    .unwrap_or_else(|| "0".to_string()),
            ),
            ("MAGICNET_CAPTURE_HOST", host.to_string()),
            ("MAGICNET_CAPTURE_PORT", port.to_string()),
            ("MAGICNET_CAPTURE_NAME", name.to_string()),
        ],
    )?;
    println!("[info] Capture proxy set to {host}:{port}");
    Ok(())
}

fn capture_toggle(app: &App, action: &str) -> Result<(), String> {
    let enabled = if action == "enable" { "1" } else { "0" };
    let conf = read_kv(conf_dir(app).join("capture.conf"));
    write_kv(
        conf_dir(app).join("capture.conf"),
        &[
            ("MAGICNET_CAPTURE_ENABLED", enabled.to_string()),
            (
                "MAGICNET_CAPTURE_HOST",
                conf.get("MAGICNET_CAPTURE_HOST")
                    .cloned()
                    .unwrap_or_else(|| "192.168.1.100".to_string()),
            ),
            (
                "MAGICNET_CAPTURE_PORT",
                conf.get("MAGICNET_CAPTURE_PORT")
                    .cloned()
                    .unwrap_or_else(|| "8888".to_string()),
            ),
            (
                "MAGICNET_CAPTURE_NAME",
                conf.get("MAGICNET_CAPTURE_NAME")
                    .cloned()
                    .unwrap_or_else(|| "MagicNet-Capture".to_string()),
            ),
        ],
    )?;
    run_magicnet_function(app, "magicnet_capture_apply")?;
    println!(
        "[info] Capture {}",
        if enabled == "1" {
            "enabled"
        } else {
            "disabled"
        }
    );
    Ok(())
}

fn capture_rule(app: &App, args: &[String]) -> Result<(), String> {
    let value = args.get(1).map(String::as_str).unwrap_or_default();
    if value.is_empty() {
        return Err(
            "Usage: cli capture {add-app|remove-app|add-domain|remove-domain} <value>".to_string(),
        );
    }
    let path = match args[0].as_str() {
        "add-app" | "remove-app" => conf_dir(app).join("capture-app.list"),
        _ => conf_dir(app).join("capture-domain-suffix.list"),
    };
    update_line(path, value, args[0].starts_with("add"))?;
    run_magicnet_function(app, "magicnet_capture_apply")?;
    println!("[info] Capture rule updated");
    Ok(())
}

fn app_list(app: &App) {
    let conf = read_kv(app.moddir.join(".config/magicnet/app-mode.conf"));
    println!(
        "mode={}",
        conf.get("MAGICNET_APP_MODE")
            .map(String::as_str)
            .unwrap_or("blacklist")
    );
    println!("proxy apps:");
    print_lines(app_file(app, "proxy").unwrap());
    println!("bypass apps:");
    print_lines(app_file(app, "bypass").unwrap());
}

fn app_mode(app: &App, args: &[String]) -> Result<(), String> {
    let mode = args.get(1).map(String::as_str).unwrap_or_default();
    if !matches!(mode, "blacklist" | "whitelist") {
        return Err("Usage: cli app mode <blacklist|whitelist>".to_string());
    }
    write_text_file(
        conf_dir(app).join("app-mode.conf"),
        &format!("MAGICNET_APP_MODE={mode}\n"),
    )?;
    run_magicnet_function(app, "magicnet_app_policy_apply")?;
    println!("[info] App policy mode set to {mode}");
    Ok(())
}

fn app_add(app: &App, args: &[String]) -> Result<(), String> {
    let package = args.get(1).map(String::as_str).unwrap_or_default();
    let target = args.get(2).map(String::as_str).unwrap_or("proxy");
    if package.is_empty() {
        return Err("Usage: cli app add <package> [proxy|bypass]".to_string());
    }
    if !valid_package_name(package) {
        return Err(format!("invalid package name: {package}"));
    }
    let opposite = match target {
        "proxy" => "bypass",
        "bypass" => "proxy",
        _ => return Err("Target must be proxy or bypass".to_string()),
    };
    update_line(app_file(app, opposite)?, package, false)?;
    update_line(app_file(app, target)?, package, true)?;
    run_magicnet_function(app, "magicnet_app_policy_apply")?;
    println!("[info] Added {package} to {target} app list");
    Ok(())
}

fn app_add_many(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    if !matches!(target, "proxy" | "bypass") || args.len() < 3 {
        return Err("Usage: cli app add-many <proxy|bypass> <package...>".to_string());
    }
    let path = app_file(app, target)?;
    let mut lines = clean_lines(path.clone());
    let mut added = 0usize;
    for package in args.iter().skip(2).map(String::as_str) {
        if !valid_package_name(package) {
            return Err(format!("invalid package name: {package}"));
        }
        if !lines.iter().any(|line| line == package) {
            lines.push(package.to_string());
            added += 1;
        }
    }
    write_unique_lines(path, &lines)?;
    run_magicnet_function(app, "magicnet_app_policy_apply")?;
    println!("[info] Added {added} packages to {target} app list");
    Ok(())
}

fn app_remove(app: &App, args: &[String]) -> Result<(), String> {
    let package = args.get(1).map(String::as_str).unwrap_or_default();
    let target = args.get(2).map(String::as_str);
    if package.is_empty() {
        return Err("Usage: cli app remove <package> [proxy|bypass]".to_string());
    }
    if !valid_package_name(package) {
        return Err(format!("invalid package name: {package}"));
    }
    match target {
        Some("proxy" | "bypass") => {
            update_line(app_file(app, target.unwrap())?, package, false)?;
        }
        Some(_) => return Err("Target must be proxy or bypass".to_string()),
        None => {
            update_line(app_file(app, "proxy")?, package, false)?;
            update_line(app_file(app, "bypass")?, package, false)?;
        }
    }
    run_magicnet_function(app, "magicnet_app_policy_apply")?;
    println!(
        "[info] Removed {package} from {} app list",
        target.unwrap_or("both")
    );
    Ok(())
}

fn app_packages(args: &[String]) -> Result<(), String> {
    let query = args
        .get(1)
        .map(|value| value.to_lowercase())
        .unwrap_or_default();
    let output = Command::new("pm")
        .args(["list", "packages"])
        .output()
        .map_err(|err| format!("run pm list packages: {err}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    let mut packages: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().strip_prefix("package:"))
        .map(str::trim)
        .filter(|package| valid_package_name(package))
        .filter(|package| query.is_empty() || package.to_lowercase().contains(&query))
        .map(ToOwned::to_owned)
        .collect();
    packages.sort();
    packages.dedup();
    for package in packages.into_iter().take(300) {
        println!("{package}");
    }
    Ok(())
}

fn valid_package_name(package: &str) -> bool {
    let mut count = 0usize;
    for segment in package.split('.') {
        count += 1;
        let mut chars = segment.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        if !(first.is_ascii_alphabetic() || first == '_') {
            return false;
        }
        if !chars.all(|value| value.is_ascii_alphanumeric() || value == '_') {
            return false;
        }
    }
    count >= 2
}

pub(super) fn update_line(path: PathBuf, item: &str, add: bool) -> Result<(), String> {
    let mut lines: Vec<String> = clean_lines(path.clone())
        .into_iter()
        .filter(|line| line != item)
        .collect();
    if add {
        lines.push(item.trim().to_string());
    }
    write_unique_lines(path, &lines)
}

fn write_unique_lines(path: PathBuf, lines: &[String]) -> Result<(), String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for line in lines
        .iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
    {
        if seen.insert(line.to_string()) {
            out.push(line.to_string());
        }
    }
    write_text_file(path, &format!("{}\n", out.join("\n")))
}

pub(super) fn conf_dir(app: &App) -> PathBuf {
    app.moddir.join(".config/magicnet")
}

fn app_file(app: &App, target: &str) -> Result<PathBuf, String> {
    match target {
        "proxy" => Ok(conf_dir(app).join("app-proxy.list")),
        "bypass" => Ok(conf_dir(app).join("app-bypass.list")),
        _ => Err("Target must be proxy or bypass".to_string()),
    }
}

pub(super) fn print_lines(path: PathBuf) {
    for line in clean_lines(path) {
        println!("  {line}");
    }
}

pub(super) fn normalize_block_rule(rule: &str) -> String {
    let value = rule.trim();
    if value.contains(',') {
        value.to_string()
    } else {
        format!("DOMAIN-SUFFIX,{value}")
    }
}
