mod block;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::service::restart_current_core;
use crate::utils::clean_module_lines;
use crate::{clean_lines, run_magicnet_function, write_text_file, App};

pub(crate) use block::block_cmd;

pub(crate) fn route_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => {
            route_list(app);
            Ok(())
        }
        "add-domain" | "remove-domain" => route_domain(app, args),
        "apply" => route_apply_and_restart(app),
        _ => Err(route_usage()),
    }
}

fn route_list(app: &App) {
    for target in ["proxy", "direct", "block", "warp"] {
        println!("{target} domain suffixes:");
        print_lines(route_file(app, target).unwrap());
    }
}

fn route_domain(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    let domain = args.get(2).map(String::as_str).unwrap_or_default();
    if domain.is_empty() {
        return Err(route_usage());
    }
    if domain.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return Err(format!("invalid domain suffix: {domain}"));
    }
    update_line(
        app,
        route_file(app, target)?,
        domain,
        args[0] == "add-domain",
    )?;
    route_apply_and_restart(app)?;
    println!("[info] Route rule updated");
    Ok(())
}

fn route_apply_and_restart(app: &App) -> Result<(), String> {
    run_magicnet_function(app, "magicnet_route_apply")?;
    restart_current_core(app)
}

fn route_file(app: &App, target: &str) -> Result<PathBuf, String> {
    match target {
        "proxy" | "direct" | "block" | "warp" => {
            Ok(conf_dir(app).join(format!("route-{target}-domain-suffix.list")))
        }
        _ => Err("Target must be proxy, direct, block, or warp".to_string()),
    }
}

fn route_usage() -> String {
    "Usage: cli route {list|add-domain <proxy|direct|block|warp> <domain-suffix>|remove-domain <proxy|direct|block|warp> <domain-suffix>|apply}".to_string()
}

pub(crate) fn app_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => app_list(app),
        "mode" => app_mode(app, args),
        "add" => app_add(app, args),
        "add-many" => app_add_many(app, args),
        "remove" => app_remove(app, args),
        "packages" => app_packages(args),
        "apply" => app_apply_and_restart(app),
        _ => Err("Usage: cli app {list|packages [query]|mode <blacklist|whitelist>|add <package> [proxy|direct|bypass]|add-many <proxy|direct|bypass> <package...>|remove <package> [proxy|direct|bypass]|apply}".to_string()),
    }
}

fn app_list(app: &App) -> Result<(), String> {
    let mode = app_mode_value(app)?.unwrap_or_else(|| "blacklist".to_string());
    println!("mode={mode}");
    println!("proxy apps:");
    print_app_list_lines(&app_list_lines(app, "proxy")?);
    println!("direct apps:");
    print_app_list_lines(&app_list_lines(app, "direct")?);
    println!("bypass apps:");
    print_app_list_lines(&app_list_lines(app, "bypass")?);
    Ok(())
}

fn app_mode(app: &App, args: &[String]) -> Result<(), String> {
    let mode = args.get(1).map(String::as_str).unwrap_or_default();
    if !matches!(mode, "blacklist" | "whitelist") {
        return Err("Usage: cli app mode <blacklist|whitelist>".to_string());
    }
    write_text_file(
        app,
        Path::new(".config/magicnet/app-mode.conf"),
        &format!("MAGICNET_APP_MODE={mode}\n"),
    )?;
    app_apply_and_restart(app)?;
    println!("[info] App policy mode set to {mode}");
    Ok(())
}

fn app_add(app: &App, args: &[String]) -> Result<(), String> {
    let package = args.get(1).map(String::as_str).unwrap_or_default();
    let target = args.get(2).map(String::as_str).unwrap_or("proxy");
    if package.is_empty() {
        return Err("Usage: cli app add <package> [proxy|direct|bypass]".to_string());
    }
    if !valid_package_name(package) {
        return Err(format!("invalid package name: {package}"));
    }
    if !matches!(target, "proxy" | "direct" | "bypass") {
        return Err("Target must be proxy, direct, or bypass".to_string());
    }
    for other in ["proxy", "direct", "bypass"] {
        if other != target {
            update_app_list_line(app, other, package, false)?;
        }
    }
    update_app_list_line(app, target, package, true)?;
    app_apply_and_restart(app)?;
    println!("[info] Added {package} to {target} app list");
    Ok(())
}

