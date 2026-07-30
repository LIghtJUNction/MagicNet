use std::fs;
use std::path::Path;

use serde_json::Value;

use crate::{read_kv, run_magicnet_function, write_kv, App};

const NETWORK_POLICY_CONF: &str = ".config/magicnet/network-policy.conf";
const DEFAULT_IPV6_MODE: &str = "prefer_ipv4";
const DEFAULT_MTU: u16 = 1400;
const DEFAULT_UDP_TIMEOUT: &str = "5m";

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
            run_magicnet_function(app, "magicnet_transparent_apply")?;
            print_status(app, &policy);
            println!("[info] Network policy applied");
            Ok(())
        }
        "apply" => {
            run_magicnet_function(app, "magicnet_transparent_apply")?;
            print_status(app, &NetworkPolicy::load(app));
            Ok(())
        }
        _ => Err(network_usage()),
    }
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
        write_kv(
            app,
            Path::new(NETWORK_POLICY_CONF),
            &[
                ("MAGICNET_IPV6_MODE", self.ipv6_mode.to_string()),
                ("MAGICNET_TUN_MTU", self.mtu.to_string()),
                ("MAGICNET_UDP_TIMEOUT", self.udp_timeout.to_string()),
            ],
        )
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
    println!("ipv6_mode={}", policy.ipv6_mode);
    println!("mtu={}", policy.mtu);
    println!("udp_timeout={}", policy.udp_timeout);

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
}

fn network_usage() -> String {
    "Usage: cli network {status|set <ipv4_only|prefer_ipv4|prefer_ipv6> <mtu:1280-1500> <udp-timeout:1m|3m|5m|10m|15m|30m>|apply}".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
