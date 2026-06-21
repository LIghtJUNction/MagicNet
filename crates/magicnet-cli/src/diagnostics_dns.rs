use std::fs;

use crate::App;

pub(super) fn dns_leak_check(app: &App, singbox: &str, mode: &str) -> (bool, String) {
    let transparent_dns = true;
    let cfg = singbox_dns_config(app, mode, transparent_dns);
    let core = if singbox != "stopped" {
        "sing-box"
    } else {
        "stopped"
    };
    (
        cfg.ok(),
        format!(
            "core={core}, mode={mode}, fakeip={}, hijack_dns={}, remote_dns_detour={}, store_fakeip={}, sniff_inbound={}, ebpf_dns_inbound={}, strategy={}",
            yes_no(cfg.fake_ip),
            yes_no(cfg.hijack),
            yes_no(cfg.remote_dns),
            yes_no(cfg.store_fake_ip),
            yes_no(cfg.sniff_inbound),
            yes_no(cfg.ebpf_dns_inbound),
            cfg.strategy,
        ),
    )
}

#[derive(Clone, Copy)]
struct SingboxDnsConfig {
    fake_ip: bool,
    hijack: bool,
    remote_dns: bool,
    store_fake_ip: bool,
    sniff_inbound: bool,
    ebpf_dns_inbound: bool,
    strategy: &'static str,
    ipv6_fallback_ready: bool,
    transparent_dns: bool,
    require_ebpf_dns_inbound: bool,
}

impl SingboxDnsConfig {
    fn ok(self) -> bool {
        let fallback_ok = !self.ipv6_fallback_ready || self.strategy == "ipv4_only";
        let ebpf_dns_ok = !self.require_ebpf_dns_inbound || self.ebpf_dns_inbound;
        self.fake_ip
            && self.hijack
            && self.remote_dns
            && self.store_fake_ip
            && self.sniff_inbound
            && ebpf_dns_ok
            && fallback_ok
            && self.transparent_dns
    }
}

fn singbox_dns_config(app: &App, mode: &str, transparent_dns: bool) -> SingboxDnsConfig {
    let text =
        fs::read_to_string(app.moddir.join(".config/sing-box/config.json")).unwrap_or_default();
    let compact = compact_jsonish(&text);
    let strategy = singbox_dns_strategy(&compact);
    let ipv6_fallback_ready = false;
    let require_ebpf_dns_inbound = mode != "tun";
    let sniff_inbound = sniff_rule_has(&compact, "mixed-in")
        && (mode == "ebpf" || sniff_rule_has(&compact, "tun-in"))
        && (!require_ebpf_dns_inbound
            || (sniff_rule_has(&compact, "magicnet-ebpf-dns4-in")
                && sniff_rule_has(&compact, "magicnet-ebpf-dns6-in")));
    SingboxDnsConfig {
        fake_ip: compact.contains("\"type\":\"fakeip\"") && compact.contains("\"tag\":\"fakeip\""),
        hijack: compact.contains("\"protocol\":\"dns\"")
            && compact.contains("\"action\":\"hijack-dns\""),
        remote_dns: has_remote_dns_detour(&compact),
        store_fake_ip: compact.contains("\"store_fakeip\":true"),
        sniff_inbound,
        ebpf_dns_inbound: has_ebpf_dns_inbounds(&compact),
        strategy,
        ipv6_fallback_ready,
        transparent_dns,
        require_ebpf_dns_inbound,
    }
}

fn sniff_rule_has(compact: &str, tag: &str) -> bool {
    compact.contains("\"action\":\"sniff\"") && compact.contains(&format!("\"{tag}\""))
}

fn has_ebpf_dns_inbounds(compact: &str) -> bool {
    compact.contains("\"tag\":\"magicnet-ebpf-dns4-in\"")
        && compact.contains("\"listen\":\"127.0.0.1\"")
        && compact.contains("\"tag\":\"magicnet-ebpf-dns6-in\"")
        && compact.contains("\"listen\":\"::1\"")
        && compact.contains("\"listen_port\":")
}

fn singbox_dns_strategy(compact: &str) -> &'static str {
    if compact.contains("\"strategy\":\"ipv4_only\"") {
        "ipv4_only"
    } else if compact.contains("\"strategy\":\"prefer_ipv4\"") {
        "prefer_ipv4"
    } else if compact.contains("\"strategy\":\"prefer_ipv6\"") {
        "prefer_ipv6"
    } else if compact.contains("\"strategy\":\"ipv6_only\"") {
        "ipv6_only"
    } else {
        "unset"
    }
}

fn has_remote_dns_detour(compact: &str) -> bool {
    compact.contains("\"detour\":\"proxy\"")
        && (compact.contains("\"server\":\"dns.google\"")
            || compact.contains("\"server\":\"cloudflare-dns.com\"")
            || compact.contains("\"server\":\"dns.adguard-dns.com\"")
            || compact.contains("\"server_name\":\"dns.google\"")
            || compact.contains("\"server_name\":\"cloudflare-dns.com\"")
            || compact.contains("\"server_name\":\"dns.adguard-dns.com\""))
}

fn compact_jsonish(text: &str) -> String {
    text.chars()
        .filter(|ch| !ch.is_ascii_whitespace())
        .collect()
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "ok"
    } else {
        "missing"
    }
}

#[cfg(test)]
mod tests {
    use super::{compact_jsonish, has_remote_dns_detour};

    #[test]
    fn remote_dns_detour_accepts_tls_server_name() {
        let config = r#"
        {
          "dns": {
            "servers": [
              {
                "type": "https",
                "tag": "doh-google",
                "detour": "proxy",
                "server": "8.8.8.8",
                "server_port": 443,
                "tls": {
                  "server_name": "dns.google"
                }
              }
            ]
          }
        }
        "#;

        assert!(has_remote_dns_detour(&compact_jsonish(config)));
    }

    #[test]
    fn remote_dns_detour_requires_proxy_detour() {
        let config = r#"
        {
          "dns": {
            "servers": [
              {
                "type": "https",
                "tag": "doh-google",
                "server": "dns.google"
              }
            ]
          }
        }
        "#;

        assert!(!has_remote_dns_detour(&compact_jsonish(config)));
    }
}
