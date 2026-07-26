use std::fs;

use serde_json::Value;

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
            "core={core}, mode={mode}, valid_json={}, fakeip={}, hijack_dns={}, remote_dns_detour={}, store_fakeip={}, sniff_inbound={}, strategy={}, ipv6_guard={}",
            yes_no(cfg.valid_json),
            yes_no(cfg.fake_ip),
            yes_no(cfg.hijack),
            yes_no(cfg.remote_dns),
            yes_no(cfg.store_fake_ip),
            yes_no(cfg.sniff_inbound),
            cfg.strategy,
            cfg.ipv6_guard.as_str(),
        ),
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Ipv6GuardStatus {
    Ok,
    Missing,
    NotRequired,
}

impl Ipv6GuardStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Missing => "missing",
            Self::NotRequired => "not_required",
        }
    }

    fn ok(self) -> bool {
        self != Self::Missing
    }
}

#[derive(Clone, Copy)]
struct SingboxDnsConfig {
    valid_json: bool,
    fake_ip: bool,
    hijack: bool,
    remote_dns: bool,
    store_fake_ip: bool,
    sniff_inbound: bool,
    strategy: &'static str,
    ipv6_guard: Ipv6GuardStatus,
    transparent_dns: bool,
}

impl SingboxDnsConfig {
    fn ok(self) -> bool {
        self.valid_json
            && self.fake_ip
            && self.hijack
            && self.remote_dns
            && self.store_fake_ip
            && self.sniff_inbound
            && self.ipv6_guard.ok()
            && self.transparent_dns
    }
}

fn singbox_dns_config(app: &App, mode: &str, transparent_dns: bool) -> SingboxDnsConfig {
    let text =
        fs::read_to_string(app.moddir.join(".config/sing-box/config.json")).unwrap_or_default();
    singbox_dns_config_from_text(&text, mode, transparent_dns)
}

fn singbox_dns_config_from_text(
    text: &str,
    _mode: &str,
    transparent_dns: bool,
) -> SingboxDnsConfig {
    let compact = compact_jsonish(text);
    let parsed = serde_json::from_str::<Value>(text).ok();
    let strategy = singbox_dns_strategy(parsed.as_ref());
    let ipv6_guard = ipv6_guard_status(strategy, parsed.as_ref());
    let sniff_inbound = sniff_rule_has(&compact, "mixed-in") && sniff_rule_has(&compact, "tun-in");
    SingboxDnsConfig {
        valid_json: parsed.is_some(),
        fake_ip: compact.contains("\"type\":\"fakeip\"") && compact.contains("\"tag\":\"fakeip\""),
        hijack: parsed.as_ref().is_some_and(has_dns_hijack_rule),
        remote_dns: has_remote_dns_detour(&compact),
        store_fake_ip: compact.contains("\"store_fakeip\":true"),
        sniff_inbound,
        strategy,
        ipv6_guard,
        transparent_dns,
    }
}

fn has_dns_hijack_rule(config: &Value) -> bool {
    config
        .get("route")
        .and_then(|route| route.get("rules"))
        .and_then(Value::as_array)
        .is_some_and(|rules| {
            rules.iter().any(|rule| {
                rule.as_object().is_some_and(|rule| {
                    value_contains_string(rule.get("action"), "hijack-dns")
                        && (value_contains_string(rule.get("protocol"), "dns")
                            || value_contains_string(rule.get("inbound"), "magicnet-dns-in"))
                })
            })
        })
}

fn value_contains_string(value: Option<&Value>, expected: &str) -> bool {
    match value {
        Some(Value::String(value)) => value == expected,
        Some(Value::Array(values)) => values.iter().any(|value| value.as_str() == Some(expected)),
        _ => false,
    }
}

fn ipv6_guard_status(strategy: &str, config: Option<&Value>) -> Ipv6GuardStatus {
    if strategy != "ipv4_only" {
        return Ipv6GuardStatus::NotRequired;
    }

    if config.is_some_and(has_ipv6_reject_guard) {
        Ipv6GuardStatus::Ok
    } else {
        Ipv6GuardStatus::Missing
    }
}

