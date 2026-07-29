use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::service::restart_current_core;
use crate::subscriptions::validate_subscription_url;
use crate::{clean_lines, read_kv, run_magicnet_function, shell_inert_conf_value, write_kv, App};

use super::{conf_dir, normalize_allow_rule, normalize_block_rule, print_lines, update_line};

const BLOCK_CONF: &str = ".config/magicnet/block.conf";
/// Keep a compromised community source from consuming more than 8 MiB of CLI memory.
const MAX_COMMUNITY_BLOCKLIST_BYTES: usize = 8 * 1024 * 1024;
/// Bound parser work independently of the byte budget.
const MAX_COMMUNITY_BLOCKLIST_LINES: usize = 250_000;
const MAX_COMMUNITY_BLOCKLIST_RULES: usize = 100_000;

pub(crate) fn block_cmd(app: &App, args: &[String]) -> Result<(), String> {
    let dir = conf_dir(app);
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => {
            block_list(app);
            Ok(())
        }
        "enable" | "disable" => block_toggle(app, args[0].as_str()),
        "community" => block_community(app, args),
        "url" => block_url(app, args),
        "add-domain" | "remove-domain" => block_domain(app, args),
        "allow-rule" | "unallow-rule" => block_allow(app, args),
        "apply" => apply_and_restart(app),
        "update" => block_update(app),
        "diff" => block_diff(dir),
        _ => Err("Usage: cli block {list|enable|disable|community <on|off>|url <http-url>|update|add-domain <suffix>|remove-domain <suffix>|allow-rule <rule>|unallow-rule <rule>|diff|apply}".to_string()),
    }
}

fn block_list(app: &App) {
    let dir = conf_dir(app);
    let conf = block_conf_values(app);
    println!(
        "enabled={}",
        conf.get("MAGICNET_BLOCK_ENABLED")
            .map(String::as_str)
            .unwrap_or("1")
    );
    println!(
        "community={}",
        conf.get("MAGICNET_BLOCK_COMMUNITY_ENABLED")
            .map(String::as_str)
            .unwrap_or("1")
    );
    println!(
        "url={}",
        conf.get("MAGICNET_BLOCK_URL")
            .map(String::as_str)
            .unwrap_or(default_block_url())
    );
    println!("manual domain suffixes:");
    print_lines(dir.join("block-domain-suffix.list"));
    let allow = clean_lines(dir.join("block-allow-rules.list"));
    println!("community rules:");
    for line in clean_lines(dir.join("community-ban-rules.list"))
        .into_iter()
        .filter(|line| !allow.contains(line))
    {
        println!("  {line}");
    }
    println!("community domain suffixes:");
    print_lines(dir.join("community-ban-domain-suffix.list"));
    println!("local allow rules:");
    for line in allow {
        println!("  {line}");
    }
}

fn block_toggle(app: &App, action: &str) -> Result<(), String> {
    let mut conf = block_conf_values(app);
    conf.insert(
        "MAGICNET_BLOCK_ENABLED".to_string(),
        if action == "enable" { "1" } else { "0" }.to_string(),
    );
    write_block_conf(app, &conf)?;
    apply_and_restart(app)?;
    println!(
        "[info] Blocklist {}",
        if action == "enable" {
            "enabled"
        } else {
            "disabled"
        }
    );
    Ok(())
}

fn block_community(app: &App, args: &[String]) -> Result<(), String> {
    let value = match args.get(1).map(String::as_str).unwrap_or_default() {
        "on" | "enable" | "1" => "1",
        "off" | "disable" | "0" => "0",
        _ => return Err("Usage: cli block community <on|off>".to_string()),
    };
    let mut conf = block_conf_values(app);
    conf.insert(
        "MAGICNET_BLOCK_COMMUNITY_ENABLED".to_string(),
        value.to_string(),
    );
    write_block_conf(app, &conf)?;
    apply_and_restart(app)?;
    println!(
        "[info] Community blocklist {}",
        if value == "1" { "enabled" } else { "disabled" }
    );
    Ok(())
}

fn block_url(app: &App, args: &[String]) -> Result<(), String> {
    let url = args.get(1).map(String::as_str).unwrap_or_default();
    validate_subscription_url(url)?;
    // Keep the on-disk schema restricted to inert URL characters. The device
    // reader parses this schema rather than sourcing it, but the same allowlist
    // prevents malformed legacy data from being persisted again.
    if !block_url_is_safe(url) {
        return Err("Blocklist URL may only contain unreserved URL characters".to_string());
    }
    let mut conf = block_conf_values(app);
    conf.insert("MAGICNET_BLOCK_URL".to_string(), url.to_string());
    write_block_conf(app, &conf)?;
    println!("[info] Blocklist URL saved");
    Ok(())
}

