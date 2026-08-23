use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::json;
use sha2::{Digest, Sha256};

use crate::connection_control::{
    close_connections_through_chain, close_matching_connections, close_top_connections,
    print_close_all_summary,
};
use crate::node_delay::encode_path_segment;
use crate::selector_store;
use crate::service::{
    apply_config, apply_config_preserving_hotspot_watchdog, singbox_webui, with_config_apply_lock,
};
use crate::subscriptions::{download_pinned_https_url, validate_subscription_url};
use crate::{run_bounded_command, run_magicnet_function, write_text_file, App};

const PANEL_MAX_BYTES: usize = 32 * 1024 * 1024;
const PANEL_MAX_ENTRY_BYTES: u64 = 32 * 1024 * 1024;
const PANEL_MAX_UNPACKED_BYTES: u64 = 128 * 1024 * 1024;
const PANEL_MAX_ENTRIES: usize = 4096;
const PANEL_MAX_PATH_BYTES: usize = 512;
const PANEL_MAX_PATH_DEPTH: usize = 16;
const PANEL_COMMAND_TIMEOUT: Duration = Duration::from_secs(30);
const PANEL_COMMAND_OUTPUT_LIMIT: usize = 2 * 1024 * 1024;

struct PanelInstallGuard(File);

impl Drop for PanelInstallGuard {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn panel_install_lock(app: &App) -> Result<PanelInstallGuard, String> {
    let path = app.moddir.join(".state/webui-panel-install.lock");
    let parent = path.parent().ok_or("panel lock has no parent")?;
    fs::create_dir_all(parent).map_err(|err| format!("create panel lock directory: {err}"))?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&path)
        .map_err(|err| format!("open panel install lock: {err}"))?;
    let metadata = file
        .metadata()
        .map_err(|err| format!("inspect panel install lock: {err}"))?;
    if !metadata.is_file() || metadata.nlink() != 1 {
        return Err("panel install lock is not a private regular file".to_string());
    }
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("protect panel install lock: {err}"))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(format!(
            "lock panel install: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(PanelInstallGuard(file))
}

pub(crate) fn api_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or_default() {
        "ui" => {
            api_ui(app, args.get(1).map(String::as_str).unwrap_or("current"));
            Ok(())
        }
        "groups" => curl(app, "/providers/proxies"),
        "proxies" => curl(app, "/proxies"),
        "select" => select_proxy(
            app,
            args.get(1).map(String::as_str).unwrap_or_default(),
            &args[2..].join(" "),
        ),
        "replay" => replay_persisted_selectors(app, true),
        "replay-startup" => replay_persisted_selectors(app, false),
        "conns" => curl(app, "/connections"),
        "stats" => curl(app, "/traffic"),
        "close" => close_connection(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "close-top" => close_top_connections(app, args.get(1).map(String::as_str).unwrap_or("3")),
        "close-matching" => close_matching_connections(app, &args[1..].join(" ")),
        "close-all" => print_close_all_summary(app),
        _ => Err(
            "Usage: cli api {ui [current|sing-box|all]|groups|proxies|select <group> <node>|replay|replay-startup|conns|stats|close <id>|close-top [count]|close-matching <query>|close-all}"
                .to_string(),
        ),
    }
}

fn replay_persisted_selectors(app: &App, refresh_stale_policy: bool) -> Result<(), String> {
    sync_persisted_hotspot_offload(app, refresh_stale_policy)?;
    let applied = selector_store::replay(app)?;
    println!("[info] replayed {applied} persisted selectors");
    Ok(())
}

fn sync_persisted_hotspot_offload(app: &App, refresh_stale_policy: bool) -> Result<(), String> {
    let member = selector_store::selected(app, "hotspot").unwrap_or_else(|| "direct".to_string());
    if member == "proxy" {
        let result = (|| {
            run_magicnet_function(app, "magicnet_hotspot_offload_enable")
                .map_err(|err| format!("disable hotspot offload: {err}"))?;
            run_magicnet_function(app, "magicnet_hotspot_reconcile")
                .map_err(|err| format!("reconcile hotspot TUN route: {err}"))?;
            run_magicnet_function(app, "magicnet_hotspot_watchdog_start")
                .map_err(|err| format!("start hotspot route watcher: {err}"))?;
            Ok(())
        })();
        if let Err(error) = result {
            rollback_hotspot_enable(app);
            return Err(error);
        }
    } else {
        if let Err(err) = run_magicnet_function(app, "magicnet_hotspot_offload_restore") {
            eprintln!("[warning] persisted hotspot offload state could not be restored: {err}");
        }
        let _ = run_magicnet_function(app, "magicnet_hotspot_watchdog_stop");
        let _ = run_magicnet_function(app, "magicnet_hotspot_route_cleanup");
        if refresh_stale_policy {
            if let Err(err) = refresh_hotspot_policy_if_stale(app) {
                eprintln!("[warning] stale hotspot source policy could not be removed: {err}");
            }
        }
    }
    Ok(())
}

fn refresh_hotspot_policy_if_stale(app: &App) -> Result<(), String> {
    if run_magicnet_function(app, "magicnet_singbox_hotspot_policy_current").is_err() {
        apply_config_preserving_hotspot_watchdog(app)?;
    }
    Ok(())
}

fn rollback_hotspot_enable(app: &App) {
    let _ = select_proxy(app, "hotspot", "direct");
    let _ = selector_store::save(app, "hotspot", "direct");
    let _ = run_magicnet_function(app, "magicnet_hotspot_watchdog_stop");
    let _ = run_magicnet_function(app, "magicnet_hotspot_offload_restore");
    let _ = run_magicnet_function(app, "magicnet_hotspot_route_cleanup");
}

pub(crate) fn hotspot_cmd(app: &App, args: &[String]) -> Result<(), String> {
    let action = args.first().map(String::as_str).unwrap_or("status");
    match action {
        "status" => {
            let member = hotspot_member(app);
            println!("enabled={}", usize::from(member == "proxy"));
            println!("outbound={member}");
            run_magicnet_function(app, "magicnet_hotspot_offload_status")?;
            run_magicnet_function(app, "magicnet_hotspot_route_status")?;
            Ok(())
        }
        "reconcile" => {
            run_magicnet_function(app, "magicnet_hotspot_reconcile")?;
            refresh_hotspot_policy_if_stale(app)
        }
        "enable" | "disable" => {
            let member = if action == "enable" {
                "proxy"
            } else {
                "direct"
            };
            if action == "enable" {
                run_magicnet_function(app, "magicnet_hotspot_offload_enable")?;
            }
            let selected = if curl_get_json(app, "/proxies").is_ok() {
                select_proxy(app, "hotspot", member)
            } else {
                selector_store::save(app, "hotspot", member).map(|()| {
                    println!(
                        "[info] hotspot outbound set to {member}; applies when sing-box starts"
                    );
                })
            };
            if let Err(error) = selected {
                if action == "enable" {
                    rollback_hotspot_enable(app);
                }
                return Err(error);
            }
            if action == "enable" {
                // The hotspot source rule is consumed at sing-box startup.
                // Materialize the active downstream subnet and restart only
                // when the effective runtime fingerprint changed.
                if let Err(error) = apply_config(app) {
                    rollback_hotspot_enable(app);
                    return Err(format!("apply hotspot TUN policy: {error}"));
                }
                if let Err(error) = run_magicnet_function(app, "magicnet_hotspot_reconcile") {
                    rollback_hotspot_enable(app);
                    return Err(format!("apply hotspot TUN route: {error}"));
                }
                if let Err(error) = run_magicnet_function(app, "magicnet_hotspot_watchdog_start") {
                    rollback_hotspot_enable(app);
                    return Err(format!("start hotspot route watcher: {error}"));
                }
            }
            if action == "disable" {
                run_magicnet_function(app, "magicnet_hotspot_offload_restore")?;
                let stop_result = run_magicnet_function(app, "magicnet_hotspot_watchdog_stop");
                let cleanup_result = run_magicnet_function(app, "magicnet_hotspot_route_cleanup");
                stop_result?;
                cleanup_result?;
                refresh_hotspot_policy_if_stale(app)?;
            }
            Ok(())
        }
        _ => Err("Usage: cli hotspot {status|enable|disable|reconcile}".to_string()),
    }
}

fn hotspot_member(app: &App) -> String {
    let runtime = curl_get_json(app, "/proxies").ok();
    runtime
        .as_ref()
        .and_then(hotspot_member_from_api)
        .map(str::to_string)
        .or_else(|| selector_store::selected(app, "hotspot"))
        .filter(|member| matches!(member.as_str(), "direct" | "proxy"))
        .unwrap_or_else(|| "direct".to_string())
}

fn hotspot_member_from_api(root: &serde_json::Value) -> Option<&str> {
    root.get("proxies")
        .and_then(|proxies| proxies.get("hotspot"))
        .and_then(|hotspot| hotspot.get("now"))
        .and_then(serde_json::Value::as_str)
        .filter(|member| matches!(*member, "direct" | "proxy"))
}

pub(crate) fn webui_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            webui_status(app);
            Ok(())
        }
        "verify" => webui_verify(app),
        "install-local" => install_local(app, args),
        "payload" => crate::webui_payload::webui_payload_cmd(app, &args[1..]),
        _ => Err(
            "Usage: cli webui {status|verify|install-local <https-download-url> <sha256> [name]|payload {create <tmp|subscription> <safe-basename>|append <tmp|subscription> <safe-basename> <base64-chunk>|remove <tmp|subscription> <safe-basename>|apply-subscription <safe-basename>|apply-subscription-source <safe-basename>}}".to_string(),
        ),
    }
}

