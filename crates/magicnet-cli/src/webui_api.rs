use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::Command;

use serde_json::json;
use sha2::{Digest, Sha256};

use crate::connection_control::{
    close_connections_through_chain, close_matching_connections, close_top_connections,
    print_close_all_summary,
};
use crate::node_delay::encode_path_segment;
use crate::process::run_magicnet_function_status;
use crate::selector_store;
use crate::service::{apply_config, singbox_webui};
use crate::subscriptions::{download_pinned_https_url, validate_subscription_url};
use crate::{run_magicnet_function, write_text_file, App};

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
        "replay" => {
            sync_persisted_hotspot_offload(app);
            let applied = selector_store::replay(app)?;
            println!("[info] replayed {applied} persisted selectors");
            Ok(())
        }
        "conns" => curl(app, "/connections"),
        "stats" => curl(app, "/traffic"),
        "close" => close_connection(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "close-top" => close_top_connections(app, args.get(1).map(String::as_str).unwrap_or("3")),
        "close-matching" => close_matching_connections(app, &args[1..].join(" ")),
        "close-all" => print_close_all_summary(app),
        _ => Err(
            "Usage: cli api {ui [current|sing-box|all]|groups|proxies|select <group> <node>|conns|stats|close <id>|close-top [count]|close-matching <query>|close-all}"
                .to_string(),
        ),
    }
}

fn sync_persisted_hotspot_offload(app: &App) {
    let member = selector_store::selected(app, "hotspot").unwrap_or_else(|| "direct".to_string());
    let function = if member == "proxy" {
        "magicnet_hotspot_offload_enable"
    } else {
        "magicnet_hotspot_offload_restore"
    };
    if let Err(err) = run_magicnet_function(app, function) {
        eprintln!("[warning] persisted hotspot offload state could not be synchronized: {err}");
    }
    if member == "proxy" {
        if let Err(err) = run_magicnet_function(app, "magicnet_hotspot_reconcile") {
            eprintln!("[warning] persisted hotspot TUN route could not be reconciled: {err}");
        }
        if let Err(err) = run_magicnet_function(app, "magicnet_hotspot_watchdog_start") {
            eprintln!("[warning] hotspot route watcher could not be started: {err}");
        }
    } else {
        let _ = run_magicnet_function(app, "magicnet_hotspot_watchdog_stop");
        let _ = run_magicnet_function(app, "magicnet_hotspot_route_cleanup");
        if let Err(err) = refresh_hotspot_policy_if_stale(app) {
            eprintln!("[warning] stale hotspot source policy could not be removed: {err}");
        }
    }
}

fn refresh_hotspot_policy_if_stale(app: &App) -> Result<(), String> {
    // Only a confirmed topology change should restart the core. Discovery
    // failures are retried by the watcher without interrupting live sockets.
    match run_magicnet_function_status(app, "magicnet_singbox_hotspot_policy_current")?.code() {
        Some(0) => Ok(()),
        Some(1) => apply_config(app),
        status => Err(format!(
            "hotspot discovery failed with status {status:?}; retaining the current configuration"
        )),
    }
}

fn rollback_hotspot_enable(app: &App) {
    let _ = select_proxy(app, "hotspot", "direct");
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
    let tmp = app.moddir.join(".tmp/webui-panel.zip");
    let staging = app.moddir.join(".tmp/webui-panel-stage");
    let target = app.moddir.join(".config/sing-box/zashboard");
    if let Some(parent) = tmp.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    clean_panel_staging(&tmp, &staging);
    download_panel_zip(url, &tmp)?;
    if let Err(err) = verify_panel_archive(&tmp, expected_sha256)
        .and_then(|_| validate_panel_archive_entries(&tmp))
        .and_then(|_| unpack_panel_archive(&tmp, &staging))
    {
        clean_panel_staging(&tmp, &staging);
        return Err(err);
    }

    let backup = target.with_extension("bak");
    let _ = fs::remove_dir_all(&backup);
    if target.exists() {
        if let Err(err) = fs::rename(&target, &backup) {
            clean_panel_staging(&tmp, &staging);
            return Err(format!("backup existing panel: {err}"));
        }
    }
    if let Err(err) = fs::rename(&staging, &target) {
        if backup.exists() {
            let _ = fs::rename(&backup, &target);
        }
        clean_panel_staging(&tmp, &staging);
        return Err(format!("promote validated panel: {err}"));
    }
    let _ = fs::remove_file(&tmp);
    write_text_file(app, Path::new("zashboard.version"), &format!("{name}\n"))?;
    run_magicnet_function(app, "magicnet_singbox_apply_zashboard")?;
    println!("[info] Installed local panel {name}");
    Ok(())
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

const PANEL_MAX_BYTES: usize = 32 * 1024 * 1024;

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
    let status = Command::new("unzip")
        .arg("-oq")
        .arg(archive)
        .arg("-d")
        .arg(staging)
        .status()
        .map_err(|err| format!("unzip panel: {err}"))?;
    if !status.success() {
        return Err("panel unzip failed".to_string());
    }
    ensure_panel_tree_safe(staging)?;
    promote_dist_dir(staging)?;
    if contains_index(staging) {
        Ok(())
    } else {
        Err("panel zip does not contain index.html".to_string())
    }
}

fn validate_panel_archive_entries(archive: &Path) -> Result<(), String> {
    let output = Command::new("unzip")
        .args(["-Z1"])
        .arg(archive)
        .output()
        .map_err(|err| format!("list panel archive: {err}"))?;
    if !output.status.success() {
        return Err("panel archive entry listing failed".to_string());
    }
    for entry in String::from_utf8_lossy(&output.stdout).lines() {
        validate_panel_archive_entry(entry)?;
    }
    Ok(())
}

fn validate_panel_archive_entry(entry: &str) -> Result<(), String> {
    let entry = entry.trim_end_matches('/');
    if entry.is_empty()
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
    fn hotspot_probe_failure_does_not_apply_config() {
        let app = temp_app();
        fs::create_dir_all(app.moddir.join("lib/kamfw")).unwrap();
        fs::write(app.moddir.join("lib/kamfw/.kamfwrc"), "import() { :; }\n").unwrap();
        fs::write(
            app.moddir.join("lib/magicnet_singbox_subscribe.sh"),
            "magicnet_singbox_update_lock_active() { return 1; }\n",
        )
        .unwrap();
        for status in [1, 0, 2, 124] {
            fs::write(
                app.moddir.join("lib/magicnet.sh"),
                format!(
                    "magicnet_singbox_hotspot_policy_current() {{ return {status}; }}\n\
                     magicnet_apply_runtime_config() {{ touch \"$MODDIR/applied\"; return 42; }}\n"
                ),
            )
            .unwrap();
            assert_eq!(refresh_hotspot_policy_if_stale(&app).is_ok(), status == 0);
            assert_eq!(app.moddir.join("applied").exists(), status == 1);
            assert_eq!(
                app.moddir.join(".state/config-apply.lock").exists(),
                status == 1
            );
            if status == 1 {
                fs::remove_file(app.moddir.join("applied")).unwrap();
                fs::remove_file(app.moddir.join(".state/config-apply.lock")).unwrap();
            }
        }
    }

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