fn block_domain(app: &App, args: &[String]) -> Result<(), String> {
    let domain = args.get(1).map(String::as_str).unwrap_or_default();
    if domain.is_empty() {
        return Err("Usage: cli block {add-domain|remove-domain} <domain-suffix>".to_string());
    }
    update_line(
        app,
        conf_dir(app).join("block-domain-suffix.list"),
        domain,
        args[0] == "add-domain",
    )?;
    apply_and_restart(app)?;
    println!("[info] Manual blocklist updated");
    Ok(())
}

fn block_allow(app: &App, args: &[String]) -> Result<(), String> {
    let rule = args.get(1).map(String::as_str).unwrap_or_default();
    if rule.is_empty() {
        return Err("Usage: cli block {allow-rule|unallow-rule} <rule>".to_string());
    }
    let normalized = normalize_allow_rule(rule)?;
    let path = conf_dir(app).join("block-allow-rules.list");
    let add = args[0] == "allow-rule";
    if !add {
        let legacy = normalize_block_rule(rule);
        if legacy != normalized {
            update_line(app, path.clone(), &legacy, false)?;
        }
    }
    update_line(app, path, &normalized, add)?;
    apply_and_restart(app)?;
    println!("[info] Local allow rule updated");
    Ok(())
}

fn block_update(app: &App) -> Result<(), String> {
    let dir = conf_dir(app);
    let conf = block_conf_values(app);
    let url = conf
        .get("MAGICNET_BLOCK_URL")
        .map(String::as_str)
        .unwrap_or(default_block_url());
    validate_subscription_url(url)?;

    let (text, source) = match download_blocklist(url) {
        Ok(text) => (text, "remote".to_string()),
        Err(err) => {
            let fallback = app.moddir.join(".config/magicnet/community-ban.yaml");
            let text = fs::read_to_string(&fallback).map_err(|read_err| {
                format!(
                    "download blocklist failed: {err}; read fallback {}: {read_err}",
                    fallback.display()
                )
            })?;
            (text, format!("fallback: {}", fallback.display()))
        }
    };
    // Parse everything before replacing either persisted rule file. A malformed
    // or oversized update must leave the last known-good rules intact.
    let rules = parse_community_rules(&text)?;
    let domains = rules
        .iter()
        .filter_map(|rule| {
            rule.strip_prefix("DOMAIN-SUFFIX,")
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
        })
        .collect::<Vec<_>>();
    write_lines(app, dir.join("community-ban-rules.list"), &rules)?;
    write_lines(app, dir.join("community-ban-domain-suffix.list"), &domains)?;
    apply_and_restart(app)?;
    println!(
        "[info] Community blocklist updated from {source}: rules={}, domain_suffixes={}",
        rules.len(),
        domains.len()
    );
    Ok(())
}

fn download_blocklist(url: &str) -> Result<String, String> {
    let max_bytes = MAX_COMMUNITY_BLOCKLIST_BYTES.to_string();
    let mut child = Command::new("curl")
        .args([
            "-fsSL",
            "--max-filesize",
            &max_bytes,
            "--connect-timeout",
            "8",
            "--max-time",
            "30",
            url,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|err| format!("run curl: {err}"))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| "capture blocklist download failed".to_string())?;
    let mut bytes = Vec::with_capacity(MAX_COMMUNITY_BLOCKLIST_BYTES.min(64 * 1024));
    stdout
        .by_ref()
        .take((MAX_COMMUNITY_BLOCKLIST_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|err| format!("read blocklist download: {err}"))?;
    if bytes.len() > MAX_COMMUNITY_BLOCKLIST_BYTES {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!(
            "community blocklist exceeds {MAX_COMMUNITY_BLOCKLIST_BYTES} byte limit"
        ));
    }
    if child
        .wait()
        .map_err(|err| format!("wait for curl: {err}"))?
        .success()
    {
        return String::from_utf8(bytes)
            .map_err(|_| "community blocklist is not UTF-8".to_string());
    }
    Err(format!("download blocklist failed: {url}"))
}

fn apply_and_restart(app: &App) -> Result<(), String> {
    // Runtime application reads block.conf on-device. Normalize and persist it
    // immediately before that hand-off so `block apply` and `block update`
    // cannot leave legacy or injected content for the shell reader.
    persist_normalized_block_conf(app)?;
    run_magicnet_function(app, "magicnet_block_apply")?;
    restart_current_core(app)
}