fn curl(app: &App, path: &str) -> Result<(), String> {
    run_curl(&["-fsS", "--max-time", "4", &format!("{}{}", app.api, path)])
}

fn curl_delete(app: &App, path: &str) -> Result<(), String> {
    run_curl(&[
        "-fsS",
        "-X",
        "DELETE",
        "--max-time",
        "4",
        &format!("{}{}", app.api, path),
    ])
}

fn curl_put_json(app: &App, path: &str, payload: &str) -> Result<(), String> {
    run_curl(&[
        "-fsS",
        "-X",
        "PUT",
        "-H",
        "Content-Type: application/json",
        "--data",
        payload,
        "--max-time",
        "5",
        &format!("{}{}", app.api, path),
    ])
}

fn curl_patch_json(app: &App, path: &str, payload: &str) -> Result<(), String> {
    run_curl(&[
        "-fsS",
        "-X",
        "PATCH",
        "-H",
        "Content-Type: application/json",
        "--data",
        payload,
        "--max-time",
        "5",
        &format!("{}{}", app.api, path),
    ])
}

pub(crate) fn clash_mode_cmd(app: &App, args: &[String]) -> Result<(), String> {
    let requested = args.first().map(String::as_str).unwrap_or_default();
    if requested.is_empty() {
        println!("{}", current_clash_mode(app)?);
        return Ok(());
    }
    set_clash_mode(app, requested)?;
    println!(
        "[info] sing-box mode set to {}",
        normalize_clash_mode(requested)?
    );
    Ok(())
}

