use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde_json::Value;

use crate::service::restart_current_core;
use crate::{read_kv, run_magicnet_function, write_kv, App};

const NETWORK_POLICY_CONF: &str = ".config/magicnet/network-policy.conf";
const DEFAULT_IPV6_MODE: &str = "prefer_ipv4";
const DEFAULT_MTU: u16 = 1400;
const DEFAULT_UDP_TIMEOUT: &str = "5m";
pub(crate) const DEFAULT_DNS_CAPTURE_PORT: u16 = 1053;
pub(crate) const DEFAULT_TUN_INET: &str = "172.19.0.1/30";
pub(crate) const DEFAULT_TUN_INET6: &str = "fdfe:dcba:9876::1/126";

#[derive(Clone, Debug, Eq, PartialEq)]
struct NetworkPolicy {
    ipv6_mode: &'static str,
    mtu: u16,
    udp_timeout: &'static str,
}

impl Default for NetworkPolicy {
    fn default() -> Self {
        Self {
            ipv6_mode: DEFAULT_IPV6_MODE,
            mtu: DEFAULT_MTU,
            udp_timeout: DEFAULT_UDP_TIMEOUT,
        }
    }
}

pub(crate) fn network_cmd(app: &App, args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str).unwrap_or("status") {
        "status" => {
            print_status(app, &NetworkPolicy::load(app));
            Ok(())
        }
        "set" => {
            let policy = NetworkPolicy::from_args(&args[1..])?;
            policy.write(app)?;
            apply_network_policy(app)?;
            print_status(app, &policy);
            println!("[info] Network policy applied");
            Ok(())
        }
        "apply" => {
            apply_network_policy(app)?;
            print_status(app, &NetworkPolicy::load(app));
            Ok(())
        }
        _ => Err(network_usage()),
    }
}

fn apply_network_policy(app: &App) -> Result<(), String> {
    run_magicnet_function(app, "magicnet_transparent_apply")?;
    // sing-box reads the TUN inbound and DNS strategy at process start; a
    // successful file rewrite alone leaves a running core on the old policy.
    restart_current_core(app)
}

impl NetworkPolicy {
    fn load(app: &App) -> Self {
        let values = read_kv(app.moddir.join(NETWORK_POLICY_CONF));
        Self {
            ipv6_mode: normalize_ipv6_mode(
                values
                    .get("MAGICNET_IPV6_MODE")
                    .map(String::as_str)
                    .unwrap_or_default(),
            )
            .unwrap_or(DEFAULT_IPV6_MODE),
            mtu: normalize_mtu(
                values
                    .get("MAGICNET_TUN_MTU")
                    .map(String::as_str)
                    .unwrap_or_default(),
            )
            .unwrap_or(DEFAULT_MTU),
            udp_timeout: normalize_udp_timeout(
                values
                    .get("MAGICNET_UDP_TIMEOUT")
                    .map(String::as_str)
                    .unwrap_or_default(),
            )
            .unwrap_or(DEFAULT_UDP_TIMEOUT),
        }
    }

    fn from_args(args: &[String]) -> Result<Self, String> {
        if args.len() != 3 {
            return Err(network_usage());
        }
        Ok(Self {
            ipv6_mode: normalize_ipv6_mode(&args[0]).ok_or_else(network_usage)?,
            mtu: normalize_mtu(&args[1]).ok_or_else(network_usage)?,
            udp_timeout: normalize_udp_timeout(&args[2]).ok_or_else(network_usage)?,
        })
    }

    fn write(&self, app: &App) -> Result<(), String> {
        let existing = read_kv(app.moddir.join(NETWORK_POLICY_CONF));
        let mut values = vec![
            ("MAGICNET_IPV6_MODE", self.ipv6_mode.to_string()),
            ("MAGICNET_TUN_MTU", self.mtu.to_string()),
            ("MAGICNET_UDP_TIMEOUT", self.udp_timeout.to_string()),
        ];
        if let Some(port) = existing
            .get("MAGICNET_DNS_CAPTURE_PORT")
            .filter(|value| normalize_dns_capture_port(value).is_some())
        {
            values.push(("MAGICNET_DNS_CAPTURE_PORT", port.clone()));
        }
        if let Some(inet) = existing
            .get("MAGICNET_TUN_INET")
            .filter(|value| ipv4_tun_cidr_valid(value))
        {
            values.push(("MAGICNET_TUN_INET", inet.clone()));
        }
        if let Some(inet6) = existing
            .get("MAGICNET_TUN_INET6")
            .filter(|value| ipv6_tun_cidr_valid(value))
        {
            values.push(("MAGICNET_TUN_INET6", inet6.clone()));
        }
        write_kv(app, Path::new(NETWORK_POLICY_CONF), &values)
    }
}

