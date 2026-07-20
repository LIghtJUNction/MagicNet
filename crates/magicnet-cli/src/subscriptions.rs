use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{
    clean_lines, clear_node_cache, decode_base64, first_clean_line, run_magicnet_function,
    write_text_file, App,
};

const MAX_SINGBOX_SUBSCRIPTION_URLS: usize = 5;
const SELECTOR_REPLAY_WARNING: &str =
    "subscription committed, but saved selector choices could not be replayed";

fn subscription_update_outcome(
    update: Result<(), String>,
    replay: Result<(), String>,
) -> Result<Option<&'static str>, String> {
    update?;
    Ok(replay.err().map(|_| SELECTOR_REPLAY_WARNING))
}

fn finish_subscription_update(app: &App, update: Result<(), String>) -> Result<(), String> {
    update?;
    clear_node_cache(app);
    let replay = crate::selector_store::replay(app).map(|_| ());
    if let Some(warning) = subscription_update_outcome(Ok(()), replay)? {
        eprintln!("[warning] {warning}");
    }
    Ok(())
}

pub fn setup_subscription(app: &App, url: &str) -> Result<(), String> {
    if url.is_empty() {
        return Err("Usage: cli setup <subscription-url>".to_string());
    }
    validate_subscription_url(url)?;
    apply_subscription_text(app, &format!("{url}\n"))
}

pub fn sub_set(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let url = match target {
        "sing-box" | "singbox" => args.get(3).map(String::as_str).unwrap_or_default(),
        _ => return Err("Usage: cli sub set sing-box <url>".to_string()),
    };
    if url.is_empty() {
        return Err("Usage: cli sub set sing-box <url>".to_string());
    }
    validate_subscription_url(url)?;
    apply_subscription_text(app, &format!("{url}\n"))
}

pub fn sub_set_file(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let payload = args.get(3).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli sub set-file sing-box <base64-lines>".to_string());
    }
    match target {
        "sing-box" | "singbox" => {}
        _ => return Err("set-file supports sing-box only".to_string()),
    }
    let text = normalized_subscription_payload(payload)?;
    apply_subscription_text(app, &text)
}

pub fn sub_apply_file(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let payload = args.get(3).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli sub apply-file sing-box <base64-lines>".to_string());
    }
    if !matches!(target, "sing-box" | "singbox") {
        return Err("apply-file supports sing-box only".to_string());
    }
    let text = normalized_subscription_payload(payload)?;
    apply_subscription_text(app, &text)
}

fn apply_subscription_text(app: &App, text: &str) -> Result<(), String> {
    let result = with_subscription_candidate(app, text, |candidate| {
        let candidate_arg = shell_single_quote(&candidate.to_string_lossy());
        let command = format!(
            "MAGICNET_SUB_CANDIDATE_URL_FILE={candidate_arg}; export MAGICNET_SUB_CANDIDATE_URL_FILE; . \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; magicnet_singbox_update_subscription"
        );
        run_magicnet_function(app, &command)
    });
    finish_subscription_update(app, result)
}

fn with_subscription_candidate<T>(
    app: &App,
    text: &str,
    activate: impl FnOnce(&std::path::Path) -> Result<T, String>,
) -> Result<T, String> {
    let candidate = write_subscription_candidate(app, text)?;
    let result = activate(&candidate);
    let _ = fs::remove_file(candidate);
    result
}

fn write_subscription_candidate(app: &App, text: &str) -> Result<PathBuf, String> {
    let candidate_dir = app.moddir.join(".state/sing-box/subscription-candidates");
    cleanup_subscription_candidates(&candidate_dir)?;
    fs::create_dir_all(&candidate_dir)
        .map_err(|err| format!("create subscription candidate dir: {err}"))?;
    fs::set_permissions(&candidate_dir, fs::Permissions::from_mode(0o700))
        .map_err(|err| format!("secure subscription candidate dir: {err}"))?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| format!("system clock before epoch: {err}"))?
        .as_nanos();
    let candidate = candidate_dir.join(format!("{}-{nonce}.url", std::process::id()));
    write_text_file(candidate.clone(), text)?;
    fs::set_permissions(&candidate, fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("secure subscription candidate: {err}"))?;
    Ok(candidate)
}