pub(crate) fn current_clash_mode(app: &App) -> Result<String, String> {
    let value = curl_get_json(app, "/configs")?;
    let mode = value
        .get("mode")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("rule");
    Ok(normalize_clash_mode(mode)?.to_string())
}

pub(crate) fn set_clash_mode(app: &App, mode: &str) -> Result<(), String> {
    let mode = normalize_clash_mode(mode)?;
    let payload = json!({ "mode": mode }).to_string();
    curl_patch_json(app, "/configs", &payload)?;
    if let Err(err) = curl_delete(app, "/connections") {
        eprintln!("[warn] mode changed, but stale connections could not be closed: {err}");
    }
    Ok(())
}

fn normalize_clash_mode(mode: &str) -> Result<&'static str, String> {
    match mode.trim().to_ascii_lowercase().as_str() {
        "rule" => Ok("rule"),
        "global" => Ok("global"),
        "direct" => Ok("direct"),
        _ => Err("Mode must be rule, global, or direct".to_string()),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum SelectorCleanupOutcome {
    Complete(crate::connection_control::ConnectionCloseSummary),
    Degraded(String),
}

fn classify_selector_cleanup(
    result: Result<crate::connection_control::ConnectionCloseSummary, String>,
) -> SelectorCleanupOutcome {
    match result {
        Ok(summary) => SelectorCleanupOutcome::Complete(summary),
        Err(error) => SelectorCleanupOutcome::Degraded(error),
    }
}

pub(crate) fn select_proxy(app: &App, group: &str, node: &str) -> Result<(), String> {
    let clean_group = group.trim();
    let clean_node = node.trim();
    if clean_group.is_empty() || clean_node.is_empty() {
        return Err("Usage: cli api select <group> <node>".to_string());
    }
    let payload = json!({ "name": clean_node }).to_string();
    curl_put_selection(app, clean_group, &payload)?;
    let persist_error = selector_store::save(app, clean_group, clean_node).err();
    match classify_selector_cleanup(close_connections_through_chain(app, clean_group)) {
        SelectorCleanupOutcome::Complete(summary) => {
            if let Some(err) = persist_error {
                eprintln!("[warn] runtime applied, persistence failed: {err}");
            }
            println!(
                "[info] {clean_group} selector set to {clean_node}; closed {}/{} stale connections",
                summary.closed, summary.targets
            );
        }
        SelectorCleanupOutcome::Degraded(err) => {
            if let Some(persist_error) = persist_error {
                eprintln!("[warn] runtime applied, persistence failed: {persist_error}");
            }
            println!(
                "[warning] {clean_group} selector set to {clean_node}; stale connections were not fully closed: {err}"
            );
        }
    }
    Ok(())
}

pub(crate) fn curl_put_selection(app: &App, group: &str, payload: &str) -> Result<(), String> {
    curl_put_json(
        app,
        &format!("/proxies/{}", encode_path_segment(group)),
        payload,
    )
}

pub(crate) fn curl_get_json(app: &App, path: &str) -> Result<serde_json::Value, String> {
    let output = Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            "3",
            "--max-filesize",
            "8388608",
            &format!("{}{}", app.api, path),
        ])
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    serde_json::from_slice(&output.stdout).map_err(|err| format!("parse API response: {err}"))
}