fn normalize_ipv6_mode(value: &str) -> Option<&'static str> {
    match value {
        "ipv4_only" | "ipv4-only" | "compat" | "disabled" => Some("ipv4_only"),
        "prefer_ipv4" | "prefer-ipv4" | "auto" | "dual" => Some("prefer_ipv4"),
        "prefer_ipv6" | "prefer-ipv6" => Some("prefer_ipv6"),
        _ => None,
    }
}

fn normalize_mtu(value: &str) -> Option<u16> {
    value
        .parse::<u16>()
        .ok()
        .filter(|value| (1280..=1500).contains(value))
}

fn canonical_u16(value: &str) -> Option<u16> {
    value
        .parse::<u16>()
        .ok()
        .filter(|number| number.to_string() == value)
}

pub(crate) fn normalize_dns_capture_port(value: &str) -> Option<u16> {
    canonical_u16(value).filter(|port| *port >= 1)
}

pub(crate) fn configured_dns_capture_port(values: &HashMap<String, String>) -> u16 {
    values
        .get("MAGICNET_DNS_CAPTURE_PORT")
        .and_then(|value| normalize_dns_capture_port(value))
        .unwrap_or(DEFAULT_DNS_CAPTURE_PORT)
}

pub(crate) fn configured_tun_inet(values: &HashMap<String, String>) -> String {
    values
        .get("MAGICNET_TUN_INET")
        .filter(|value| ipv4_tun_cidr_valid(value))
        .cloned()
        .unwrap_or_else(|| DEFAULT_TUN_INET.to_string())
}

pub(crate) fn configured_tun_inet6(values: &HashMap<String, String>) -> String {
    values
        .get("MAGICNET_TUN_INET6")
        .filter(|value| ipv6_tun_cidr_valid(value))
        .cloned()
        .unwrap_or_else(|| DEFAULT_TUN_INET6.to_string())
}

pub(crate) fn effective_dns_capture_port(config: Option<&Value>) -> Option<u16> {
    config
        .and_then(|config| config.get("inbounds"))
        .and_then(Value::as_array)
        .and_then(|inbounds| {
            inbounds.iter().find(|inbound| {
                inbound.get("type").and_then(Value::as_str) == Some("direct")
                    && inbound.get("tag").and_then(Value::as_str) == Some("magicnet-dns-in")
            })
        })
        .and_then(|inbound| inbound.get("listen_port"))
        .and_then(Value::as_u64)
        .and_then(|port| u16::try_from(port).ok())
        .filter(|port| *port >= 1)
}

