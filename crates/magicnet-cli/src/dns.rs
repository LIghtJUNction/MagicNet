use std::fs;
use std::process::Command;

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
        "test" => dns_test(args.get(1).map(String::as_str).unwrap_or("www.gstatic.com")),
        "apply" => {
            run_magicnet_function(app, "magicnet_dns_apply")?;
            Ok(())
        }
        _ => Err(dns_usage()),
    }
}

fn dns_test(domain: &str) -> Result<(), String> {
    let domain = normalize_test_domain(domain)?;
    let url = format!("https://{domain}/");
    let output = Command::new("curl")
        .args([
            "-fsS",
            "--max-time",
            "6",
            "-o",
            "/dev/null",
            "-w",
            "domain=%{url_effective}\nremote_ip=%{remote_ip}\ntime_total=%{time_total}\n",
            &url,
        ])
        .output()
        .map_err(|err| format!("run curl: {err}"))?;
    print!("{}", String::from_utf8_lossy(&output.stdout));
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
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

fn normalize_test_domain(domain: &str) -> Result<&str, String> {
    let domain = domain.trim().trim_end_matches('.');
    if domain.is_empty() || domain.len() > 253 {
        return Err("Usage: cli dns test [domain]".to_string());
    }
    let valid = domain.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    });
    if valid && domain.contains('.') {
        Ok(domain)
    } else {
        Err("Usage: cli dns test [domain]".to_string())
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
    "Usage: cli dns {status|set <default|cloudflare-doh|cloudflare-dot|cloudflare-udp>|test [domain]|apply}"
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::normalize_test_domain;

    #[test]
    fn dns_test_domain_rejects_urls_and_shell_fragments() {
        assert_eq!(normalize_test_domain("example.com").unwrap(), "example.com");
        assert!(normalize_test_domain("https://example.com").is_err());
        assert!(normalize_test_domain("example.com;id").is_err());
        assert!(normalize_test_domain("localhost").is_err());
    }
}