fn close_connection(app: &App, id: &str) -> Result<(), String> {
    if id.is_empty() {
        return Err("Usage: cli api close <id>".to_string());
    }
    curl_delete(app, &format!("/connections/{}", encode_path_segment(id)))
}

fn run_curl(args: &[&str]) -> Result<(), String> {
    let output = Command::new("curl")
        .args(["--max-filesize", "8388608"])
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

#[cfg(test)]
mod mode_tests {
    use super::{hotspot_member_from_api, normalize_clash_mode};

    #[test]
    fn accepts_supported_clash_modes_case_insensitively() {
        assert_eq!(normalize_clash_mode("Rule").unwrap(), "rule");
        assert_eq!(normalize_clash_mode("GLOBAL").unwrap(), "global");
        assert_eq!(normalize_clash_mode("direct").unwrap(), "direct");
        assert!(normalize_clash_mode("tun").is_err());
    }

    #[test]
    fn hotspot_status_only_accepts_direct_or_proxy() {
        let direct = serde_json::json!({"proxies": {"hotspot": {"now": "direct"}}});
        let proxy = serde_json::json!({"proxies": {"hotspot": {"now": "proxy"}}});
        let private_node = serde_json::json!({"proxies": {"hotspot": {"now": "PRIVATE-NODE"}}});

        assert_eq!(hotspot_member_from_api(&direct), Some("direct"));
        assert_eq!(hotspot_member_from_api(&proxy), Some("proxy"));
        assert_eq!(hotspot_member_from_api(&private_node), None);
    }
}

fn webui_status(app: &App) {
    let local_dir = app.moddir.join(".config/sing-box/zashboard");
    println!("local_dir={}", local_dir.display());
    println!(
        "local_ready={}",
        local_dir.join("index.html").exists() as u8
    );
    println!("sing-box={}", singbox_webui(app));
    println!(
        "version={}",
        fs::read_to_string(app.moddir.join("zashboard.version"))
            .unwrap_or_else(|_| "unknown".to_string())
            .lines()
            .next()
            .unwrap_or("unknown")
    );
}

fn webui_verify(app: &App) -> Result<(), String> {
    let module_webui = app.moddir.join("webroot");
    let singbox_panel = app.moddir.join(".config/sing-box/zashboard");
    let checks = [
        ("module_webui", module_webui.as_path()),
        ("singbox_zashboard", singbox_panel.as_path()),
    ];

    let mut failed = Vec::new();
    for (name, dir) in checks {
        let ok = contains_index(dir);
        println!(
            "{name}={} path={}",
            if ok { "ok" } else { "missing" },
            dir.display()
        );
        if !ok {
            failed.push(name);
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("webui verify failed: {}", failed.join(",")))
    }
}

fn api_ui(app: &App, target: &str) {
    match target {
        "sing-box" | "singbox" => println!("{}", singbox_webui(app)),
        "all" => {
            println!("sing-box={}", singbox_webui(app));
        }
        _ => println!("{}", singbox_webui(app)),
    }
}

fn install_local(app: &App, args: &[String]) -> Result<(), String> {
    let url = args.get(1).map(String::as_str).unwrap_or_default();
    if url.is_empty() {
        return Err(
            "Usage: cli webui install-local <https-download-url> <sha256> [name]".to_string(),
        );
    }
    validate_panel_download_url(url)?;
    let expected_sha256 = args.get(2).map(String::as_str).unwrap_or_default();
    validate_sha256(expected_sha256)?;
    let name = args.get(3).map(String::as_str).unwrap_or("zashboard");
    if name.is_empty() || name.len() > 128 || name.chars().any(char::is_control) {
        return Err("panel name must be 1-128 bytes without control characters".to_string());
    }

    let _panel_guard = panel_install_lock(app)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let operation = format!("{}-{nonce}", std::process::id());
    let tmp = app.moddir.join(format!(".tmp/webui-panel-{operation}.zip"));
    let staging = app
        .moddir
        .join(format!(".tmp/webui-panel-stage-{operation}"));
    let target = app.moddir.join(".config/sing-box/zashboard");
    let backup = app
        .moddir
        .join(format!(".tmp/webui-panel-backup-{operation}"));
    if let Some(parent) = tmp.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    clean_panel_staging(&tmp, &staging);
    let prepared = download_panel_zip(url, &tmp)
        .and_then(|_| verify_panel_archive(&tmp, expected_sha256))
        .and_then(|_| validate_panel_archive_entries(&tmp))
        .and_then(|_| unpack_panel_archive(&tmp, &staging));
    if let Err(error) = prepared {
        clean_panel_staging(&tmp, &staging);
        return Err(error);
    }

    let promoted = with_config_apply_lock(app, || {
        promote_panel_transaction(app, name, &staging, &target, &backup)
    });
    clean_panel_staging(&tmp, &staging);
    promoted?;
    println!("[info] Installed local panel {name}");
    Ok(())
}

fn promote_panel_transaction(
    app: &App,
    name: &str,
    staging: &Path,
    target: &Path,
    backup: &Path,
) -> Result<(), String> {
    let version_path = app.moddir.join("zashboard.version");
    let previous_version = match fs::read_to_string(&version_path) {
        Ok(value) => Some(value),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(format!("read current panel version: {error}")),
    };
    let had_target = fs::symlink_metadata(target).is_ok();
    if had_target {
        fs::rename(target, backup).map_err(|err| format!("backup existing panel: {err}"))?;
    }
    if let Err(error) = fs::rename(staging, target) {
        if had_target {
            let _ = fs::rename(backup, target);
        }
        return Err(format!("promote validated panel: {error}"));
    }

    let activated = write_text_file(app, Path::new("zashboard.version"), &format!("{name}\n"))
        .and_then(|_| run_magicnet_function(app, "magicnet_singbox_apply_zashboard"));
    if let Err(error) = activated {
        let rollback = rollback_panel_transaction(app, target, backup, previous_version.as_deref());
        return match rollback {
            Ok(()) => Err(format!(
                "activate installed panel: {error}; previous panel restored"
            )),
            Err(rollback_error) => Err(format!(
                "activate installed panel: {error}; rollback failed: {rollback_error}"
            )),
        };
    }
    if let Err(error) = remove_panel_path(backup) {
        eprintln!("[warning] installed panel backup could not be removed: {error}");
    }
    Ok(())
}

fn rollback_panel_transaction(
    app: &App,
    target: &Path,
    backup: &Path,
    previous_version: Option<&str>,
) -> Result<(), String> {
    remove_panel_path(target).map_err(|err| format!("remove failed panel: {err}"))?;
    if fs::symlink_metadata(backup).is_ok() {
        fs::rename(backup, target).map_err(|err| format!("restore previous panel: {err}"))?;
    }
    if let Some(version) = previous_version {
        write_text_file(app, Path::new("zashboard.version"), version)?;
    } else {
        match fs::remove_file(app.moddir.join("zashboard.version")) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("remove failed panel version: {error}")),
        }
    }
    Ok(())
}