fn has_ipv6_reject_guard(config: &Value) -> bool {
    config
        .get("route")
        .and_then(|route| route.get("rules"))
        .and_then(Value::as_array)
        .is_some_and(|rules| {
            rules.iter().any(|rule| {
                rule.as_object().is_some_and(|rule| {
                    let canonical_fields = rule.len() == 3 && !rule.contains_key("method")
                        || rule.len() == 4
                            && rule.get("method").and_then(Value::as_str) == Some("default");
                    canonical_fields
                        && rule.get("ip_version").and_then(Value::as_u64) == Some(6)
                        && rule.get("action").and_then(Value::as_str) == Some("reject")
                        && rule.get("no_drop").and_then(Value::as_bool) == Some(true)
                })
            })
        })
}

fn sniff_rule_has(compact: &str, tag: &str) -> bool {
    compact.contains("\"action\":\"sniff\"") && compact.contains(&format!("\"{tag}\""))
}

fn singbox_dns_strategy(config: Option<&Value>) -> &'static str {
    match config
        .and_then(|config| config.get("dns"))
        .and_then(|dns| dns.get("strategy"))
        .and_then(Value::as_str)
    {
        Some("ipv4_only") => "ipv4_only",
        Some("prefer_ipv4") => "prefer_ipv4",
        Some("prefer_ipv6") => "prefer_ipv6",
        Some("ipv6_only") => "ipv6_only",
        _ => "unset",
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
    use super::{
        compact_jsonish, has_remote_dns_detour, ipv6_guard_status, singbox_dns_config_from_text,
        singbox_dns_strategy, Ipv6GuardStatus, SingboxDnsConfig,
    };
    use serde_json::Value;

    fn parsed(json: &str) -> Value {
        serde_json::from_str(json).expect("test JSON must be valid")
    }

    fn healthy_config(strategy: &'static str, ipv6_guard: Ipv6GuardStatus) -> SingboxDnsConfig {
        SingboxDnsConfig {
            valid_json: true,
            fake_ip: true,
            hijack: true,
            remote_dns: true,
            store_fake_ip: true,
            sniff_inbound: true,
            strategy,
            ipv6_guard,
            transparent_dns: true,
        }
    }

    #[test]
    fn dns_hijack_accepts_dedicated_inbound_array_rule() {
        let config = singbox_dns_config_from_text(
            r#"{"route":{"rules":[{"inbound":["magicnet-dns-in"],"action":"hijack-dns"}]}}"#,
            "tun",
            true,
        );

        assert!(config.hijack);
    }

    #[test]
    fn dns_hijack_accepts_protocol_string_rule() {
        let config = singbox_dns_config_from_text(
            r#"{"route":{"rules":[{"protocol":"dns","action":"hijack-dns"}]}}"#,
            "tun",
            true,
        );

        assert!(config.hijack);
    }

    #[test]
    fn dns_hijack_rejects_action_and_matcher_in_different_rules() {
        let config = singbox_dns_config_from_text(
            r#"{"route":{"rules":[{"protocol":"dns"},{"action":"hijack-dns"}]}}"#,
            "tun",
            true,
        );

        assert!(!config.hijack);
    }

    #[test]
    fn dns_hijack_rejects_unrelated_inbound_rule() {
        let config = singbox_dns_config_from_text(
            r#"{"route":{"rules":[{"inbound":["mixed-in"],"action":"hijack-dns"}]}}"#,
            "tun",
            true,
        );

        assert!(!config.hijack);
    }

    #[test]
    fn dns_hijack_rejects_malformed_json_with_matching_tokens() {
        let config = singbox_dns_config_from_text(
            r#"{"route":{"rules":[{"protocol":"dns","action":"hijack-dns"}]}} trailing"#,
            "tun",
            true,
        );

        assert!(!config.hijack);
    }

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

    #[test]
    fn ipv4_only_with_ipv6_reject_guard_passes() {
        let config = parsed(
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","method":"default","no_drop":true}]}}"#,
        );
        let guard = ipv6_guard_status("ipv4_only", Some(&config));

        assert!(healthy_config("ipv4_only", guard).ok());
    }

    #[test]
    fn ipv4_only_with_implicit_default_ipv6_reject_guard_passes() {
        let config =
            parsed(r#"{"route":{"rules":[{"ip_version":6,"action":"reject","no_drop":true}]}}"#);
        let guard = ipv6_guard_status("ipv4_only", Some(&config));

        assert!(healthy_config("ipv4_only", guard).ok());
    }

    #[test]
    fn ipv4_only_without_ipv6_reject_guard_fails() {
        let config = parsed(r#"{"route":{"rules":[]}}"#);
        let guard = ipv6_guard_status("ipv4_only", Some(&config));

        assert!(!healthy_config("ipv4_only", guard).ok());
    }

    #[test]
    fn ipv4_only_with_malformed_config_fails() {
        let guard = ipv6_guard_status("ipv4_only", None);

        assert!(!healthy_config("ipv4_only", guard).ok());
    }

    #[test]
    fn malformed_json_with_all_health_tokens_is_unhealthy() {
        let malformed = r#"
        {
          "dns": {
            "servers": [
              {"type": "fakeip", "tag": "fakeip"},
              {"server": "dns.google", "detour": "proxy"}
            ]
          },
          "experimental": {"cache_file": {"store_fakeip": true}},
          "route": {
            "rules": [
              {"protocol": "dns", "action": "hijack-dns"},
              {"action": "sniff", "inbound": ["mixed-in", "tun-in"]}
            ]
          }
        }
        trailing-invalid-json
        "#;

        let config = singbox_dns_config_from_text(malformed, "tun", true);

        assert_eq!(
            (
                config.fake_ip,
                config.hijack,
                config.remote_dns,
                config.store_fake_ip,
                config.sniff_inbound,
                config.valid_json,
                config.ok(),
            ),
            (true, false, true, true, true, false, false)
        );
    }

    #[test]
    fn prefer_ipv4_without_ipv6_reject_guard_does_not_fail() {
        let config = parsed(r#"{"route":{"rules":[]}}"#);
        let guard = ipv6_guard_status("prefer_ipv4", Some(&config));

        assert!(healthy_config("prefer_ipv4", guard).ok());
    }

    #[test]
    fn ipv6_reject_guard_rejects_legacy_lookalikes_and_wrong_values() {
        let invalid = [
            r#"{"route":{"rules":[{"ip_version":6,"outbound":"block"}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","method":"default"}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","no_drop":false}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","method":"default","no_drop":false}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","method":"drop","no_drop":true}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","method":"default","no_drop":true,"network":"tcp"}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","no_drop":true,"network":"tcp"}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","method":"default","no_drop":true,"domain_suffix":["example.com"]}]}}"#,
            r#"{"route":{"rules":[{"ip_version":"6","action":"reject","method":"default","no_drop":true}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6.0,"action":"reject","method":"default","no_drop":true}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"Reject","method":"default","no_drop":true}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","method":"DEFAULT","no_drop":true}]}}"#,
            r#"{"route":{"rules":[{"ip_version":6,"action":"reject","method":"default","no_drop":"true"}]}}"#,
        ];

        assert!(invalid.iter().all(|json| {
            ipv6_guard_status("ipv4_only", Some(&parsed(json))) == Ipv6GuardStatus::Missing
        }));
    }

    #[test]
    fn ipv6_reject_guard_is_independent_of_field_order() {
        let config = parsed(
            r#"{"route":{"rules":[{"no_drop":true,"method":"default","action":"reject","ip_version":6}]}}"#,
        );

        assert_eq!(
            ipv6_guard_status("ipv4_only", Some(&config)),
            Ipv6GuardStatus::Ok
        );
    }

    #[test]
    fn dns_strategy_ignores_out_of_scope_strategy_strings() {
        let config = parsed(
            r#"{"dns":{"strategy":"prefer_ipv4","servers":[{"strategy":"ipv4_only"}]},"route":{"strategy":"ipv6_only"}}"#,
        );

        assert_eq!(singbox_dns_strategy(Some(&config)), "prefer_ipv4");
    }

    #[test]
    fn dns_strategy_rejects_missing_wrong_type_and_malformed_values() {
        let missing = parsed(r#"{"dns":{}}"#);
        let wrong_type = parsed(r#"{"dns":{"strategy":["ipv4_only"]}}"#);
        let unknown = parsed(r#"{"dns":{"strategy":"IPv4_only"}}"#);

        assert_eq!(
            [
                singbox_dns_strategy(Some(&missing)),
                singbox_dns_strategy(Some(&wrong_type)),
                singbox_dns_strategy(Some(&unknown)),
                singbox_dns_strategy(None),
            ],
            ["unset"; 4]
        );
    }
}