fn persist_normalized_block_conf(app: &App) -> Result<(), String> {
    let conf = block_conf_values(app);
    write_block_conf(app, &conf)
}

fn parse_community_rules(text: &str) -> Result<Vec<String>, String> {
    if text.as_bytes().len() > MAX_COMMUNITY_BLOCKLIST_BYTES {
        return Err(format!(
            "community blocklist exceeds {MAX_COMMUNITY_BLOCKLIST_BYTES} byte limit"
        ));
    }
    let mut seen = HashSet::new();
    let mut rules = Vec::new();
    for (line_number, raw) in text.lines().enumerate() {
        if line_number >= MAX_COMMUNITY_BLOCKLIST_LINES {
            return Err(format!(
                "community blocklist exceeds {MAX_COMMUNITY_BLOCKLIST_LINES} line limit"
            ));
        }
        let line = raw
            .trim()
            .trim_start_matches('-')
            .trim()
            .trim_matches('"')
            .trim_matches('\'');
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.ends_with(':') {
            continue;
        }
        let rule = normalize_block_rule(line);
        if matches!(
            rule.split(',').next().unwrap_or_default(),
            "DOMAIN" | "DOMAIN-SUFFIX" | "DOMAIN-KEYWORD"
        ) && seen.insert(rule.clone())
        {
            rules.push(rule);
            if rules.len() > MAX_COMMUNITY_BLOCKLIST_RULES {
                return Err(format!(
                    "community blocklist exceeds {MAX_COMMUNITY_BLOCKLIST_RULES} rule limit"
                ));
            }
        }
    }
    Ok(rules)
}

fn write_lines(app: &App, path: PathBuf, values: &[String]) -> Result<(), String> {
    let text = values
        .iter()
        .map(|value| format!("{value}\n"))
        .collect::<String>();
    let relative = path
        .strip_prefix(&app.moddir)
        .map_err(|_| "refusing to write block rules outside the module root".to_string())?;
    crate::write_text_file(app, relative, &text)
}

fn block_diff(dir: PathBuf) -> Result<(), String> {
    for domain in clean_lines(dir.join("block-domain-suffix.list")) {
        println!("+ DOMAIN-SUFFIX,{domain}");
    }
    for rule in clean_lines(dir.join("block-allow-rules.list")) {
        println!("- {rule}");
    }
    Ok(())
}

fn block_conf_values(app: &App) -> HashMap<String, String> {
    let mut conf = read_kv(conf_dir(app).join("block.conf"));
    sanitize_block_conf(&mut conf);
    conf
}

fn write_block_conf(app: &App, conf: &HashMap<String, String>) -> Result<(), String> {
    // This is the persistence sink for both CLI and WebUI paths. Revalidate
    // every field here so a malformed legacy map cannot be re-emitted into the
    // shell-sourced configuration file.
    write_kv(
        app,
        Path::new(BLOCK_CONF),
        &[
            (
                "MAGICNET_BLOCK_ENABLED",
                safe_block_flag(conf.get("MAGICNET_BLOCK_ENABLED")),
            ),
            (
                "MAGICNET_BLOCK_COMMUNITY_ENABLED",
                safe_block_flag(conf.get("MAGICNET_BLOCK_COMMUNITY_ENABLED")),
            ),
            (
                "MAGICNET_BLOCK_URL",
                safe_block_url(conf.get("MAGICNET_BLOCK_URL")),
            ),
        ],
    )
}

fn sanitize_block_conf(conf: &mut HashMap<String, String>) {
    let enabled = safe_block_flag(conf.get("MAGICNET_BLOCK_ENABLED"));
    let community_enabled = safe_block_flag(conf.get("MAGICNET_BLOCK_COMMUNITY_ENABLED"));
    let url = safe_block_url(conf.get("MAGICNET_BLOCK_URL"));

    conf.insert("MAGICNET_BLOCK_ENABLED".to_string(), enabled);
    conf.insert(
        "MAGICNET_BLOCK_COMMUNITY_ENABLED".to_string(),
        community_enabled,
    );
    conf.insert("MAGICNET_BLOCK_URL".to_string(), url);
}

fn block_url_is_safe(url: &str) -> bool {
    validate_subscription_url(url).is_ok() && shell_inert_conf_value(url)
}

fn safe_block_flag(value: Option<&String>) -> String {
    value
        .filter(|value| matches!(value.as_str(), "0" | "1"))
        .cloned()
        .unwrap_or_else(|| "1".to_string())
}