fn remove_panel_path(path: &Path) -> Result<(), String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
    .map_err(|error| error.to_string())
}

fn validate_panel_download_url(url: &str) -> Result<(), String> {
    validate_subscription_url(url).map_err(|error| {
        if error.contains("must use HTTPS") {
            "refusing plaintext http download (MITM risk); use an https:// URL".to_string()
        } else {
            format!("invalid WebUI download URL: {error}")
        }
    })
}

fn download_panel_zip(url: &str, tmp: &std::path::Path) -> Result<(), String> {
    if let Err(err) = curl_download(url, tmp) {
        let _ = fs::remove_file(tmp);
        return Err(err);
    }
    Ok(())
}

fn curl_download(url: &str, tmp: &std::path::Path) -> Result<(), String> {
    // Panel archives unpack as root. Reuse the subscription pinned-HTTPS
    // downloader so redirects and private targets cannot re-aim the request.
    let result = (|| {
        let body = download_pinned_https_url(url, PANEL_MAX_BYTES, 15, 90)?;
        fs::write(tmp, body).map_err(|err| format!("stage downloaded panel: {err}"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}

fn validate_sha256(expected: &str) -> Result<(), String> {
    if expected.len() == 64 && expected.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err("install-local requires a 64-character hexadecimal SHA-256 digest".to_string())
    }
}

fn verify_panel_archive(path: &Path, expected: &str) -> Result<(), String> {
    let mut archive =
        fs::File::open(path).map_err(|err| format!("open downloaded panel: {err}"))?;
    let mut reader = (&mut archive).take(PANEL_MAX_BYTES as u64 + 1);
    let mut digest = Sha256::new();
    let mut bytes_read = 0usize;
    let mut buffer = [0u8; 8192];
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|err| format!("read downloaded panel: {err}"))?;
        if read == 0 {
            break;
        }
        bytes_read += read;
        ensure_panel_size(bytes_read)?;
        digest.update(&buffer[..read]);
    }
    let actual = format!("{:x}", digest.finalize());
    if actual.eq_ignore_ascii_case(expected) {
        Ok(())
    } else {
        Err("downloaded panel SHA-256 verification failed".to_string())
    }
}

fn ensure_panel_size(bytes_read: usize) -> Result<(), String> {
    if bytes_read <= PANEL_MAX_BYTES {
        Ok(())
    } else {
        Err("downloaded panel exceeds 32 MiB limit".to_string())
    }
}

fn unpack_panel_archive(archive: &Path, staging: &Path) -> Result<(), String> {
    fs::create_dir_all(staging).map_err(|err| format!("mkdir {}: {err}", staging.display()))?;
    let mut command = Command::new("unzip");
    command.arg("-oq").arg(archive).arg("-d").arg(staging);
    run_panel_command(command, "extract panel archive")?;
    ensure_panel_tree_safe(staging)?;
    promote_dist_dir(staging)?;
    if contains_index(staging) {
        Ok(())
    } else {
        Err("panel zip does not contain index.html".to_string())
    }
}

fn validate_panel_archive_entries(archive: &Path) -> Result<(), String> {
    let mut names_command = Command::new("unzip");
    names_command.args(["-Z1"]).arg(archive);
    let names_output = run_panel_command(names_command, "list panel archive entries")?;
    let names = String::from_utf8_lossy(&names_output.stdout);
    let entries = names.lines().collect::<Vec<_>>();
    if entries.is_empty() || entries.len() > PANEL_MAX_ENTRIES {
        return Err(format!(
            "panel archive must contain 1-{PANEL_MAX_ENTRIES} entries"
        ));
    }
    let mut seen = HashSet::new();
    for entry in &entries {
        validate_panel_archive_entry(entry)?;
        if !seen.insert(entry.trim_end_matches('/')) {
            return Err("panel archive contains duplicate entry paths".to_string());
        }
    }

    let mut sizes_command = Command::new("unzip");
    sizes_command.arg("-l").arg(archive);
    let sizes_output = run_panel_command(sizes_command, "inspect panel archive sizes")?;
    validate_panel_archive_sizes(
        &String::from_utf8_lossy(&sizes_output.stdout),
        entries.len(),
    )
}

fn run_panel_command(
    command: Command,
    operation: &str,
) -> Result<crate::BoundedCommandOutput, String> {
    let output = run_bounded_command(command, PANEL_COMMAND_TIMEOUT, PANEL_COMMAND_OUTPUT_LIMIT)?;
    if output.timed_out {
        return Err(format!(
            "{operation} timed out after {} seconds",
            PANEL_COMMAND_TIMEOUT.as_secs()
        ));
    }
    if !output.status.is_some_and(|status| status.success()) {
        return Err(format!("{operation} failed"));
    }
    Ok(output)
}

fn validate_panel_archive_sizes(listing: &str, expected_entries: usize) -> Result<(), String> {
    let mut sizes = Vec::new();
    for line in listing.lines() {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        if fields.len() < 4 || !fields[1].contains('-') || !fields[2].contains(':') {
            continue;
        }
        let Ok(size) = fields[0].parse::<u64>() else {
            continue;
        };
        if size > PANEL_MAX_ENTRY_BYTES {
            return Err("panel archive entry exceeds 32 MiB unpacked limit".to_string());
        }
        sizes.push(size);
    }
    if sizes.len() != expected_entries {
        return Err("panel archive size metadata is incomplete".to_string());
    }
    let total = sizes.iter().try_fold(0u64, |total, size| {
        total
            .checked_add(*size)
            .ok_or("panel archive size overflow")
    })?;
    if total > PANEL_MAX_UNPACKED_BYTES {
        return Err("panel archive exceeds 128 MiB total unpacked limit".to_string());
    }
    Ok(())
}

fn validate_panel_archive_entry(entry: &str) -> Result<(), String> {
    let entry = entry.trim_end_matches('/');
    if entry.len() > PANEL_MAX_PATH_BYTES
        || entry.split('/').count() > PANEL_MAX_PATH_DEPTH
        || entry.is_empty()
        || entry.starts_with('/')
        || entry.starts_with('\\')
        || entry.chars().any(char::is_control)
        || entry.split('/').any(|component| {
            component.is_empty()
                || component == "."
                || component == ".."
                || component.contains('\\')
        })
    {
        return Err("panel archive contains an unsafe path".to_string());
    }
    Ok(())
}

fn ensure_panel_tree_safe(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|err| format!("inspect extracted panel {}: {err}", path.display()))?;
    if metadata.file_type().is_symlink() {
        return Err("panel archive contains a symlink".to_string());
    }
    if metadata.is_dir() {
        for entry in fs::read_dir(path)
            .map_err(|err| format!("read extracted panel {}: {err}", path.display()))?
        {
            ensure_panel_tree_safe(
                &entry
                    .map_err(|err| format!("read extracted panel entry: {err}"))?
                    .path(),
            )?;
        }
    }
    Ok(())
}