fn cleanup_subscription_candidates(candidate_dir: &PathBuf) -> Result<(), String> {
    let Ok(entries) = fs::read_dir(candidate_dir) else {
        return Ok(());
    };
    for entry in entries {
        let entry = entry.map_err(|err| format!("read subscription candidate entry: {err}"))?;
        let file_type = entry
            .file_type()
            .map_err(|err| format!("inspect subscription candidate entry: {err}"))?;
        if file_type.is_file() {
            fs::remove_file(entry.path())
                .map_err(|err| format!("remove stale subscription candidate: {err}"))?;
        }
    }
    Ok(())
}

fn normalized_subscription_payload(payload: &str) -> Result<String, String> {
    let bytes = decode_base64(payload)?;
    let text =
        String::from_utf8(bytes).map_err(|err| format!("subscription text is not UTF-8: {err}"))?;
    let mut seen = HashSet::new();
    let mut lines = Vec::new();
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        validate_subscription_url(line)?;
        if seen.insert(line.to_string()) {
            lines.push(line.to_string());
            if lines.len() > MAX_SINGBOX_SUBSCRIPTION_URLS {
                return Err(format!(
                    "sing-box subscription URL list supports at most {MAX_SINGBOX_SUBSCRIPTION_URLS} entries"
                ));
            }
        }
    }
    Ok(format!("{}\n", lines.join("\n")))
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn sub_list(app: &App) {
    for (idx, url) in clean_lines(app.moddir.join(".config/sing-box/subscription.url"))
        .iter()
        .enumerate()
    {
        println!("sing-box.{}={}", idx + 1, url);
    }
    println!(
        "sing-box={}",
        first_clean_line(app.moddir.join(".config/sing-box/subscription.url"))
    );
}

pub fn sub_get(app: &App, target: &str) {
    println!("{}", first_clean_line(sub_target_file(app, target)));
}

pub fn sub_update(app: &App, args: &[String]) -> Result<(), String> {
    match args.get(2).map(String::as_str).unwrap_or("sing-box") {
        "sing-box" | "singbox" | "all" => update_singbox_subscription(app),
        _ => Err("Usage: cli sub update <sing-box|all>".to_string()),
    }
}

pub fn sub_update_all(app: &App) -> Result<(), String> {
    update_singbox_subscription(app)
}

pub fn sub_status(app: &App) -> Result<(), String> {
    run_magicnet_function(
        app,
        ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; magicnet_singbox_status",
    )
}

pub fn sub_schedule(app: &App, args: &[String]) -> Result<(), String> {
    match args.get(2).map(String::as_str).unwrap_or("status") {
        "status" => run_magicnet_function(app, "magicnet_subscription_schedule_report"),
        "set" => {
            let value = args.get(3).map(String::as_str).unwrap_or_default();
            if !matches!(value, "off" | "12" | "24" | "48" | "72") {
                return Err("Usage: cli sub schedule set <off|12|24|48|72>".to_string());
            }
            run_magicnet_function(app, &format!("magicnet_subscription_schedule_set {value}"))
        }
        _ => Err("Usage: cli sub schedule {status|set <off|12|24|48|72>}".to_string()),
    }
}

fn update_singbox_subscription(app: &App) -> Result<(), String> {
    let update = run_magicnet_function(
        app,
        ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; magicnet_singbox_update_subscription",
    );
    finish_subscription_update(app, update)
}

pub(crate) fn cleanup_stale_update_lock(app: &App) {
    let lock = app.moddir.join(".state/sing-box/subscription-update.lock");
    let owner_path = lock.join("owner");
    let Ok(owner) = fs::read_to_string(&owner_path) else {
        return;
    };
    let mut fields = owner.trim().split(':');
    let pid = fields.next().and_then(|value| value.parse::<u32>().ok());
    let expected_start = fields.next();
    let live_start = pid
        .and_then(|pid| fs::read_to_string(format!("/proc/{pid}/stat")).ok())
        .and_then(|stat| stat.split_whitespace().nth(21).map(str::to_string));
    if expected_start.is_some() && live_start.as_deref() == expected_start {
        return;
    }
    if fs::read_to_string(&owner_path)
        .ok()
        .as_deref()
        .map(str::trim)
        == Some(owner.trim())
    {
        let _ = fs::remove_dir_all(lock);
    }
}

