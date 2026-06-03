use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

use serde_yaml::{Mapping, Value};

use crate::{
    clean_lines, clear_node_cache, decode_base64, first_clean_line, pid_summary,
    run_magicnet_function, write_text_file, App,
};

const DEFAULT_MIHOMO_PROVIDER: &str = "premium_a";

pub fn setup_subscription(app: &App, url: &str) -> Result<(), String> {
    if url.is_empty() {
        return Err("Usage: cli setup <subscription-url>".to_string());
    }
    validate_subscription_url(url)?;
    clear_node_cache(app);
    write_text_file(sub_target_file(app, "sing-box"), &format!("{url}\n"))?;
    write_text_file(sub_target_file(app, "mihomo"), &format!("{url}\n"))?;
    ensure_mihomo_provider_cache_dir(app)?;
    update_mihomo_config_url(app, url, Some(DEFAULT_MIHOMO_PROVIDER))?;
    println!("[info] Saved subscription URL for sing-box");
    println!("[info] Saved subscription URL for mihomo provider {DEFAULT_MIHOMO_PROVIDER}");
    Ok(())
}

pub fn sub_set(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let (provider, url) = match target {
        "mihomo" | "clash" => match (args.get(3), args.get(4)) {
            (Some(provider), Some(url)) => (Some(provider.as_str()), url.as_str()),
            (Some(url), None) => (None, url.as_str()),
            _ => {
                return Err(
                    "Usage: cli sub set <sing-box|mihomo|clash> [provider] <url>".to_string(),
                )
            }
        },
        "sing-box" | "singbox" => match args.get(3) {
            Some(url) => (None, url.as_str()),
            None => {
                return Err(
                    "Usage: cli sub set <sing-box|mihomo|clash> [provider] <url>".to_string(),
                )
            }
        },
        _ => return Err("Subscription target must be sing-box or mihomo".to_string()),
    };
    validate_subscription_url(url)?;
    clear_node_cache(app);
    write_text_file(sub_target_file(app, target), &format!("{url}\n"))?;
    if matches!(target, "mihomo" | "clash") {
        ensure_mihomo_provider_cache_dir(app)?;
        update_mihomo_config_url(app, url, provider)?;
    }
    println!(
        "[info] Saved {target}{} subscription URL to {}",
        provider
            .map(|value| format!(" provider {value}"))
            .unwrap_or_default(),
        sub_target_file(app, target).display()
    );
    Ok(())
}

pub fn sub_set_file(app: &App, args: &[String]) -> Result<(), String> {
    let target = args.get(2).map(String::as_str).unwrap_or_default();
    let payload = args.get(3).map(String::as_str).unwrap_or_default();
    if payload.is_empty() {
        return Err("Usage: cli sub set-file <sing-box> <base64-lines>".to_string());
    }
    let file = match target {
        "sing-box" | "singbox" => sub_target_file(app, "sing-box"),
        _ => return Err("set-file currently supports sing-box only".to_string()),
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
    for (name, url) in mihomo_providers(app) {
        println!("mihomo.{name}={url}");
    }
    println!(
        "mihomo={}",
        first_clean_line(app.moddir.join(".config/mihomo/subscription.url"))
    );
}

pub fn sub_get(app: &App, target: &str) {
    println!("{}", first_clean_line(sub_target_file(app, target)));
}

pub fn sub_update(app: &App, args: &[String]) -> Result<(), String> {
    match args.get(2).map(String::as_str).unwrap_or("sing-box") {
        "sing-box" | "singbox" => update_singbox_subscription(app),
        "mihomo" | "clash" => update_mihomo_providers(app),
        "all" => sub_update_all(app),
        _ => Err("Usage: cli sub update <sing-box|mihomo|all>".to_string()),
    }
}

pub fn sub_update_all(app: &App) -> Result<(), String> {
    let mut failed = Vec::new();
    if let Err(err) = update_singbox_subscription(app) {
        failed.push(format!("sing-box: {err}"));
    }
    if pid_summary("mihomo") == "stopped" {
        println!("[warn] mihomo is not running; skipped mihomo provider update");
    } else if let Err(err) = update_mihomo_providers(app) {
        failed.push(format!("mihomo: {err}"));
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(failed.join("; "))
    }
}

fn update_singbox_subscription(app: &App) -> Result<(), String> {
    clear_node_cache(app);
    run_magicnet_function(
        app,
        ". \"$MODDIR/lib/magicnet_singbox_subscribe.sh\"; magicnet_singbox_update_subscription",
    )
}

fn update_mihomo_providers(app: &App) -> Result<(), String> {
    let providers: Vec<_> = mihomo_providers(app)
        .into_iter()
        .filter(|(_, url)| !url.trim().is_empty())
        .collect();
    if providers.is_empty() {
        return Err("mihomo proxy-providers has no usable url. Run `cli sub set mihomo premium_a <subscription-url>` or `cli setup <subscription-url>` first".to_string());
    }
    let mut ok = 0usize;
    let mut failed = Vec::new();
    for (name, _) in providers {
        match update_mihomo_provider(app, &name) {
            Ok(()) => {
                ok += 1;
                println!("[info] Updated mihomo provider {name}");
            }
            Err(err) => failed.push(format!("{name}: {err}")),
        }
    }
    clear_node_cache(app);
    if failed.is_empty() {
        println!("[info] Updated {ok} mihomo providers");
        Ok(())
    } else {
        Err(format!(
            "updated {ok} providers, failed {}",
            failed.join(", ")
        ))
    }
}

fn update_mihomo_provider(app: &App, name: &str) -> Result<(), String> {
    let url = format!(
        "{}/providers/proxies/{}",
        app.api,
        shell_url_component(name)
    );
    let output = Command::new("curl")
        .args(["-fsS", "-X", "PUT", "--max-time", "45", &url])
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let err = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(if err.is_empty() {
            "provider API failed".to_string()
        } else {
            err
        })
    }
}