pub(crate) fn effective_tun_addresses(tun: Option<&Value>) -> (Option<String>, Option<String>) {
    let addresses = tun
        .and_then(|tun| tun.get("address"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str);
    let mut inet = None;
    let mut inet6 = None;
    for address in addresses {
        if inet.is_none() && ipv4_tun_cidr_valid(address) {
            inet = Some(address.to_string());
        } else if inet6.is_none() && ipv6_tun_cidr_valid(address) {
            inet6 = Some(address.to_string());
        }
    }
    (inet, inet6)
}

pub(crate) fn ipv4_tun_cidr_valid(value: &str) -> bool {
    let Some((address, prefix)) = value.split_once('/') else {
        return false;
    };
    let Some(prefix) = canonical_u16(prefix) else {
        return false;
    };
    let Ok(address) = address.parse::<std::net::Ipv4Addr>() else {
        return false;
    };
    if !(8..=30).contains(&prefix) || matches!(address.octets()[0], 0 | 127 | 224..=255) {
        return false;
    }
    // sing-tun uses the following address for DNS/TCP. It must stay in the
    // prefix and must not be the IPv4 broadcast address.
    let host_mask = u32::MAX >> prefix;
    (u32::from(address) & host_mask) < host_mask - 1
}

pub(crate) fn ipv6_tun_cidr_valid(value: &str) -> bool {
    let Some((address, prefix)) = value.split_once('/') else {
        return false;
    };
    let Some(prefix) = canonical_u16(prefix) else {
        return false;
    };
    // Match the shell contract: pure hexadecimal IPv6, no zone or dotted tail.
    if !address
        .bytes()
        .all(|byte| byte.is_ascii_hexdigit() || byte == b':')
    {
        return false;
    }
    let Ok(address) = address.parse::<std::net::Ipv6Addr>() else {
        return false;
    };
    // A textual fc/fd prefix is not enough: fc::1 actually starts with 00fc.
    if !(64..=126).contains(&prefix) || address.segments()[0] & 0xfe00 != 0xfc00 {
        return false;
    }
    // Reserve the next address for sing-tun DNS without crossing the prefix.
    let host_mask = u128::MAX >> prefix;
    (u128::from(address) & host_mask) < host_mask
}

fn normalize_udp_timeout(value: &str) -> Option<&'static str> {
    match value {
        "1m" => Some("1m"),
        "3m" => Some("3m"),
        "5m" => Some("5m"),
        "10m" => Some("10m"),
        "15m" => Some("15m"),
        "30m" => Some("30m"),
        _ => None,
    }
}

