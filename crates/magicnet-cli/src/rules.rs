mod block;

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::service::restart_current_core;
use crate::{clean_lines, read_kv, run_magicnet_function, write_text_file, App};

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
    update_line(route_file(app, target)?, domain, args[0] == "add-domain")?;
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
        "list" => {
            app_list(app);
            Ok(())
        }
        "mode" => app_mode(app, args),
        "add" => app_add(app, args),
        "add-many" => app_add_many(app, args),
        "remove" => app_remove(app, args),
        "packages" => app_packages(args),
        "apply" => app_apply_and_restart(app),
        _ => Err("Usage: cli app {list|packages [query]|mode <blacklist|whitelist>|add <package> [proxy|bypass]|add-many <proxy|bypass> <package...>|remove <package>|apply}".to_string()),
    }
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
    app_apply_and_restart(app)?;
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
    app_apply_and_restart(app)?;
    println!("[info] Added {package} to {target} app list");
    Ok(())
}

fn app_add_many(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(1).map(String::as_str).unwrap_or_default();
    if !matches!(target, "proxy" | "bypass") || args.len() < 3 {
        return Err("Usage: cli app add-many <proxy|bypass> <package...>".to_string());
    }
    let opposite = if target == "proxy" { "bypass" } else { "proxy" };
    let path = app_file(app, target)?;
    let opposite_path = app_file(app, opposite)?;
    let mut lines = clean_lines(path.clone());
    let mut opposite_lines = clean_lines(opposite_path.clone());
    let mut added = 0usize;
    for package in args.iter().skip(2).map(String::as_str) {
        if !valid_package_name(package) {
            return Err(format!("invalid package name: {package}"));
        }
        if !lines.iter().any(|line| line == package) {
            lines.push(package.to_string());
            added += 1;
        }
        opposite_lines.retain(|line| line != package);
    }
    write_two_files_transactional(
        &opposite_path,
        &unique_lines_text(&opposite_lines),
        &path,
        &unique_lines_text(&lines),
    )?;
    app_apply_and_restart(app)?;
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
    write_text_file(path, &unique_lines_text(lines))
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

enum FileSnapshot {
    Missing,
    Present(Vec<u8>),
}

fn write_two_files_transactional(
    first_path: &Path,
    first_text: &str,
    second_path: &Path,
    second_text: &str,
) -> Result<(), String> {
    write_two_files_transactional_with_replace(
        first_path,
        first_text,
        second_path,
        second_text,
        |source, destination| fs::rename(source, destination),
    )
}

fn write_two_files_transactional_with_replace<F>(
    first_path: &Path,
    first_text: &str,
    second_path: &Path,
    second_text: &str,
    mut replace: F,
) -> Result<(), String>
where
    F: FnMut(&Path, &Path) -> io::Result<()>,
{
    let targets = [first_path, second_path];
    let contents = [first_text.as_bytes(), second_text.as_bytes()];
    let snapshots = [file_snapshot(first_path)?, file_snapshot(second_path)?];
    let stages = [
        transaction_temp_path(first_path, 1)?,
        transaction_temp_path(second_path, 2)?,
    ];

    for (index, stage) in stages.iter().enumerate() {
        if let Some(parent) = stage.parent() {
            if let Err(err) = fs::create_dir_all(parent) {
                let cleanup_errors = cleanup_transaction_temps(&stages);
                return Err(transaction_error(
                    format!("mkdir {}: {err}", parent.display()),
                    cleanup_errors,
                ));
            }
        }
        if let Err(err) = fs::write(stage, contents[index]) {
            let cleanup_errors = cleanup_transaction_temps(&stages);
            return Err(transaction_error(
                format!("stage {}: {err}", targets[index].display()),
                cleanup_errors,
            ));
        }
    }

    for index in 0..targets.len() {
        if let Err(err) = replace(&stages[index], targets[index]) {
            let mut recovery_errors = Vec::new();
            for rollback_index in (0..index).rev() {
                if let Err(restore_err) = restore_file_snapshot(
                    targets[rollback_index],
                    &snapshots[rollback_index],
                    &stages[rollback_index],
                    &mut replace,
                ) {
                    recovery_errors.push(restore_err);
                }
            }
            recovery_errors.extend(cleanup_transaction_temps(&stages));
            return Err(transaction_error(
                format!("replace {}: {err}", targets[index].display()),
                recovery_errors,
            ));
        }
    }
    Ok(())
}

fn file_snapshot(path: &Path) -> Result<FileSnapshot, String> {
    match fs::read(path) {
        Ok(contents) => Ok(FileSnapshot::Present(contents)),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(FileSnapshot::Missing),
        Err(err) => Err(format!("snapshot {}: {err}", path.display())),
    }
}

fn transaction_temp_path(path: &Path, index: usize) -> Result<PathBuf, String> {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| format!("invalid app list path: {}", path.display()))?;
    Ok(path.with_file_name(format!(
        ".{name}.magicnet-{}-{index}.tmp",
        std::process::id()
    )))
}