pub(crate) fn sub_target_file(app: &App, target: &str) -> PathBuf {
    match target {
        "mihomo" | "clash" => app.moddir.join(".config/mihomo/subscription.url"),
        "sing-box" | "singbox" => app.moddir.join(".config/sing-box/subscription.url"),
        _ => app.moddir.join(".config/sing-box/subscription.url"),
    }
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

fn mihomo_providers(app: &App) -> Vec<(String, String)> {
    let Ok(mut config) = read_mihomo_yaml(app) else {
        return Vec::new();
    };
    let Some(providers) = yaml_mapping_mut(&mut config, "proxy-providers") else {
        return Vec::new();
    };
    providers
        .iter()
        .filter_map(|(key, value)| {
            let name = key.as_str()?.to_string();
            let _ = value.as_mapping()?;
            let url = value
                .get("url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_string();
            Some((name, url))
        })
        .collect()
}

fn update_mihomo_config_url(
    app: &App,
    url: &str,
    target_provider: Option<&str>,
) -> Result<(), String> {
    let mut config = match read_mihomo_yaml(app) {
        Ok(config) => config,
        Err(_) => return Ok(()),
    };
    let Some(providers) = yaml_mapping_mut(&mut config, "proxy-providers") else {
        return Ok(());
    };
    let target_key = target_provider.map(ToOwned::to_owned).or_else(|| {
        providers.iter().find_map(|(key, value)| {
            value.as_mapping()?;
            key.as_str().map(ToOwned::to_owned)
        })
    });
    let Some(target_key) = target_key else {
        return Ok(());
    };
    let provider = providers
        .entry(Value::String(target_key.clone()))
        .or_insert_with(|| Value::Mapping(Mapping::new()));
    let Some(provider_map) = provider.as_mapping_mut() else {
        return Err(format!("mihomo provider {target_key} is not a map"));
    };
    provider_map.insert(
        Value::String("type".to_string()),
        Value::String("http".to_string()),
    );
    provider_map.insert(
        Value::String("interval".to_string()),
        Value::Number(serde_yaml::Number::from(3600)),
    );
    provider_map.insert(
        Value::String("url".to_string()),
        Value::String(url.to_string()),
    );
    let health_check = serde_yaml::from_str(
        "{enable: true, url: http://www.gstatic.com/generate_204, interval: 300}",
    )
    .map_err(|err| format!("build mihomo health-check: {err}"))?;
    provider_map.insert(Value::String("health-check".to_string()), health_check);
    attach_mihomo_provider_to_groups(&mut config, &target_key);
    write_mihomo_yaml(app, &config)?;
    println!("[info] Updated mihomo provider {target_key}");
    Ok(())
}

fn attach_mihomo_provider_to_groups(config: &mut Value, provider: &str) {
    let Some(groups) = config
        .get_mut("proxy-groups")
        .and_then(Value::as_sequence_mut)
    else {
        return;
    };
    for group in groups {
        let Some(group_map) = group.as_mapping_mut() else {
            continue;
        };
        let type_key = Value::String("type".to_string());
        let group_type = group_map
            .get(&type_key)
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !matches!(
            group_type,
            "select" | "url-test" | "fallback" | "load-balance"
        ) {
            continue;
        }
        let use_key = Value::String("use".to_string());
        let use_value = group_map
            .entry(use_key)
            .or_insert_with(|| Value::Sequence(Vec::new()));
        let Some(use_list) = use_value.as_sequence_mut() else {
            continue;
        };
        let already_present = use_list.iter().any(|item| {
            item.as_str()
                .map(|value| value == provider)
                .unwrap_or(false)
        });
        if !already_present {
            use_list.push(Value::String(provider.to_string()));
        }
    }
}

fn ensure_mihomo_provider_cache_dir(app: &App) -> Result<(), String> {
    fs::create_dir_all(app.moddir.join(".config/mihomo/proxies"))
        .map_err(|err| format!("create mihomo provider cache dir: {err}"))
}

fn read_mihomo_yaml(app: &App) -> Result<Value, String> {
    let path = app.moddir.join(".config/mihomo/config.yaml");
    let text =
        fs::read_to_string(&path).map_err(|err| format!("read {}: {err}", path.display()))?;
    serde_yaml::from_str(&text).map_err(|err| format!("parse {}: {err}", path.display()))
}

fn write_mihomo_yaml(app: &App, config: &Value) -> Result<(), String> {
    let path = app.moddir.join(".config/mihomo/config.yaml");
    let text =
        serde_yaml::to_string(config).map_err(|err| format!("serialize mihomo yaml: {err}"))?;
    write_text_file(path, &text)
}

fn yaml_mapping_mut<'a>(value: &'a mut Value, key: &str) -> Option<&'a mut Mapping> {
    value.get_mut(key)?.as_mapping_mut()
}