pub(crate) fn sub_target_file(app: &App, _target: &str) -> PathBuf {
    app.moddir.join(".config/sing-box/subscription.url")
}

pub(crate) fn validate_subscription_url(url: &str) -> Result<(), String> {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("Subscription URL must start with http:// or https://".to_string());
    }
    if url.chars().any(char::is_whitespace) {
        return Err("Subscription URL must not contain whitespace".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    fn temp_app() -> App {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("magicnet-cli-test-{stamp}"));
        App::for_test(dir)
    }

    #[test]
    fn subscription_url_validation_accepts_only_http_urls_without_whitespace() {
        validate_subscription_url("https://example.com/sub?profile=abc").unwrap();
        validate_subscription_url("http://127.0.0.1:8080/sub").unwrap();
        assert!(validate_subscription_url("ftp://example.com/sub").is_err());
        assert!(validate_subscription_url("https://example.com/a b").is_err());
    }

    #[test]
    fn set_file_dedupes_and_trims_singbox_subscription_lines() {
        let payload = crate::encode_base64(
            b"\nhttps://example.com/a\nhttps://example.com/a\n  http://example.com/b  \n",
        );
        let text = normalized_subscription_payload(&payload).unwrap();
        assert_eq!(text, "https://example.com/a\nhttp://example.com/b\n");
    }

    #[test]
    fn set_file_rejects_non_http_subscription_lines() {
        let app = temp_app();
        let payload = crate::encode_base64(b"vmess://not-a-subscription-file-entry\n");

        let err = sub_set_file(
            &app,
            &[
                "sub".to_string(),
                "set-file".to_string(),
                "sing-box".to_string(),
                payload,
            ],
        )
        .unwrap_err();

        assert!(err.contains("must start with http:// or https://"), "{err}");
    }

    #[test]
    fn set_file_rejects_more_than_five_singbox_subscription_lines() {
        let app = temp_app();
        let payload = crate::encode_base64(
            b"https://example.com/1\nhttps://example.com/2\nhttps://example.com/3\nhttps://example.com/4\nhttps://example.com/5\nhttps://example.com/6\n",
        );

        let err = sub_set_file(
            &app,
            &[
                "sub".to_string(),
                "set-file".to_string(),
                "sing-box".to_string(),
                payload,
            ],
        )
        .unwrap_err();

        assert!(err.contains("at most 5 entries"), "{err}");
    }

    #[test]
    fn candidate_activation_failure_never_writes_the_active_url() {
        let app = temp_app();
        let mut staged = None;
        let error = with_subscription_candidate(&app, "https://example.com/sub\n", |candidate| {
            staged = Some(candidate.to_path_buf());
            assert_eq!(
                fs::read_to_string(candidate).unwrap(),
                "https://example.com/sub\n"
            );
            Err::<(), _>("activation rejected".to_string())
        })
        .unwrap_err();

        assert_eq!(error, "activation rejected");
        assert!(!sub_target_file(&app, "sing-box").exists());
        assert!(!staged.unwrap().exists());
    }

    #[test]
    fn committed_update_with_selector_replay_failure_is_success_with_warning() {
        let outcome =
            subscription_update_outcome(Ok(()), Err("fixture selector replay failure".to_string()))
                .unwrap();

        assert_eq!(outcome, Some(SELECTOR_REPLAY_WARNING));
    }

    #[test]
    fn failed_update_stays_failed_even_when_replay_would_succeed() {
        let error =
            subscription_update_outcome(Err("update failed".to_string()), Ok(())).unwrap_err();

        assert_eq!(error, "update failed");
    }

    #[test]
    fn subscription_candidate_uses_dedicated_private_location() {
        let app = temp_app();
        let candidate =
            write_subscription_candidate(&app, "https://example.com/private\n").unwrap();
        let mode = fs::metadata(&candidate).unwrap().permissions().mode() & 0o777;

        assert_eq!(mode, 0o600);
        assert_eq!(
            candidate.parent().unwrap(),
            app.moddir.join(".state/sing-box/subscription-candidates")
        );
    }
}