fn app_add_many(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    if !matches!(target, "proxy" | "direct" | "bypass") || args.len() < 3 {
        return Err("Usage: cli app add-many <proxy|direct|bypass> <package...>".to_string());
    }
    let target_relative = app_file_relative(target)?;
    let mut lines = app_list_lines(app, target)?;
    let packages = args.iter().skip(2).map(String::as_str).collect::<Vec<_>>();
    let mut added = 0usize;
    for &package in &packages {
        if !valid_package_name(package) {
            return Err(format!("invalid package name: {package}"));
        }
        if !lines.iter().any(|line| line == package) {
            lines.push(package.to_string());
            added += 1;
        }
    }
    for other in ["proxy", "direct", "bypass"] {
        if other == target {
            continue;
        }
        let filtered = app_list_lines(app, other)?
            .into_iter()
            .filter(|line| !packages.iter().any(|package| *package == line))
            .collect::<Vec<_>>();
        write_text_file(
            app,
            Path::new(app_file_relative(other)?),
            &unique_lines_text(&filtered),
        )?;
    }
    write_text_file(app, Path::new(target_relative), &unique_lines_text(&lines))?;
    app_apply_and_restart(app)?;
    println!("[info] Added {added} packages to {target} app list");
    Ok(())
}

fn app_remove(app: &App, args: &[String]) -> Result<(), String> {
    let package = args.get(1).map(String::as_str).unwrap_or_default();
    let target = args.get(2).map(String::as_str);
    if package.is_empty() {
        return Err("Usage: cli app remove <package> [proxy|direct|bypass]".to_string());
    }
    if !valid_package_name(package) {
        return Err(format!("invalid package name: {package}"));
    }
    match target {
        Some("proxy" | "direct" | "bypass") => {
            update_app_list_line(app, target.unwrap(), package, false)?;
        }
        Some(_) => return Err("Target must be proxy, direct, or bypass".to_string()),
        None => {
            update_app_list_line(app, "proxy", package, false)?;
            update_app_list_line(app, "direct", package, false)?;
            update_app_list_line(app, "bypass", package, false)?;
        }
    }
    app_apply_and_restart(app)?;
    println!(
        "[info] Removed {package} from {} app list",
        target.unwrap_or("both")
    );
    Ok(())
}

fn app_apply_and_restart(app: &App) -> Result<(), String> {
    run_magicnet_function(app, "magicnet_app_policy_apply")?;
    restart_current_core(app)
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

pub(super) fn update_line(app: &App, path: PathBuf, item: &str, add: bool) -> Result<(), String> {
    let mut lines: Vec<String> = clean_lines(path.clone())
        .into_iter()
        .filter(|line| line != item)
        .collect();
    if add {
        lines.push(item.trim().to_string());
    }
    write_unique_lines(app, path, &lines)
}

fn write_unique_lines(app: &App, path: PathBuf, lines: &[String]) -> Result<(), String> {
    let relative = path
        .strip_prefix(&app.moddir)
        .map_err(|_| "refusing to write an app list outside the module root".to_string())?;
    write_text_file(app, relative, &unique_lines_text(lines))
}

fn unique_lines_text(lines: &[String]) -> String {
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
    format!("{}\n", out.join("\n"))
}

pub(super) fn conf_dir(app: &App) -> PathBuf {
    app.moddir.join(".config/magicnet")
}

fn app_file_relative(target: &str) -> Result<&'static str, String> {
    match target {
        "proxy" => Ok(".config/magicnet/app-proxy.list"),
        "direct" => Ok(".config/magicnet/app-direct.list"),
        "bypass" => Ok(".config/magicnet/app-bypass.list"),
        _ => Err("Target must be proxy, direct, or bypass".to_string()),
    }
}

