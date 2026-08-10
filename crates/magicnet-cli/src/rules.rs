mod block;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::service::restart_current_core;
use crate::utils::{clean_module_lines, replace_module_text_files_transactionally};
use crate::{clean_lines, run_magicnet_function, write_text_file, App};

pub(crate) use block::block_cmd;

const APP_POLICY_TARGETS: [&str; 3] = ["proxy", "direct", "bypass"];

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
        "recommendations" => app_recommendations(),
        "apply" => app_apply_and_restart(app),
        _ => Err("Usage: cli app {list|packages [query]|recommendations|mode <blacklist|whitelist>|add <package> [proxy|direct|bypass]|add-many <proxy|direct|bypass> <package...>|remove <package> [proxy|direct|bypass]|apply}".to_string()),
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
    let target_index = app_policy_target_index(target)?;
    let mut lists = app_policy_lists(app)?;
    for lines in &mut lists {
        lines.retain(|line| line != package);
    }
    lists[target_index].push(package.to_string());
    write_app_policy_lists_transactionally(app, &lists)?;
    app_apply_and_restart(app)?;
    println!("[info] Added {package} to {target} app list");
    Ok(())
}

fn app_add_many(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    if !matches!(target, "proxy" | "direct" | "bypass") || args.len() < 3 {
        return Err("Usage: cli app add-many <proxy|direct|bypass> <package...>".to_string());
    }
    let target_index = app_policy_target_index(target)?;
    let packages = args.iter().skip(2).map(String::as_str).collect::<Vec<_>>();
    for &package in &packages {
        if !valid_package_name(package) {
            return Err(format!("invalid package name: {package}"));
        }
    }
    let mut lists = app_policy_lists(app)?;
    let mut added = 0usize;
    for &package in &packages {
        let already_targeted = lists[target_index].iter().any(|line| line == package);
        for lines in &mut lists {
            lines.retain(|line| line != package);
        }
        if !already_targeted {
            added += 1;
        }
        lists[target_index].push(package.to_string());
    }
    write_app_policy_lists_transactionally(app, &lists)?;
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
    let mut lists = app_policy_lists(app)?;
    match target {
        Some("proxy" | "direct" | "bypass") => {
            lists[app_policy_target_index(target.unwrap())?].retain(|line| line != package)
        }
        Some(_) => return Err("Target must be proxy, direct, or bypass".to_string()),
        None => lists
            .iter_mut()
            .for_each(|lines| lines.retain(|line| line != package)),
    }
    write_app_policy_lists_transactionally(app, &lists)?;
    app_apply_and_restart(app)?;
    println!(
        "[info] Removed {package} from {} app list",
        target.unwrap_or("all")
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
        return Err(command_failure_message(
            "query Android VPN services",
            &output,
        ));
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

fn command_failure_message(operation: &str, output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let detail = stderr.trim();
    if detail.is_empty() {
        format!("{operation} failed: {}", output.status)
    } else {
        format!("{operation} failed: {detail}")
    }
}

fn app_recommendations() -> Result<(), String> {
    let output = Command::new("cmd")
        .args([
            "package",
            "query-services",
            "--brief",
            "-a",
            "android.net.VpnService",
        ])
        .output()
        .map_err(|err| format!("query Android VPN services: {err}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    for package in vpn_service_packages(&String::from_utf8_lossy(&output.stdout)) {
        println!("{package}");
    }
    Ok(())
}

fn vpn_service_packages(output: &str) -> Vec<String> {
    let mut packages = output
        .lines()
        .filter_map(|line| line.trim().split_once('/').map(|(package, _)| package))
        .filter(|package| valid_package_name(package))
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    packages.sort();
    packages.dedup();
    packages
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

fn app_policy_target_index(target: &str) -> Result<usize, String> {
    APP_POLICY_TARGETS
        .iter()
        .position(|candidate| *candidate == target)
        .ok_or_else(|| "Target must be proxy, direct, or bypass".to_string())
}

fn app_policy_lists(app: &App) -> Result<[Vec<String>; 3], String> {
    Ok([
        app_list_lines(app, APP_POLICY_TARGETS[0])?,
        app_list_lines(app, APP_POLICY_TARGETS[1])?,
        app_list_lines(app, APP_POLICY_TARGETS[2])?,
    ])
}

fn write_app_policy_lists_transactionally(
    app: &App,
    lists: &[Vec<String>; 3],
) -> Result<(), String> {
    let texts: [String; 3] = std::array::from_fn(|index| unique_lines_text(&lists[index]));
    replace_module_text_files_transactionally(
        app,
        &[
            (
                Path::new(app_file_relative(APP_POLICY_TARGETS[0])?),
                texts[0].as_str(),
            ),
            (
                Path::new(app_file_relative(APP_POLICY_TARGETS[1])?),
                texts[1].as_str(),
            ),
            (
                Path::new(app_file_relative(APP_POLICY_TARGETS[2])?),
                texts[2].as_str(),
            ),
        ],
    )
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
    fn app_list_transaction_replaces_all_destinations() {
        let dir = test_dir("success");
        let module_root = dir.join("module");
        let config = module_root.join(".config/magicnet");
        fs::create_dir_all(&config).unwrap();
        let app = App::for_test(module_root);
        let proxy = config.join("app-proxy.list");
        let direct = config.join("app-direct.list");
        let bypass = config.join("app-bypass.list");
        fs::write(&proxy, "old-proxy\n").unwrap();
        fs::write(&direct, "old-direct\n").unwrap();
        fs::write(&bypass, "old-bypass\n").unwrap();

        write_app_policy_lists_transactionally(
            &app,
            &[
                vec!["new-proxy".to_string()],
                vec!["new-direct".to_string()],
                vec!["new-bypass".to_string()],
            ],
        )
        .unwrap();

        assert_eq!(fs::read_to_string(&proxy).unwrap(), "new-proxy\n");
        assert_eq!(fs::read_to_string(&direct).unwrap(), "new-direct\n");
        assert_eq!(fs::read_to_string(&bypass).unwrap(), "new-bypass\n");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn vpn_recommendations_are_discovered_from_service_components() {
        let output = r#"
3 services found:
  Service #0:
    com.example.vpn/.TunnelService
  Service #1:
    com.example.vpn/com.example.vpn.SecondaryService
  Service #2:
    invalid-package/.VpnService
"#;
        assert_eq!(
            vpn_service_packages(output),
            vec!["com.example.vpn".to_string()]
        );
    }

    #[test]
    fn command_failure_message_falls_back_to_exit_status() {
        let output = Command::new("sh").args(["-c", "exit 7"]).output().unwrap();
        let message = command_failure_message("query Android VPN services", &output);
        assert!(message.starts_with("query Android VPN services failed:"));
        assert!(message.contains('7'));
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
