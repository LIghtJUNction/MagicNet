use std::collections::HashMap;
use std::path::PathBuf;

use crate::subscriptions::validate_subscription_url;
use crate::{clean_lines, read_kv, run_magicnet_function, write_kv, App};

use super::{conf_dir, normalize_block_rule, print_lines, update_line};

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
        "apply" | "update" => run_magicnet_function(app, "magicnet_block_apply"),
        "diff" => block_diff(dir),
        _ => Err("Usage: cli block {list|enable|disable|community <on|off>|url <http-url>|update|add-domain <suffix>|remove-domain <suffix>|allow-rule <rule>|unallow-rule <rule>|diff|apply}".to_string()),
    }
}

fn block_list(app: &App) {
    let dir = conf_dir(app);
    let conf = read_kv(dir.join("block.conf"));
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
    run_magicnet_function(app, "magicnet_block_apply")?;
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
    run_magicnet_function(app, "magicnet_block_apply")?;
    println!(
        "[info] Community blocklist {}",
        if value == "1" { "enabled" } else { "disabled" }
    );
    Ok(())
}

fn block_url(app: &App, args: &[String]) -> Result<(), String> {
    let url = args.get(1).map(String::as_str).unwrap_or_default();
    validate_subscription_url(url)?;
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
        conf_dir(app).join("block-domain-suffix.list"),
        domain,
        args[0] == "add-domain",
    )?;
    run_magicnet_function(app, "magicnet_block_apply")?;
    println!("[info] Manual blocklist updated");
    Ok(())
}

fn block_allow(app: &App, args: &[String]) -> Result<(), String> {
    let rule = args.get(1).map(String::as_str).unwrap_or_default();
    if rule.is_empty() {
        return Err("Usage: cli block {allow-rule|unallow-rule} <rule>".to_string());
    }
    update_line(
        conf_dir(app).join("block-allow-rules.list"),
        &normalize_block_rule(rule),
        args[0] == "allow-rule",
    )?;
    run_magicnet_function(app, "magicnet_block_apply")?;
    println!("[info] Local allow rule updated");
    Ok(())
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
    conf.entry("MAGICNET_BLOCK_ENABLED".to_string())
        .or_insert_with(|| "1".to_string());
    conf.entry("MAGICNET_BLOCK_COMMUNITY_ENABLED".to_string())
        .or_insert_with(|| "1".to_string());
    conf.entry("MAGICNET_BLOCK_URL".to_string())
        .or_insert_with(|| default_block_url().to_string());
    conf
}

fn write_block_conf(app: &App, conf: &HashMap<String, String>) -> Result<(), String> {
    write_kv(
        conf_dir(app).join("block.conf"),
        &[
            (
                "MAGICNET_BLOCK_ENABLED",
                conf.get("MAGICNET_BLOCK_ENABLED")
                    .cloned()
                    .unwrap_or_else(|| "1".to_string()),
            ),
            (
                "MAGICNET_BLOCK_COMMUNITY_ENABLED",
                conf.get("MAGICNET_BLOCK_COMMUNITY_ENABLED")
                    .cloned()
                    .unwrap_or_else(|| "1".to_string()),
            ),
            (
                "MAGICNET_BLOCK_URL",
                conf.get("MAGICNET_BLOCK_URL")
                    .cloned()
                    .unwrap_or_else(|| default_block_url().to_string()),
            ),
        ],
    )
}

fn default_block_url() -> &'static str {
    "https://raw.githubusercontent.com/LIghtJUNction/MagicMihomo/main/ruleset/magicnet/ban.yaml"
}
