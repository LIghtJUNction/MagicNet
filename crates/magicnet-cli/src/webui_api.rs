use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

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
        "tailscale-status" => {
            let tag = args.get(1).filter(|tag| !tag.is_empty())
                .ok_or("Usage: cli api tailscale-status <endpoint-tag>")?;
            tailscale_status(app, tag)
        }
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
        "stats" => {
            println!("{}", traffic_sample(app)?);
            Ok(())
        }
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

fn tailscale_status(app: &App, tag: &str) -> Result<(), String> {
    let port = app
        .api
        .strip_prefix("http://127.0.0.1:")
        .or_else(|| app.api.strip_prefix("http://[::1]:"))
        .and_then(|value| value.trim_end_matches('/').parse::<u16>().ok());
    if port.is_none_or(|port| port == 0) {
        return Err("Tailscale login requires a local sing-box API".to_string());
    }
    let config = crate::utils::read_json_file_bounded(
        &app.moddir.join(".config/sing-box/config.json"),
        4 * 1024 * 1024,
    )
    .ok_or("invalid or unreadable private API configuration")?;
    let api = &config["experimental"]["clash_api"];
    let secret = api["secret"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| api["tailscale_secret"].as_str())
        .filter(|s| !s.is_empty())
        .ok_or("Tailscale API credential missing; configure browser login first")?;
    if !secret
        .bytes()
        .all(|b| b.is_ascii_graphic() && b != b'"' && b != b'\\')
    {
        return Err("unsupported API credential format".to_string());
    }
    // Keep the credential out of process arguments and shell command previews.
    let prefix = "header = \"Authorization: Bearer ";
    let suffix = "\"\n";
    if secret.len() > crate::utils::MAX_COMMAND_INPUT_BYTES - prefix.len() - suffix.len() {
        return Err("unsupported API credential format".to_string());
    }
    let credential = format!("{prefix}{secret}{suffix}");
    let body = local_curl_output(
        app,
        &[
            "-q",
            "--noproxy",
            "*",
            "-fsS",
            "--max-time",
            "4",
            "--config",
            "-",
            &format!(
                "{}/tailscale/{}",
                app.api.trim_end_matches('/'),
                encode_path_segment(tag)
            ),
        ],
        Duration::from_secs(5),
        64 * 1024,
        Some(credential.as_bytes()),
    )
    .map_err(|_| "Tailscale status is unavailable")?;
    print!("{}", String::from_utf8_lossy(&body));
    Ok(())
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
    if hotspot_policy_is_stale(app)? {
        apply_config(app)?;
    }
    Ok(())
}

fn hotspot_policy_is_stale(app: &App) -> Result<bool, String> {
    // Only a confirmed topology change should restart the core. Discovery
    // failures are retried by the watcher without interrupting live sockets.
    match run_magicnet_function_status(app, "magicnet_singbox_hotspot_policy_current")?.code() {
        Some(0) => Ok(false),
        Some(1) => Ok(true),
        status => Err(format!(
            "hotspot discovery failed with status {status:?}; retaining the current configuration"
        )),
    }
}

fn refresh_hotspot_policy_locked(
    app: &App,
    guard: &crate::service::ConfigApplyGuard,
) -> Result<(), String> {
    if hotspot_policy_is_stale(app)? {
        crate::service::apply_config_locked(app, guard)?;
    }
    Ok(())
}

fn apply_hotspot_policy_locked(
    app: &App,
    member: &str,
    runtime_member: Option<&str>,
    guard: &crate::service::ConfigApplyGuard,
) -> Result<(), String> {
    if member == "proxy" {
        run_magicnet_function(app, "magicnet_hotspot_offload_enable")?;
        // Persisted intent must be visible before the core snapshots its
        // source policy. Reuse the lifecycle guard instead of locking twice.
        refresh_hotspot_policy_locked(app, guard)?;
        if let Some(runtime_member) = runtime_member {
            curl_put_selection(app, "hotspot", &json!({"name": runtime_member}).to_string())?;
        }
        run_magicnet_function(app, "magicnet_hotspot_reconcile")?;
        run_magicnet_function(app, "magicnet_hotspot_watchdog_start")?;
    } else {
        run_magicnet_function(app, "magicnet_hotspot_watchdog_stop")?;
        // Successful offload restoration already removed owned hotspot routes.
        run_magicnet_function(app, "magicnet_hotspot_offload_restore")?;
        refresh_hotspot_policy_locked(app, guard)?;
        if let Some(runtime_member) = runtime_member {
            curl_put_selection(app, "hotspot", &json!({"name": runtime_member}).to_string())?;
        }
    }
    Ok(())
}