fn print_status(app: &App, policy: &NetworkPolicy) {
    let values = read_kv(app.moddir.join(NETWORK_POLICY_CONF));
    println!("ipv6_mode={}", policy.ipv6_mode);
    println!("mtu={}", policy.mtu);
    println!("udp_timeout={}", policy.udp_timeout);
    println!("dns_capture_port={}", configured_dns_capture_port(&values));
    println!("tun_inet={}", configured_tun_inet(&values));
    println!("tun_inet6={}", configured_tun_inet6(&values));

    let effective = fs::read_to_string(app.moddir.join(".config/sing-box/config.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let tun = effective
        .as_ref()
        .and_then(|config| config.get("inbounds"))
        .and_then(Value::as_array)
        .and_then(|inbounds| {
            inbounds
                .iter()
                .find(|inbound| inbound.get("type").and_then(Value::as_str) == Some("tun"))
        });
    let strategy = effective
        .as_ref()
        .and_then(|config| config.get("dns"))
        .and_then(|dns| dns.get("strategy"))
        .and_then(Value::as_str)
        .unwrap_or("unavailable");
    let (effective_inet, effective_inet6) = effective_tun_addresses(tun);
    println!("effective_ipv6_mode={strategy}");
    println!(
        "effective_stack={}",
        tun.and_then(|tun| tun.get("stack"))
            .and_then(Value::as_str)
            .unwrap_or("unavailable")
    );
    println!(
        "effective_mtu={}",
        tun.and_then(|tun| tun.get("mtu"))
            .and_then(Value::as_u64)
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unavailable".to_string())
    );
    println!(
        "effective_udp_timeout={}",
        tun.and_then(|tun| tun.get("udp_timeout"))
            .and_then(Value::as_str)
            .unwrap_or("unavailable")
    );
    println!(
        "effective_dns_capture_port={}",
        effective_dns_capture_port(effective.as_ref())
            .map(|port| port.to_string())
            .unwrap_or_else(|| "unavailable".to_string())
    );
    println!(
        "effective_tun_inet={}",
        effective_inet.as_deref().unwrap_or("unavailable")
    );
    println!(
        "effective_tun_inet6={}",
        effective_inet6.as_deref().unwrap_or("unavailable")
    );
}

fn network_usage() -> String {
    "Usage: cli network {status|set <ipv4_only|prefer_ipv4|prefer_ipv6> <mtu:1280-1500> <udp-timeout:1m|3m|5m|10m|15m|30m>|apply}".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::temp_app;
    use std::fs;

    #[test]
    fn aliases_normalize_to_canonical_ipv6_modes() {
        assert_eq!(normalize_ipv6_mode("compat"), Some("ipv4_only"));
        assert_eq!(normalize_ipv6_mode("dual"), Some("prefer_ipv4"));
        assert_eq!(normalize_ipv6_mode("prefer-ipv6"), Some("prefer_ipv6"));
        assert_eq!(normalize_ipv6_mode("ipv6_only"), None);
    }

    #[test]
    fn mtu_rejects_values_that_break_ipv6_or_exceed_common_links() {
        assert_eq!(normalize_mtu("1280"), Some(1280));
        assert_eq!(normalize_mtu("1400"), Some(1400));
        assert_eq!(normalize_mtu("1500"), Some(1500));
        assert_eq!(normalize_mtu("1279"), None);
        assert_eq!(normalize_mtu("1501"), None);
    }

    #[test]
    fn udp_timeout_uses_bounded_presets() {
        assert_eq!(normalize_udp_timeout("5m"), Some("5m"));
        assert_eq!(normalize_udp_timeout("30m"), Some("30m"));
        assert_eq!(normalize_udp_timeout("0m"), None);
        assert_eq!(normalize_udp_timeout("1h"), None);
    }

    #[test]
    fn dns_capture_port_rejects_zero_and_non_numeric() {
        assert_eq!(normalize_dns_capture_port("1053"), Some(1053));
        assert_eq!(normalize_dns_capture_port("15353"), Some(15353));
        assert_eq!(normalize_dns_capture_port("0"), None);
        assert_eq!(normalize_dns_capture_port("dns"), None);
    }

    #[test]
    fn dataplane_pins_report_configured_defaults_and_effective_inbounds() {
        let mut values = HashMap::new();
        assert_eq!(configured_dns_capture_port(&values), 1053);
        assert_eq!(configured_tun_inet(&values), "172.19.0.1/30");
        assert_eq!(configured_tun_inet6(&values), "fdfe:dcba:9876::1/126");
        values.insert("MAGICNET_DNS_CAPTURE_PORT".into(), "0".into());
        values.insert("MAGICNET_TUN_INET".into(), "127.0.0.1/30".into());
        values.insert("MAGICNET_TUN_INET6".into(), "fe80::1/64".into());
        assert_eq!(configured_dns_capture_port(&values), 1053);
        assert_eq!(configured_tun_inet(&values), "172.19.0.1/30");
        assert_eq!(configured_tun_inet6(&values), "fdfe:dcba:9876::1/126");
        values.insert("MAGICNET_DNS_CAPTURE_PORT".into(), "15353".into());
        values.insert("MAGICNET_TUN_INET".into(), "172.20.0.1/30".into());
        values.insert("MAGICNET_TUN_INET6".into(), "fd12::2/126".into());
        assert_eq!(configured_dns_capture_port(&values), 15353);
        assert_eq!(configured_tun_inet(&values), "172.20.0.1/30");
        assert_eq!(configured_tun_inet6(&values), "fd12::2/126");

        let config = serde_json::json!({
            "inbounds": [
                {
                    "type": "direct",
                    "tag": "magicnet-dns-in",
                    "listen": "127.0.0.1",
                    "listen_port": 15353
                },
                {
                    "type": "tun",
                    "address": ["172.20.0.1/30", "fd12::2/126"]
                }
            ]
        });
        assert_eq!(effective_dns_capture_port(Some(&config)), Some(15353));
        assert_eq!(
            effective_tun_addresses(config["inbounds"].as_array().and_then(|inbounds| {
                inbounds
                    .iter()
                    .find(|inbound| inbound.get("type").and_then(Value::as_str) == Some("tun"))
            })),
            (
                Some("172.20.0.1/30".to_string()),
                Some("fd12::2/126".to_string())
            )
        );
        assert_eq!(effective_dns_capture_port(None), None);
    }

    #[test]
    fn tun_inet_rejects_loopback_and_overwide_prefixes() {
        assert!(ipv4_tun_cidr_valid("172.19.0.1/30"));
        assert!(ipv4_tun_cidr_valid("172.20.0.1/30"));
        assert!(!ipv4_tun_cidr_valid("127.0.0.1/30"));
        assert!(!ipv4_tun_cidr_valid("172.19.0.1/31"));
        assert!(!ipv4_tun_cidr_valid("172.019.0.1/30"));
        assert!(ipv6_tun_cidr_valid("fdfe:dcba:9876::1/126"));
        assert!(!ipv6_tun_cidr_valid("fe80::1/64"));
        assert!(!ipv6_tun_cidr_valid("2001:db8::1/64"));
        assert!(!ipv6_tun_cidr_valid("fdfe:dcba:9876::1/127"));
    }

    #[test]
    fn dataplane_pins_reject_ambiguous_or_non_ula_values() {
        for value in ["+53", "00053", "65536", "18446744073709551616", "53\n53"] {
            assert_eq!(normalize_dns_capture_port(value), None, "{value:?}");
        }
        for value in [
            "172.20.0.1/+30",
            "172.20.0.1/030",
            "+172.20.0.1/30",
            "172.20.0.1/30\n172.20.0.1/30",
        ] {
            assert!(!ipv4_tun_cidr_valid(value), "{value:?}");
        }
        for value in [
            "fc::1/64",
            "fd::1/64",
            "fcd::1/64",
            "fd12::1/+64",
            "fd12::1/064",
            "fd12::1/64\nfd12::1/64",
        ] {
            assert!(!ipv6_tun_cidr_valid(value), "{value:?}");
        }
        for value in ["fc00::1/64", "FDFF::1/126", "fd12:3456:789a:1:2:3:4:5/64"] {
            assert!(ipv6_tun_cidr_valid(value), "{value:?}");
        }
    }

    #[test]
    fn tun_addresses_reserve_a_reachable_next_address_for_dns() {
        for value in [
            "172.20.0.2/30",
            "172.20.0.3/30",
            "172.20.1.254/23",
            "172.20.1.255/23",
            "172.20.0.126/25",
            "172.20.0.127/25",
            "10.255.255.254/8",
            "10.255.255.255/8",
        ] {
            assert!(!ipv4_tun_cidr_valid(value), "{value:?}");
        }
        for value in ["172.20.0.1/30", "172.20.1.253/23", "172.20.0.125/25"] {
            assert!(ipv4_tun_cidr_valid(value), "{value:?}");
        }
        for value in [
            "fd12::3/126",
            "fd12::7/125",
            "fd12::ffff/112",
            "fd12:1:2:3:4:ffff:ffff:ffff/80",
            "fd12:1:2:3:7fff:ffff:ffff:ffff/65",
            "fd12:1:2:3:ffff:ffff:ffff:ffff/64",
        ] {
            assert!(!ipv6_tun_cidr_valid(value), "{value:?}");
        }
        for value in [
            "fd12::2/126",
            "fd12::6/125",
            "fd12::fffe/112",
            "fd12:1:2:3:4:ffff:ffff:fffe/80",
            "fd12:1:2:3:7fff:ffff:ffff:fffe/65",
            "fd12:1:2:3:ffff:ffff:ffff:fffe/64",
        ] {
            assert!(ipv6_tun_cidr_valid(value), "{value:?}");
        }
    }

    #[test]
    fn write_preserves_validated_dataplane_pins() {
        let app = temp_app();
        let path = app.moddir.join(NETWORK_POLICY_CONF);
        fs::create_dir_all(path.parent().expect("network policy parent")).unwrap();
        fs::write(
            &path,
            concat!(
                "MAGICNET_IPV6_MODE=prefer_ipv4\n",
                "MAGICNET_TUN_MTU=1400\n",
                "MAGICNET_UDP_TIMEOUT=5m\n",
                "MAGICNET_DNS_CAPTURE_PORT=15353\n",
                "MAGICNET_TUN_INET=172.20.0.1/30\n",
                "MAGICNET_TUN_INET6=fdfe:dcba:9876::1/126\n"
            ),
        )
        .unwrap();
        NetworkPolicy {
            ipv6_mode: "ipv4_only",
            mtu: 1280,
            udp_timeout: "10m",
        }
        .write(&app)
        .unwrap();
        let text = fs::read_to_string(path).unwrap();
        assert!(text.contains("MAGICNET_IPV6_MODE=ipv4_only"));
        assert!(text.contains("MAGICNET_TUN_MTU=1280"));
        assert!(text.contains("MAGICNET_UDP_TIMEOUT=10m"));
        assert!(text.contains("MAGICNET_DNS_CAPTURE_PORT=15353"));
        assert!(text.contains("MAGICNET_TUN_INET=172.20.0.1/30"));
        assert!(text.contains("MAGICNET_TUN_INET6=fdfe:dcba:9876::1/126"));
    }
}