fn safe_block_url(value: Option<&String>) -> String {
    value
        .filter(|value| block_url_is_safe(value))
        .cloned()
        .unwrap_or_else(|| default_block_url().to_string())
}

fn default_block_url() -> &'static str {
    "https://raw.githubusercontent.com/LIghtJUNction/MagicNet/main/src/MagicNet/.config/magicnet/community-ban.yaml"
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    fn temp_app() -> App {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is after the Unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("magicnet-block-conf-test-{stamp}"));
        fs::create_dir_all(&root).expect("create module root");
        App::for_test(root)
    }

    #[test]
    fn invalid_legacy_block_url_is_replaced_before_it_can_be_reemitted() {
        let app = temp_app();
        let path = conf_dir(&app).join("block.conf");
        fs::create_dir_all(path.parent().expect("block config parent"))
            .expect("create block config parent");
        fs::write(
            &path,
            "MAGICNET_BLOCK_ENABLED=1\nMAGICNET_BLOCK_COMMUNITY_ENABLED=1\nMAGICNET_BLOCK_URL=https://example.com/list;reboot\n",
        )
        .expect("write legacy block config");

        let values = block_conf_values(&app);
        assert_eq!(
            values.get("MAGICNET_BLOCK_URL").map(String::as_str),
            Some(default_block_url())
        );
        write_block_conf(&app, &values).expect("rewrite sanitized block config");

        let contents = fs::read_to_string(path).expect("read rewritten block config");
        assert!(!contents.contains("list;reboot"));
        assert!(contents.contains(default_block_url()));
    }

    #[test]
    fn write_block_conf_sanitizes_every_field_at_the_persistence_sink() {
        let app = temp_app();
        let mut values = HashMap::new();
        values.insert("MAGICNET_BLOCK_ENABLED".to_string(), "yes".to_string());
        values.insert(
            "MAGICNET_BLOCK_COMMUNITY_ENABLED".to_string(),
            "maybe".to_string(),
        );
        values.insert(
            "MAGICNET_BLOCK_URL".to_string(),
            "https://example.com/list;id".to_string(),
        );

        write_block_conf(&app, &values).expect("write sanitized block config");

        let contents = fs::read_to_string(conf_dir(&app).join("block.conf"))
            .expect("read sanitized block config");
        assert!(contents.contains("MAGICNET_BLOCK_ENABLED=1\n"));
        assert!(contents.contains("MAGICNET_BLOCK_COMMUNITY_ENABLED=1\n"));
        assert!(contents.contains(&format!("MAGICNET_BLOCK_URL={}\n", default_block_url())));
        assert!(!contents.contains(";id"));
    }

    #[test]
    fn runtime_handoff_rewrites_legacy_block_conf_before_shell_consumption() {
        let app = temp_app();
        let path = conf_dir(&app).join("block.conf");
        fs::create_dir_all(path.parent().expect("block config parent"))
            .expect("create block config parent");
        fs::write(
            &path,
            "MAGICNET_BLOCK_ENABLED=0\nMAGICNET_BLOCK_URL=https://example.com/list;touch /tmp/untrusted\nUNKNOWN=1\n",
        )
        .expect("write legacy block config");

        persist_normalized_block_conf(&app).expect("rewrite normalized block config");

        let contents = fs::read_to_string(path).expect("read normalized block config");
        assert_eq!(contents.lines().count(), 3);
        assert!(!contents.contains("UNKNOWN"));
        assert!(!contents.contains(";touch"));
        assert!(contents.contains(default_block_url()));
    }

    #[test]
    fn community_rules_preserve_first_seen_order_and_deduplicate() {
        let rules = parse_community_rules(
            "DOMAIN-SUFFIX,first.example\nDOMAIN,second.example\nDOMAIN-SUFFIX,first.example\n",
        )
        .expect("parse bounded community rules");

        assert_eq!(
            rules,
            ["DOMAIN-SUFFIX,first.example", "DOMAIN,second.example"]
        );
    }

    #[test]
    fn community_rules_reject_the_rule_limit() {
        let input = (0..=MAX_COMMUNITY_BLOCKLIST_RULES)
            .map(|index| format!("DOMAIN,rule-{index}.example\n"))
            .collect::<String>();

        assert!(parse_community_rules(&input).is_err());
    }

    #[test]
    fn community_rules_reject_the_byte_limit_before_parsing() {
        let input = "x".repeat(MAX_COMMUNITY_BLOCKLIST_BYTES + 1);
        assert!(parse_community_rules(&input).is_err());
    }
}