fn app_mode_value(app: &App) -> Result<Option<String>, String> {
    Ok(
        clean_module_lines(app, Path::new(".config/magicnet/app-mode.conf"))?
            .into_iter()
            .filter_map(|line| {
                let (key, value) = line.split_once('=')?;
                if key.trim() == "MAGICNET_APP_MODE" {
                    Some(
                        value
                            .trim()
                            .trim_matches('"')
                            .trim_matches('\'')
                            .to_string(),
                    )
                } else {
                    None
                }
            })
            .next_back(),
    )
}

fn app_list_lines(app: &App, target: &str) -> Result<Vec<String>, String> {
    clean_module_lines(app, Path::new(app_file_relative(target)?))
}

fn update_app_list_line(app: &App, target: &str, item: &str, add: bool) -> Result<(), String> {
    let relative = app_file_relative(target)?;
    let mut lines: Vec<String> = app_list_lines(app, target)?
        .into_iter()
        .filter(|line| line != item)
        .collect();
    if add {
        lines.push(item.trim().to_string());
    }
    write_text_file(app, Path::new(relative), &unique_lines_text(&lines))
}

fn print_app_list_lines(lines: &[String]) {
    for line in lines {
        println!("  {line}");
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

pub(super) fn normalize_allow_rule(rule: &str) -> Result<String, String> {
    let value = rule.trim();
    let (kind, payload) = match value.split_once(',') {
        Some((kind, payload)) => (kind.trim().to_ascii_uppercase(), payload.trim()),
        None => ("DOMAIN-SUFFIX".to_string(), value),
    };
    if payload.is_empty() {
        return Err("invalid allow rule: missing domain or keyword".to_string());
    }

    match kind.as_str() {
        "DOMAIN" | "DOMAIN-SUFFIX" => {
            let host = normalize_allow_host(payload)?;
            Ok(format!("{kind},{host}"))
        }
        "DOMAIN-KEYWORD" => {
            if payload.chars().any(char::is_whitespace) {
                return Err("invalid allow rule: keyword must not contain whitespace".to_string());
            }
            Ok(format!("{kind},{}", payload.to_ascii_lowercase()))
        }
        _ => Err(format!(
            "invalid allow rule type: {kind}; expected DOMAIN, DOMAIN-SUFFIX, or DOMAIN-KEYWORD"
        )),
    }
}

fn normalize_allow_host(value: &str) -> Result<String, String> {
    let mut authority = value;
    if let Some(scheme_end) = value.find("://") {
        let scheme = &value[..scheme_end];
        if !scheme.eq_ignore_ascii_case("http") && !scheme.eq_ignore_ascii_case("https") {
            return Err(format!(
                "unsupported allow rule URL scheme: {scheme}; expected http or https"
            ));
        }
        authority = &value[scheme_end + 3..];
    }
    authority = authority.split(['/', '?', '#']).next().unwrap_or_default();
    authority = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    if authority.is_empty() {
        return Err("invalid allow rule URL: missing host".to_string());
    }

    let host = if let Some(bracketed) = authority.strip_prefix('[') {
        let Some(end) = bracketed.find(']') else {
            return Err("invalid allow rule host".to_string());
        };
        let suffix = &bracketed[end + 1..];
        if !suffix.is_empty() && (!suffix.starts_with(':') || !valid_allow_port(&suffix[1..])) {
            return Err("invalid allow rule URL port".to_string());
        }
        &bracketed[..end]
    } else if let Some((host, port)) = authority.rsplit_once(':') {
        if host.contains(':') || !valid_allow_port(port) {
            return Err("invalid allow rule URL port".to_string());
        }
        host
    } else {
        authority
    };

    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty()
        || host.chars().any(|character| {
            character.is_whitespace() || matches!(character, '/' | '?' | '#' | ',' | '@' | ':')
        })
    {
        return Err("invalid allow rule host".to_string());
    }
    Ok(host)
}

fn valid_allow_port(port: &str) -> bool {
    port.is_empty()
        || (port.bytes().all(|byte| byte.is_ascii_digit()) && port.parse::<u16>().is_ok())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::App;

    use super::*;

    fn test_dir(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "magicnet-rules-{name}-{}-{stamp}",
            std::process::id()
        ))
    }

    #[test]
    fn app_list_transaction_replaces_both_destinations() {
        let dir = test_dir("success");
        let module_root = dir.join("module");
        let config = module_root.join(".config/magicnet");
        fs::create_dir_all(&config).unwrap();
        let app = App::for_test(module_root);
        let first = config.join("app-bypass.list");
        let second = config.join("app-proxy.list");
        fs::write(&first, "old-bypass\n").unwrap();
        fs::write(&second, "old-proxy\n").unwrap();

        crate::utils::replace_module_text_files_transactionally(
            &app,
            Path::new(".config/magicnet/app-bypass.list"),
            "new-bypass\n",
            Path::new(".config/magicnet/app-proxy.list"),
            "new-proxy\n",
        )
        .unwrap();

        assert_eq!(fs::read_to_string(&first).unwrap(), "new-bypass\n");
        assert_eq!(fs::read_to_string(&second).unwrap(), "new-proxy\n");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn app_list_rejects_symlinked_app_mode_config() {
        for link_kind in ["final", "intermediate"] {
            let dir = test_dir(&format!("app-mode-{link_kind}"));
            let module_root = dir.join("module");
            let outside = dir.join("outside");
            let outside_mode = outside.join("magicnet/app-mode.conf");
            fs::create_dir_all(outside_mode.parent().unwrap()).unwrap();
            fs::write(&outside_mode, "MAGICNET_APP_MODE=whitelist\n").unwrap();

            match link_kind {
                "final" => {
                    let mode_path = module_root.join(".config/magicnet/app-mode.conf");
                    fs::create_dir_all(mode_path.parent().unwrap()).unwrap();
                    symlink(&outside_mode, &mode_path).unwrap();
                }
                "intermediate" => {
                    fs::create_dir_all(&module_root).unwrap();
                    symlink(&outside, module_root.join(".config")).unwrap();
                }
                _ => unreachable!(),
            }

            let app = App::for_test(module_root);
            assert!(
                app_list(&app).is_err(),
                "{link_kind} app-mode symlink was followed"
            );
            assert_eq!(
                fs::read_to_string(&outside_mode).unwrap(),
                "MAGICNET_APP_MODE=whitelist\n"
            );
            fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn allow_rule_normalization_extracts_url_hosts() {
        assert_eq!(
            normalize_allow_rule("https://Forum.Mobilism.org.:443/path?q=1#topic").unwrap(),
            "DOMAIN-SUFFIX,forum.mobilism.org"
        );
        assert_eq!(
            normalize_allow_rule("domain,HTTP://Ads.Example.COM:8080/banner").unwrap(),
            "DOMAIN,ads.example.com"
        );
    }

    #[test]
    fn allow_rule_normalization_canonicalizes_domains_and_keywords() {
        assert_eq!(
            normalize_allow_rule("Example.COM.").unwrap(),
            "DOMAIN-SUFFIX,example.com"
        );
        assert_eq!(
            normalize_allow_rule("domain-keyword,Sponsor").unwrap(),
            "DOMAIN-KEYWORD,sponsor"
        );
    }

    #[test]
    fn allow_rule_normalization_rejects_invalid_urls() {
        assert!(normalize_allow_rule("DOMAIN-SUFFIX,ftp://example.com").is_err());
        assert!(normalize_allow_rule("DOMAIN,https://").is_err());
        assert!(normalize_allow_rule("DOMAIN-SUFFIX,https:///missing-host").is_err());
    }
}