fn restore_hotspot_policy_locked(
    app: &App,
    saved: Option<&str>,
    runtime: Option<&str>,
    guard: &crate::service::ConfigApplyGuard,
) -> Result<(), String> {
    // Compensation is best-effort, not the fail-fast forward transition. An
    // unavailable API must not prevent restoring Android offload or routes.
    let mut errors = Vec::new();
    let mut attempt = |step: &'static str, result: Result<(), String>| {
        let success = result.is_ok();
        if !success {
            errors.push(step);
        }
        success
    };
    let saved_restored = attempt("intent", selector_store::set_checked(app, "hotspot", saved));
    let member = saved.or(runtime).unwrap_or("direct");
    if member == "proxy" {
        attempt(
            "offload-enable",
            run_magicnet_function(app, "magicnet_hotspot_offload_enable"),
        );
    } else {
        attempt(
            "watcher-stop",
            run_magicnet_function(app, "magicnet_hotspot_watchdog_stop"),
        );
        if !attempt(
            "offload-restore",
            run_magicnet_function(app, "magicnet_hotspot_offload_restore"),
        ) {
            // Offload validation can fail before route cleanup. Keep that
            // independent compensation, but do not repeat a successful pass.
            attempt(
                "route-cleanup",
                run_magicnet_function(app, "magicnet_hotspot_route_cleanup"),
            );
        }
    }
    // Do not materialize the failed operation's intent if saving the previous
    // choice failed. Still attempt independent resource and API compensation.
    if saved_restored {
        attempt("config", refresh_hotspot_policy_locked(app, guard));
    }
    if let Some(runtime) = runtime {
        attempt(
            "selector",
            curl_put_selection(app, "hotspot", &json!({"name": runtime}).to_string()),
        );
    }
    if member == "proxy" {
        attempt(
            "route-reconcile",
            run_magicnet_function(app, "magicnet_hotspot_reconcile"),
        );
        if saved_restored {
            attempt(
                "watcher-start",
                run_magicnet_function(app, "magicnet_hotspot_watchdog_start"),
            );
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join(", "))
    }
}

fn set_hotspot_policy(app: &App, member: &str) -> Result<(), String> {
    if !matches!(member, "direct" | "proxy") {
        return Err("hotspot selector only supports direct or proxy".to_string());
    }
    let guard = crate::service::config_apply_lock(app)?;
    let previous_saved = selector_store::selected_checked(app, "hotspot")?;
    if previous_saved
        .as_deref()
        .is_some_and(|value| !matches!(value, "direct" | "proxy"))
    {
        return Err("saved hotspot intent is invalid".to_string());
    }
    let previous_runtime = match curl_get_json(app, "/proxies") {
        Ok(value) => Some(
            hotspot_member_from_api(&value)
                .ok_or("hotspot runtime selection is unknown")?
                .to_string(),
        ),
        Err(_) if crate::singbox_pid_summary(app) == "stopped" => None,
        Err(_) => {
            return Err("hotspot runtime is unavailable; refusing to change policy".to_string())
        }
    };
    // A failed save is fatal before any API, route or Android settings write.
    selector_store::set_checked(app, "hotspot", Some(member))?;
    if let Err(error) = apply_hotspot_policy_locked(
        app,
        member,
        previous_runtime.as_ref().map(|_| member),
        &guard,
    ) {
        // Restore absence as absence, preserve unrelated selector keys, and
        // restore the observed runtime separately from the configured choice.
        let rollback = restore_hotspot_policy_locked(
            app,
            previous_saved.as_deref(),
            previous_runtime.as_deref(),
            &guard,
        );
        return match rollback {
            Ok(()) => Err(error),
            Err(rollback) => Err(format!("{error}; hotspot rollback failed: {rollback}")),
        };
    }
    if previous_runtime.is_some() {
        if let SelectorCleanupOutcome::Degraded(error) =
            classify_selector_cleanup(close_connections_through_chain(app, "hotspot"))
        {
            eprintln!("[warning] hotspot policy applied, but stale connections were not fully closed: {error}");
        }
    }
    println!("[info] hotspot outbound set to {member}");
    Ok(())
}

