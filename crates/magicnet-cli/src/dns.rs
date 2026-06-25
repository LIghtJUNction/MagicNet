use std::fs;

use crate::service::restart_current_core;
use crate::{run_magicnet_function, write_text_file, App};

const DNS_CONF: &str = ".config/magicnet/dns.conf";

pub(crate) fn dns_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            dns_status(app);
            Ok(())
        }
        "set" => dns_set(app, args.get(1).map(String::as_str).unwrap_or_default()),
        "apply" => {
            run_magicnet_function(app, "magicnet_dns_apply")?;
            Ok(())
        }
        _ => Err(dns_usage()),
    }
}

fn dns_status(app: &App) {
    let profile = dns_profile(app);
    println!("profile={profile}");
    match profile.as_str() {
        "cloudflare-udp" => {
            println!("primary=1.1.1.1");
            println!("secondary=1.0.0.1");
            println!("transport=udp");
        }
        "cloudflare-dot" => {
            println!("primary=tls://1.1.1.1");
            println!("secondary=tls://1.0.0.1");
            println!("transport=dot");
        }
        "cloudflare-doh" => {
            println!("primary=https://cloudflare-dns.com/dns-query");
            println!("secondary=https://1.0.0.1/dns-query");
            println!("transport=doh");
        }
        _ => {
            println!("primary=bootstrap-local-dns");
            println!("transport=default");
        }
    }
}

fn dns_set(app: &App, profile: &str) -> Result<(), String> {
    let profile = normalize_profile(profile)?;
    write_text_file(
        app.moddir.join(DNS_CONF),
        &format!("MAGICNET_DNS_PROFILE={profile}\n"),
    )?;
    run_magicnet_function(app, "magicnet_dns_apply")?;
    restart_current_core(app)?;
    println!("[info] DNS profile set to {profile}");
    Ok(())
}

fn normalize_profile(profile: &str) -> Result<&'static str, String> {
    match profile {
        "default" | "system" | "local" => Ok("default"),
        "cloudflare" | "cloudflare-doh" | "1.1.1.1-doh" | "doh" => Ok("cloudflare-doh"),
        "cloudflare-dot" | "1.1.1.1-dot" | "dot" => Ok("cloudflare-dot"),
        "cloudflare-udp" | "1.1.1.1" | "udp" => Ok("cloudflare-udp"),
        _ => Err(dns_usage()),
    }
}

fn dns_profile(app: &App) -> String {
    fs::read_to_string(app.moddir.join(DNS_CONF))
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let (_, value) = line.split_once('=')?;
                normalize_profile(value.trim().trim_matches('"').trim_matches('\''))
                    .ok()
                    .map(ToOwned::to_owned)
            })
        })
        .unwrap_or_else(|| "default".to_string())
}

fn dns_usage() -> String {
    "Usage: cli dns {status|set <default|cloudflare-doh|cloudflare-dot|cloudflare-udp>|apply}"
        .to_string()
}
