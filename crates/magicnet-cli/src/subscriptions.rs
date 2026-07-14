use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use crate::{
    clean_lines, clear_node_cache, decode_base64, first_clean_line, run_magicnet_function,
    write_text_file, App,
};

const MAX_SINGBOX_SUBSCRIPTION_URLS: usize = 5;

pub fn setup_subscription(app: &App, url: &str) -> Result<(), String> {
    if url.is_empty() {
        return Err("Usage: cli setup <subscription-url>".to_string());
    }
    validate_subscription_url(url)?;
    clear_node_cache(app);
    write_text_file(sub_target_file(app, "sing-box"), &format!("{url}\n"))?;
    println!("[info] Saved subscription URL for sing-box");
    Ok(())
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
    clear_node_cache(app);
    let file = sub_target_file(app, "sing-box");
    write_text_file(file.clone(), &format!("{url}\n"))?;
    println!(
        "[info] Saved sing-box subscription URL to {}",
        file.display()
    );
    Ok(())
}

pub fn sub_set_file(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let payload = args.get(3).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli sub set-file sing-box <base64-lines>".to_string());
    }
    let file = match target {
        "sing-box" | "singbox" => sub_target_file(app, "sing-box"),
        _ => return Err("set-file supports sing-box only".to_string()),
    };
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
    clear_node_cache(app);
    write_text_file(file.clone(), &format!("{}\n", lines.join("\n")))?;
    println!(
        "[info] Saved sing-box subscription URL list to {}",
        file.display()
    );
    Ok(())
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

fn update_singbox_subscription(app: &App) -> Result<(), String> {
    clear_node_cache(app);
    run_magicnet_function(
        app,
        ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; magicnet_singbox_update_subscription",
    )?;
    crate::selector_store::replay(app)?;
    Ok(())
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
        let app = temp_app();
        let payload = crate::encode_base64(
            b"\nhttps://example.com/a\nhttps://example.com/a\n  http://example.com/b  \n",
        );

        sub_set_file(
            &app,
            &[
                "sub".to_string(),
                "set-file".to_string(),
                "sing-box".to_string(),
                payload,
            ],
        )
        .unwrap();

        let text =
            fs::read_to_string(app.moddir.join(".config/sing-box/subscription.url")).unwrap();
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
    fn setup_subscription_updates_singbox_only() {
        let app = temp_app();

        setup_subscription(&app, "https://example.com/sub").unwrap();

        let singbox =
            fs::read_to_string(app.moddir.join(".config/sing-box/subscription.url")).unwrap();
        assert_eq!(singbox, "https://example.com/sub\n");
        assert!(app
            .moddir
            .join(".config/sing-box/subscription.url")
            .exists());
    }
}