fn restore_file_snapshot<F>(
    path: &Path,
    snapshot: &FileSnapshot,
    stage: &Path,
    replace: &mut F,
) -> Result<(), String>
where
    F: FnMut(&Path, &Path) -> io::Result<()>,
{
    match snapshot {
        FileSnapshot::Missing => match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(format!("remove {} during rollback: {err}", path.display())),
        },
        FileSnapshot::Present(contents) => {
            fs::write(stage, contents)
                .map_err(|err| format!("stage rollback for {}: {err}", path.display()))?;
            replace(stage, path)
                .map_err(|err| format!("restore {} during rollback: {err}", path.display()))
        }
    }
}

fn cleanup_transaction_temps(stages: &[PathBuf]) -> Vec<String> {
    let mut errors = Vec::new();
    for stage in stages {
        match fs::remove_file(stage) {
            Ok(()) => {}
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => errors.push(format!("remove temporary {}: {err}", stage.display())),
        }
    }
    errors
}

fn transaction_error(original: String, recovery_errors: Vec<String>) -> String {
    if recovery_errors.is_empty() {
        original
    } else {
        format!(
            "{original}; rollback failed: {}",
            recovery_errors.join("; ")
        )
    }
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

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

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
    fn two_file_transaction_replaces_both_destinations() {
        let dir = test_dir("success");
        fs::create_dir_all(&dir).unwrap();
        let first = dir.join("app-bypass.list");
        let second = dir.join("app-proxy.list");
        fs::write(&first, "old-bypass\n").unwrap();
        fs::write(&second, "old-proxy\n").unwrap();

        write_two_files_transactional(&first, "new-bypass\n", &second, "new-proxy\n").unwrap();

        assert_eq!(fs::read_to_string(&first).unwrap(), "new-bypass\n");
        assert_eq!(fs::read_to_string(&second).unwrap(), "new-proxy\n");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn two_file_transaction_rolls_back_when_second_replace_fails() {
        let dir = test_dir("rollback");
        fs::create_dir_all(&dir).unwrap();
        let first = dir.join("app-bypass.list");
        let second = dir.join("app-proxy.list");
        fs::write(&first, "old-bypass\n").unwrap();
        fs::write(&second, "old-proxy\n").unwrap();
        let mut replace_count = 0usize;

        let error = write_two_files_transactional_with_replace(
            &first,
            "new-bypass\n",
            &second,
            "new-proxy\n",
            |source, destination| {
                replace_count += 1;
                if replace_count == 2 {
                    Err(io::Error::new(
                        io::ErrorKind::Other,
                        "injected second replace failure",
                    ))
                } else {
                    fs::rename(source, destination)
                }
            },
        )
        .unwrap_err();

        assert!(error.contains("injected second replace failure"));
        assert_eq!(fs::read_to_string(&first).unwrap(), "old-bypass\n");
        assert_eq!(fs::read_to_string(&second).unwrap(), "old-proxy\n");
        assert!(!fs::read_dir(&dir).unwrap().any(|entry| entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains(".tmp")));
        fs::remove_dir_all(dir).unwrap();
    }
}