fn shell_url_component(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
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

    fn write_mihomo(app: &App, text: &str) {
        let path = app.moddir.join(".config/mihomo/config.yaml");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    #[test]
    fn subscription_url_validation_accepts_only_http_urls_without_whitespace() {
        validate_subscription_url("https://example.com/sub?token=abc").unwrap();
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
    fn set_mihomo_subscription_updates_named_provider_url() {
        let app = temp_app();
        write_mihomo(
            &app,
            r#"
proxy-providers:
  premium:
    type: http
    url: https://old.example/sub
proxy-groups:
  - name: proxy
    type: select
    use: []
    proxies: [DIRECT, REJECT]
"#,
        );

        sub_set(
            &app,
            &[
                "sub".to_string(),
                "set".to_string(),
                "mihomo".to_string(),
                "premium".to_string(),
                "https://new.example/sub".to_string(),
            ],
        )
        .unwrap();

        let text = fs::read_to_string(app.moddir.join(".config/mihomo/config.yaml")).unwrap();
        assert!(text.contains("https://new.example/sub"), "{text}");
        let saved_yaml: Value = serde_yaml::from_str(&text).unwrap();
        let saved_use = saved_yaml
            .get("proxy-groups")
            .and_then(Value::as_sequence)
            .and_then(|groups| groups.first())
            .and_then(|group| group.get("use"))
            .and_then(Value::as_sequence)
            .unwrap();
        assert!(saved_use
            .iter()
            .any(|item| item.as_str() == Some("premium")));
        let saved = fs::read_to_string(app.moddir.join(".config/mihomo/subscription.url")).unwrap();
        assert_eq!(saved, "https://new.example/sub\n");
    }

    #[test]
    fn setup_subscription_updates_singbox_and_default_mihomo_provider() {
        let app = temp_app();
        write_mihomo(
            &app,
            r#"
proxy-providers:
  premium_a:
    type: http
    path: ./proxies/A.yaml
    url: ""
"#,
        );

        setup_subscription(&app, "https://example.com/sub").unwrap();

        let singbox =
            fs::read_to_string(app.moddir.join(".config/sing-box/subscription.url")).unwrap();
        assert_eq!(singbox, "https://example.com/sub\n");
        let mihomo_sub =
            fs::read_to_string(app.moddir.join(".config/mihomo/subscription.url")).unwrap();
        assert_eq!(mihomo_sub, "https://example.com/sub\n");
        let text = fs::read_to_string(app.moddir.join(".config/mihomo/config.yaml")).unwrap();
        assert!(text.contains("https://example.com/sub"), "{text}");
        assert!(app.moddir.join(".config/mihomo/proxies").is_dir());
    }

    #[test]
    fn mihomo_provider_list_includes_empty_url_slots() {
        let app = temp_app();
        write_mihomo(
            &app,
            r#"
proxy-providers:
  premium_a:
    type: http
    path: ./proxies/A.yaml
    url: ""
  premium_b:
    type: http
    path: ./proxies/B.yaml
"#,
        );

        let providers = mihomo_providers(&app);

        assert_eq!(
            providers,
            vec![
                ("premium_a".to_string(), String::new()),
                ("premium_b".to_string(), String::new())
            ]
        );
    }

    #[test]
    fn shell_url_component_percent_encodes_provider_names_for_api_paths() {
        assert_eq!(shell_url_component("Premium HK"), "Premium%20HK");
        assert_eq!(shell_url_component("a/b?c=d"), "a%2Fb%3Fc%3Dd");
        assert_eq!(shell_url_component("az-AZ_09.~"), "az-AZ_09.~");
    }
}