fn clean_panel_staging(archive: &Path, staging: &Path) {
    let _ = fs::remove_file(archive);
    let _ = fs::remove_dir_all(staging);
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

fn promote_dist_dir(target: &std::path::Path) -> Result<(), String> {
    let dist = target.join("dist");
    if !dist.join("index.html").exists() {
        return Ok(());
    }
    for entry in fs::read_dir(&dist).map_err(|err| format!("read {}: {err}", dist.display()))? {
        let entry = entry.map_err(|err| format!("read {}: {err}", dist.display()))?;
        let dest = target.join(entry.file_name());
        if dest.exists() {
            if dest.is_dir() {
                fs::remove_dir_all(&dest)
            } else {
                fs::remove_file(&dest)
            }
            .map_err(|err| format!("remove {}: {err}", dest.display()))?;
        }
        fs::rename(entry.path(), &dest)
            .map_err(|err| format!("move panel asset to {}: {err}", dest.display()))?;
    }
    fs::remove_dir_all(&dist).map_err(|err| format!("remove {}: {err}", dist.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::test_support::temp_app;

    #[test]
    fn contains_index_searches_nested_panel_directories() {
        let app = temp_app();
        let root = app.moddir.join("panel");
        fs::create_dir_all(root.join("nested")).unwrap();
        assert!(!contains_index(&root));
        fs::write(root.join("nested/index.html"), "").unwrap();
        assert!(contains_index(&root));
    }

    #[test]
    fn promote_dist_dir_moves_zashboard_assets_to_panel_root() {
        let app = temp_app();
        let root = app.moddir.join("panel");
        fs::create_dir_all(root.join("dist/assets")).unwrap();
        fs::write(root.join("dist/index.html"), "").unwrap();
        fs::write(root.join("dist/assets/app.js"), "").unwrap();

        promote_dist_dir(&root).unwrap();

        assert!(root.join("index.html").exists());
        assert!(root.join("assets/app.js").exists());
        assert!(!root.join("dist").exists());
    }

    #[test]
    fn install_local_requires_a_sha256_digest() {
        assert!(validate_sha256("not-a-digest").is_err());
        assert!(validate_sha256(&"a".repeat(63)).is_err());
        assert!(validate_sha256(&"A".repeat(64)).is_ok());
    }

    #[test]
    fn panel_download_url_reuses_public_https_policy() {
        validate_panel_download_url("https://github.com/example/panel.zip").unwrap();
        assert!(
            validate_panel_download_url("http://github.com/example/panel.zip")
                .unwrap_err()
                .contains("plaintext")
        );
        assert!(validate_panel_download_url("https://127.0.0.1/panel.zip").is_err());
        assert!(validate_panel_download_url("https://user:secret@example.com/panel.zip").is_err());
    }

    fn stored_empty_zip(name: &str) -> Vec<u8> {
        let name = name.as_bytes();
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        bytes.extend_from_slice(&20u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&(name.len() as u16).to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(name);
        let central_offset = bytes.len() as u32;
        bytes.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        bytes.extend_from_slice(&20u16.to_le_bytes());
        bytes.extend_from_slice(&20u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&(name.len() as u16).to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(name);
        let central_size = bytes.len() as u32 - central_offset;
        bytes.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&central_size.to_le_bytes());
        bytes.extend_from_slice(&central_offset.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes
    }

    #[test]
    fn panel_archive_metadata_and_extraction_use_bounded_unzip_runner() {
        let app = temp_app();
        let archive = app.moddir.join("panel.zip");
        let staging = app.moddir.join("staging");
        fs::create_dir_all(&app.moddir).unwrap();
        fs::write(&archive, stored_empty_zip("index.html")).unwrap();
        validate_panel_archive_entries(&archive).unwrap();
        unpack_panel_archive(&archive, &staging).unwrap();
        assert!(staging.join("index.html").is_file());
    }

    #[test]
    fn panel_archive_hash_mismatch_is_rejected() {
        let app = temp_app();
        fs::create_dir_all(&app.moddir).unwrap();
        let archive = app.moddir.join("panel.zip");
        fs::write(&archive, b"test panel").unwrap();
        assert!(verify_panel_archive(&archive, &"0".repeat(64)).is_err());
    }

    #[test]
    fn panel_staging_cleanup_removes_partial_download_and_unpack_dir() {
        let app = temp_app();
        let archive = app.moddir.join("partial.zip");
        let staging = app.moddir.join("staging");
        fs::create_dir_all(&staging).unwrap();
        fs::write(&archive, b"partial").unwrap();
        clean_panel_staging(&archive, &staging);
        assert!(!archive.exists());
        assert!(!staging.exists());
    }

    #[test]
    fn panel_archive_entries_reject_escape_paths() {
        for entry in [
            "../outside.js",
            "panel/../../outside.js",
            "/absolute/index.html",
            "panel\\outside.js",
            "panel/./index.html",
        ] {
            assert!(
                validate_panel_archive_entry(entry).is_err(),
                "unsafe archive entry accepted: {entry}"
            );
        }
        validate_panel_archive_entry("panel/index.html").unwrap();
        validate_panel_archive_entry("panel/assets/").unwrap();
    }

    #[test]
    fn panel_archive_limits_entry_count_depth_and_unpacked_size() {
        let valid = "Archive: panel.zip\n Length Date Time Name\n 1024 2026-08-24 00:00 index.html\n 2048 2026-08-24 00:00 assets/app.js\n";
        validate_panel_archive_sizes(valid, 2).unwrap();
        assert!(validate_panel_archive_sizes(valid, 3).is_err());

        let oversized = format!(" {} 2026-08-24 00:00 huge.bin\n", PANEL_MAX_ENTRY_BYTES + 1);
        assert!(validate_panel_archive_sizes(&oversized, 1).is_err());
        assert!(validate_panel_archive_entry(&format!(
            "{}/index.html",
            "nested/".repeat(PANEL_MAX_PATH_DEPTH)
        ))
        .is_err());
        assert!(validate_panel_archive_entry(&"x".repeat(PANEL_MAX_PATH_BYTES + 1)).is_err());
    }

    #[test]
    fn failed_panel_activation_restores_assets_and_version_metadata() {
        let app = temp_app();
        let target = app.moddir.join(".config/sing-box/zashboard");
        let staging = app.moddir.join(".tmp/staging");
        let backup = app.moddir.join(".tmp/backup");
        fs::create_dir_all(&target).unwrap();
        fs::create_dir_all(&staging).unwrap();
        fs::write(target.join("index.html"), "old").unwrap();
        fs::write(staging.join("index.html"), "new").unwrap();
        fs::write(app.moddir.join("zashboard.version"), "old-panel\n").unwrap();

        let error =
            promote_panel_transaction(&app, "new-panel", &staging, &target, &backup).unwrap_err();
        assert!(error.contains("previous panel restored"));
        assert_eq!(
            fs::read_to_string(target.join("index.html")).unwrap(),
            "old"
        );
        assert_eq!(
            fs::read_to_string(app.moddir.join("zashboard.version")).unwrap(),
            "old-panel\n"
        );
        assert!(!backup.exists());
        let _ = fs::remove_dir_all(&app.moddir);
    }

    #[test]
    fn panel_tree_rejects_symlinks_before_promotion() {
        let app = temp_app();
        let root = app.moddir.join("panel-stage");
        fs::create_dir_all(&root).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/etc", root.join("escape")).unwrap();
        #[cfg(unix)]
        assert!(ensure_panel_tree_safe(&root).is_err());
    }

    #[test]
    fn panel_download_size_limit_is_enforced() {
        assert!(ensure_panel_size(PANEL_MAX_BYTES).is_ok());
        assert!(ensure_panel_size(PANEL_MAX_BYTES + 1).is_err());
    }

    #[test]
    fn api_connection_id_is_encoded_as_path_segment() {
        assert_eq!(encode_path_segment("abc-123_~"), "abc-123_~");
        assert_eq!(encode_path_segment("id/with space"), "id%2Fwith%20space");
        assert_eq!(encode_path_segment("proxy/final"), "proxy%2Ffinal");
    }

    #[test]
    fn select_proxy_requires_group_and_node() {
        let app = temp_app();
        assert!(select_proxy(&app, "", "node")
            .unwrap_err()
            .contains("Usage"));
        assert!(select_proxy(&app, "proxy", "")
            .unwrap_err()
            .contains("Usage"));
    }

    #[test]
    fn selector_cleanup_failure_is_degraded_not_primary_failure() {
        let outcome = classify_selector_cleanup(Err("API cleanup unavailable".to_string()));
        assert!(matches!(
            outcome,
            SelectorCleanupOutcome::Degraded(message) if message == "API cleanup unavailable"
        ));
    }
}