pub(crate) fn hotspot_cmd(app: &App, args: &[String]) -> Result<(), String> {
    if args.len() > 1 {
        return Err("Usage: cli hotspot {status|enable|disable|reconcile}".to_string());
    }
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
            let guard = crate::service::config_apply_lock(app)?;
            run_magicnet_function(app, "magicnet_hotspot_reconcile")?;
            refresh_hotspot_policy_locked(app, &guard)
        }
        "enable" => set_hotspot_policy(app, "proxy"),
        "disable" => set_hotspot_policy(app, "direct"),
        _ => Err("Usage: cli hotspot {status|enable|disable|reconcile}".to_string()),
    }
}

pub(crate) fn hotspot_member(app: &App) -> String {
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

fn traffic_sample(app: &App) -> Result<serde_json::Value, String> {
    // /traffic never finishes. Use the bounded native sampler even when curl
    // is installed so neither transport waits for the stream to close.
    let body = crate::local_http::first_line(&app.api, "/traffic")?;
    if body.iter().all(u8::is_ascii_whitespace) {
        return Err("local API traffic stream returned no sample".into());
    }
    let sample: serde_json::Value =
        serde_json::from_slice(&body).map_err(|_| "local API traffic sample is not valid JSON")?;
    if !sample.get("up").is_some_and(serde_json::Value::is_number)
        || !sample.get("down").is_some_and(serde_json::Value::is_number)
    {
        return Err("local API traffic sample requires numeric up and down".into());
    }
    Ok(json!({"up": sample["up"], "down": sample["down"]}))
}

fn curl(app: &App, path: &str) -> Result<(), String> {
    if !crate::process::trusted_curl_path(app).is_file() {
        return print_local_response(app, "GET", path, "");
    }
    run_curl(
        app,
        &["-fsS", "--max-time", "4", &format!("{}{}", app.api, path)],
    )
}

fn curl_delete(app: &App, path: &str) -> Result<(), String> {
    if !crate::process::trusted_curl_path(app).is_file() {
        return print_local_response(app, "DELETE", path, "");
    }
    run_curl(
        app,
        &[
            "-fsS",
            "-X",
            "DELETE",
            "--max-time",
            "4",
            &format!("{}{}", app.api, path),
        ],
    )
}

fn curl_put_json(app: &App, path: &str, payload: &str) -> Result<(), String> {
    if !crate::process::trusted_curl_path(app).is_file() {
        return print_local_response(app, "PUT", path, payload);
    }
    run_curl(
        app,
        &[
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
        ],
    )
}

fn curl_patch_json(app: &App, path: &str, payload: &str) -> Result<(), String> {
    if !crate::process::trusted_curl_path(app).is_file() {
        return print_local_response(app, "PATCH", path, payload);
    }
    run_curl(
        app,
        &[
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
        ],
    )
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
    if clean_group == "hotspot" {
        return set_hotspot_policy(app, clean_node);
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
    if !crate::process::trusted_curl_path(app).is_file() {
        let body = crate::local_http::request(&app.api, "GET", path, "")?;
        return serde_json::from_slice(&body).map_err(|err| format!("parse API response: {err}"));
    }
    let body = local_curl_output(
        app,
        &["-fsS", "--max-time", "3", &format!("{}{}", app.api, path)],
        Duration::from_secs(4),
        8 * 1024 * 1024,
        None,
    )?;
    serde_json::from_slice(&body).map_err(|err| format!("parse API response: {err}"))
}

fn close_connection(app: &App, id: &str) -> Result<(), String> {
    if id.is_empty() {
        return Err("Usage: cli api close <id>".to_string());
    }
    curl_delete(app, &format!("/connections/{}", encode_path_segment(id)))
}

fn run_curl(app: &App, args: &[&str]) -> Result<(), String> {
    // Existing curl deadlines are four/five seconds. Allow one second of
    // transport shutdown before the independent parent deadline cleans up.
    let body = local_curl_output(app, args, Duration::from_secs(6), 8 * 1024 * 1024, None)?;
    print!("{}", String::from_utf8_lossy(&body));
    Ok(())
}

pub(crate) fn local_curl_output(
    app: &App,
    args: &[&str],
    timeout: Duration,
    stream_limit: usize,
    input: Option<&[u8]>,
) -> Result<Vec<u8>, String> {
    let mut command = crate::trusted_curl(app);
    command
        .args(args)
        .args(["--max-filesize", &stream_limit.to_string()]);
    let output = match input {
        Some(input) => {
            crate::utils::run_bounded_command_with_input(command, timeout, stream_limit, input)
        }
        None => crate::run_bounded_command(command, timeout, stream_limit),
    }
    .map_err(|err| format!("run curl: {err}"))?;
    // Never pass partial JSON/output on as a successful API result.
    if output.timed_out {
        return Err("local API request timed out".to_string());
    }
    if output.truncated {
        return Err("local API response exceeds the read limit".to_string());
    }
    if !output.status.is_some_and(|status| status.success()) {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(output.stdout)
}

fn print_local_response(app: &App, method: &str, path: &str, payload: &str) -> Result<(), String> {
    let body = crate::local_http::request(&app.api, method, path, payload)?;
    print!("{}", String::from_utf8_lossy(&body));
    Ok(())
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
    let name = validate_panel_name(args.get(3).map(String::as_str).unwrap_or("zashboard"))?;
    let tmp = app.moddir.join(".tmp/webui-panel.zip");
    let staging = app.moddir.join(".tmp/webui-panel-stage");
    let target = app.moddir.join(".config/sing-box/zashboard");
    if let Some(parent) = tmp.parent() {
        fs::create_dir_all(parent).map_err(|err| format!("mkdir {}: {err}", parent.display()))?;
    }
    clean_panel_staging(&tmp, &staging);
    download_panel_zip(app, url, &tmp)?;
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

fn download_panel_zip(app: &App, url: &str, tmp: &std::path::Path) -> Result<(), String> {
    if let Err(err) = curl_download(app, url, tmp) {
        let _ = fs::remove_file(tmp);
        return Err(err);
    }
    Ok(())
}

const PANEL_MAX_BYTES: usize = 32 * 1024 * 1024;

fn curl_download(app: &App, url: &str, tmp: &std::path::Path) -> Result<(), String> {
    // Panel archives unpack as root. Reuse the subscription pinned-HTTPS
    // downloader so redirects and private targets cannot re-aim the request.
    let result = (|| {
        let body = download_pinned_https_url(app, url, PANEL_MAX_BYTES, 15, 90)?;
        fs::write(tmp, body).map_err(|err| format!("stage downloaded panel: {err}"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}

fn validate_panel_name(name: &str) -> Result<&str, String> {
    if (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        Ok(name)
    } else {
        Err("invalid local panel name".to_string())
    }
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
    use std::io::Write;

    use super::*;
    use crate::test_support::temp_app;

    fn fixture_curl(app: &App, script: &str) {
        use std::os::unix::fs::PermissionsExt;
        fs::create_dir_all(app.moddir.join("bin")).unwrap();
        let shell = if cfg!(target_os = "android") {
            "/system/bin/sh"
        } else {
            "/bin/sh"
        };
        let path = app.moddir.join("bin/curl");
        fs::write(&path, format!("#!{shell}\n{script}\n")).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn api_stats_finishes_after_first_sample_without_waiting_for_stream_end() {
        use std::net::TcpListener;
        use std::time::Instant;
        let fixture = temp_app();
        let mut app = App::for_test(fixture.moddir.clone());
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        app.api = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(6)))
                .unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                assert_eq!(stream.read(&mut byte).unwrap(), 1);
                request.push(byte[0]);
            }
            assert!(request.starts_with(b"GET /traffic "));
            stream.write_all(b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{\"up\":1,\"down\":2}\n{\"up\":3,\"down\":4}\n").unwrap();
            let _ = stream.read(&mut [0]);
        });
        let started = Instant::now();
        let result = api_cmd(&app, &["stats".to_string()]);
        server.join().unwrap();
        assert!(result.is_ok(), "stream sample failed: {result:?}");
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn traffic_sample_returns_one_numeric_object_or_a_sanitized_error() {
        use std::net::TcpListener;
        for (body, valid) in [
            ("{\"up\":1,\"down\":2}\n{\"up\":3,\"down\":4}\n", true),
            ("{\"up\":1,\"down\":2}", true),
            (
                "{\"up\":1,\"down\":2,\"extra\":\"private-fixture\"}\n",
                true,
            ),
            ("\n", false),
            ("", false),
            ("private-fixture\n", false),
            ("{\"up\":\"private-fixture\",\"down\":2}\n", false),
            ("{\"up\":1}\n", false),
        ] {
            let fixture = temp_app();
            let mut app = App::for_test(fixture.moddir.clone());
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            app.api = format!("http://{}", listener.local_addr().unwrap());
            let server = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let _ = stream.read(&mut [0; 2048]);
                write!(stream, "HTTP/1.0 200 OK\r\n\r\n{body}").unwrap();
            });
            let result = traffic_sample(&app);
            server.join().unwrap();
            if valid {
                assert_eq!(result.unwrap(), json!({"up":1,"down":2}));
            } else {
                assert!(!result.unwrap_err().contains("private-fixture"));
            }
        }
    }

    #[test]
    fn curl_deadline_never_returns_partial_json_as_success() {
        let app = temp_app();
        fixture_curl(&app, "printf '[]'; exec sleep 30");
        let error =
            local_curl_output(&app, &[], Duration::from_millis(100), 128, None).unwrap_err();
        assert_eq!(error, "local API request timed out");
    }

    #[test]
    fn curl_stderr_overflow_is_not_accepted_even_on_zero_exit() {
        let app = temp_app();
        fixture_curl(&app, "printf '[]'; head -c 1025 /dev/zero >&2");
        assert_eq!(
            local_curl_output(&app, &[], Duration::from_secs(1), 1024, None).unwrap_err(),
            "local API response exceeds the read limit"
        );
    }

    #[test]
    fn node_delay_uses_its_parent_enforced_response_limit() {
        let app = temp_app();
        fixture_curl(
            &app,
            "printf '{\"delay\":1}'; head -c 1048576 /dev/zero | tr '\\000' ' '",
        );
        assert_eq!(
            crate::node_delay::node_delay(&app, "fixture").unwrap_err(),
            "local API response exceeds the read limit"
        );
    }

    #[test]
    fn tailscale_credential_stdin_closes_without_exposing_it_in_argv() {
        let app = temp_app();
        fs::create_dir_all(app.moddir.join(".config/sing-box")).unwrap();
        fs::write(app.moddir.join(".config/sing-box/config.json"),
            r#"{"experimental":{"clash_api":{"tailscale_secret":"fixture-secret-not-an-argument"}}}"#).unwrap();
        fixture_curl(&app, "printf '%s\\n' \"$@\" >\"${0%/*}/curl-argv\"; cat >\"${0%/*}/curl-stdin\"; printf '{\"state\":\"Running\"}'");
        tailscale_status(&app, "fixture").unwrap();
        let argv = fs::read_to_string(app.moddir.join("bin/curl-argv")).unwrap();
        assert_eq!(argv.lines().next(), Some("-q"));
        assert!(!argv.contains("fixture-secret-not-an-argument"));
        assert_eq!(
            fs::read_to_string(app.moddir.join("bin/curl-stdin")).unwrap(),
            "header = \"Authorization: Bearer fixture-secret-not-an-argument\"\n"
        );
    }

    #[test]
    fn tailscale_transport_errors_cannot_echo_the_credential() {
        let app = temp_app();
        fs::create_dir_all(app.moddir.join(".config/sing-box")).unwrap();
        fs::write(app.moddir.join(".config/sing-box/config.json"),
            r#"{"experimental":{"clash_api":{"tailscale_secret":"fixture-secret-not-an-argument"}}}"#).unwrap();
        fixture_curl(
            &app,
            "printf '%s\\n' \"$@\" >\"${0%/*}/curl-argv\"; cat >&2; exit 7",
        );
        assert_eq!(
            tailscale_status(&app, "fixture").unwrap_err(),
            "Tailscale status is unavailable"
        );
        let argv = fs::read_to_string(app.moddir.join("bin/curl-argv")).unwrap();
        assert_eq!(argv.lines().next(), Some("-q"));
        assert!(!argv.contains("fixture-secret-not-an-argument"));
    }

    #[test]
    fn oversized_valid_curl_json_is_not_accepted_as_success() {
        let app = temp_app();
        // Valid JSON plus whitespace: parsing alone must not mask overflow.
        // The stand-in ignores curl flags to exercise the parent-side ceiling.
        fixture_curl(
            &app,
            "printf '[]'; head -c 8388608 /dev/zero | tr '\\000' ' '",
        );
        assert_eq!(
            curl_get_json(&app, "/proxies").unwrap_err(),
            "local API response exceeds the read limit"
        );
    }

    #[test]
    fn tailscale_credentials_are_only_sent_to_loopback() {
        let fixture = temp_app();
        let mut app = App::for_test(fixture.moddir.clone());
        app.api = "https://example.com".to_string();
        assert_eq!(
            tailscale_status(&app, "tailnet").unwrap_err(),
            "Tailscale login requires a local sing-box API"
        );
    }

    #[test]
    fn tailscale_status_sends_private_bearer_header() {
        use std::net::TcpListener;
        use std::time::Duration;
        let fixture = temp_app();
        let mut app = App::for_test(fixture.moddir.clone());
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        app.api = format!("http://{}", listener.local_addr().unwrap());
        fs::create_dir_all(app.moddir.join(".config/sing-box")).unwrap();
        fs::write(
            app.moddir.join(".config/sing-box/config.json"),
            r#"{"experimental":{"clash_api":{"tailscale_secret":"fixture-secret"}}}"#,
        )
        .unwrap();
        let server = std::thread::spawn(move || {
            let mut connection = None;
            for _ in 0..500 {
                if let Ok((stream, _)) = listener.accept() {
                    connection = Some(stream);
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            let mut stream = connection.expect("curl did not reach local API");
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut request = Vec::new();
            let mut buffer = [0; 1024];
            while !request.ends_with(b"\r\n\r\n") && request.len() < 16384 {
                let read = stream.read(&mut buffer).unwrap();
                assert!(read > 0);
                request.extend_from_slice(&buffer[..read]);
            }
            let request = String::from_utf8(request).unwrap();
            assert!(request.contains("Authorization: Bearer fixture-secret\r\n"));
            assert!(request.starts_with("GET /tailscale/tail%2Fnet "));
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 19\r\nConnection: close\r\n\r\n{\"state\":\"Running\"}").unwrap();
        });
        assert!(tailscale_status(&app, "tail/net").is_ok());
        server.join().unwrap();
    }

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
    fn install_local_rejects_control_characters_in_panel_name() {
        assert!(validate_panel_name("zashboard").is_ok());
        assert!(validate_panel_name("panel_v1.2").is_ok());
        assert!(validate_panel_name("bad name").is_err());
        assert!(validate_panel_name("panel\nextra").is_err());
        assert!(validate_panel_name("../escape").is_err());
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
