use std::collections::HashSet;
use std::fs;
use std::net::IpAddr;

use serde_json::{Map, Value};

use crate::App;

const CANONICAL_CN_RULE_SETS: [&str; 7] = [
    "lyc-geosite-cn",
    "lyc-geosite-geolocation-cn",
    "lyc-geoip-cn",
    "metacubex-geoip-cn",
    "ddch-direct",
    "karing-acl4ssr-china-domain",
    "karing-acl4ssr-china-ip",
];
const PROXY_POLICY_OUTBOUND_TAGS: [&str; 7] = [
    "ai-proxy",
    "dev-proxy",
    "media-proxy",
    "game-proxy",
    "social-proxy",
    "telegram-proxy",
    "proxy-rule",
];
const MAX_MATCHER_DEPTH: usize = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum JsonStatus {
    Ok,
    Missing,
    Invalid,
}

impl JsonStatus {
    fn label(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Missing => "missing",
            Self::Invalid => "invalid",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Resolution {
    Proxy,
    Direct,
    Block,
    Missing,
    Invalid,
    Cycle,
    NonProxy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuleCondition {
    Unconditional,
    Conditioned,
    Invalid,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CnPriority {
    Ok,
    Reordered,
    Invalid,
}

impl CnPriority {
    fn label(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Reordered => "reordered",
            Self::Invalid => "invalid",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MatcherFieldState {
    Missing,
    Effective,
    Ineffective,
    Invalid,
}

impl Resolution {
    fn label(self) -> &'static str {
        match self {
            Self::Proxy => "proxy",
            Self::Direct => "direct",
            Self::Block => "block",
            Self::Missing => "missing",
            Self::Invalid => "invalid",
            Self::Cycle => "cycle",
            Self::NonProxy => "non_proxy",
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
struct RoutingPolicyStatus {
    valid_json: JsonStatus,
    final_resolution: Resolution,
    cn_direct_resolution: Resolution,
    cn_rule_sets: usize,
    cn_priority: CnPriority,
    catchall_direct: usize,
    invalid_rules: usize,
}

impl RoutingPolicyStatus {
    fn unavailable(valid_json: JsonStatus) -> Self {
        Self {
            valid_json,
            final_resolution: Resolution::Invalid,
            cn_direct_resolution: Resolution::Invalid,
            cn_rule_sets: 0,
            cn_priority: CnPriority::Invalid,
            catchall_direct: 0,
            invalid_rules: 0,
        }
    }

    fn ok(&self) -> bool {
        self.valid_json == JsonStatus::Ok
            && self.final_resolution == Resolution::Proxy
            && self.cn_direct_resolution == Resolution::Direct
            && self.cn_rule_sets == CANONICAL_CN_RULE_SETS.len()
            && self.cn_priority == CnPriority::Ok
            && self.catchall_direct == 0
            && self.invalid_rules == 0
    }

    fn detail(&self) -> String {
        format!(
            "valid_json={} final={} cn_direct={} cn_rule_sets={} cn_priority={} catchall_direct={} invalid_rules={}",
            self.valid_json.label(),
            self.final_resolution.label(),
            self.cn_direct_resolution.label(),
            self.cn_rule_sets,
            self.cn_priority.label(),
            self.catchall_direct,
            self.invalid_rules
        )
    }
}

pub(crate) fn routing_policy_check(app: &App) -> (bool, String) {
    let path = app.moddir.join(".config/sing-box/config.json");
    let status = match fs::read_to_string(path) {
        Ok(text) => analyze_text(&text),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            RoutingPolicyStatus::unavailable(JsonStatus::Missing)
        }
        Err(_) => RoutingPolicyStatus::unavailable(JsonStatus::Invalid),
    };
    (status.ok(), status.detail())
}

fn analyze_text(text: &str) -> RoutingPolicyStatus {
    let Ok(config) = serde_json::from_str::<Value>(text) else {
        return RoutingPolicyStatus::unavailable(JsonStatus::Invalid);
    };
    analyze_config(&config)
}

fn analyze_config(config: &Value) -> RoutingPolicyStatus {
    let outbounds = config
        .get("outbounds")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let resolver = OutboundResolver { outbounds };
    let route = config.get("route").and_then(Value::as_object);
    let final_resolution = route
        .and_then(|route| route.get("final"))
        .and_then(nonempty_string)
        .map_or(Resolution::Missing, |tag| resolver.resolve(tag));
    let cn_direct_resolution = resolver.resolve("cn-direct");
    let mut cn_rule_sets = HashSet::new();
    let mut cn_priority = CnPriority::Ok;
    let mut catchall_direct = 0;
    let mut invalid_rules = 0;
    let rules = match route.and_then(|route| route.get("rules")) {
        Some(Value::Array(rules)) => rules.as_slice(),
        Some(_) => {
            invalid_rules = 1;
            &[]
        }
        None => &[],
    };
    for rule in rules {
        let Some(rule) = rule.as_object() else {
            invalid_rules += 1;
            continue;
        };
        let condition = classify_rule_condition(rule);
        if condition == RuleCondition::Invalid {
            invalid_rules += 1;
            continue;
        }
        let outbound = rule.get("outbound").and_then(nonempty_string);
        let rule_set_tags = strict_listable_strings(rule.get("rule_set"));
        if outbound == Some("cn-direct") {
            if let Some(tags) = &rule_set_tags {
                for tag in tags {
                    if CANONICAL_CN_RULE_SETS.contains(tag) {
                        cn_rule_sets.insert(*tag);
                    }
                }
            }
        }
        if rule_set_tags.is_some()
            && outbound.is_some_and(|tag| PROXY_POLICY_OUTBOUND_TAGS.contains(&tag))
            && cn_rule_sets.len() < CANONICAL_CN_RULE_SETS.len()
        {
            cn_priority = CnPriority::Reordered;
        }
        if condition == RuleCondition::Unconditional && catchall_target_is_direct(rule, &resolver) {
            catchall_direct += 1;
        }
    }

    RoutingPolicyStatus {
        valid_json: JsonStatus::Ok,
        final_resolution,
        cn_direct_resolution,
        cn_rule_sets: cn_rule_sets.len(),
        cn_priority,
        catchall_direct,
        invalid_rules,
    }
}

struct OutboundResolver<'a> {
    outbounds: &'a [Value],
}

impl<'a> OutboundResolver<'a> {
    fn resolve(&self, tag: &'a str) -> Resolution {
        self.resolve_inner(tag, &mut HashSet::new())
    }

    fn resolve_inner(&self, tag: &'a str, visiting: &mut HashSet<&'a str>) -> Resolution {
        if tag.is_empty() {
            return Resolution::Invalid;
        }
        if !visiting.insert(tag) {
            return Resolution::Cycle;
        }
        let resolution = match self.find(tag) {
            Ok(outbound) => self.resolve_outbound(outbound, visiting),
            Err(resolution) => resolution,
        };
        visiting.remove(tag);
        resolution
    }

    fn find(&self, tag: &str) -> Result<&'a Value, Resolution> {
        let mut matches = self
            .outbounds
            .iter()
            .filter(|outbound| outbound.get("tag").and_then(Value::as_str) == Some(tag));
        let Some(outbound) = matches.next() else {
            return Err(Resolution::Missing);
        };
        if matches.next().is_some() {
            return Err(Resolution::Invalid);
        }
        Ok(outbound)
    }

    fn resolve_outbound(&self, outbound: &'a Value, visiting: &mut HashSet<&'a str>) -> Resolution {
        match outbound.get("type").and_then(nonempty_string) {
            Some("direct") => Resolution::Direct,
            Some("block") => Resolution::Block,
            Some("selector") => self.resolve_selector(outbound, visiting),
            Some("urltest") => self.resolve_urltest(outbound, visiting),
            Some(kind) if is_proxy_endpoint(kind, outbound) => Resolution::Proxy,
            _ => Resolution::Invalid,
        }
    }

    fn resolve_selector(&self, outbound: &'a Value, visiting: &mut HashSet<&'a str>) -> Resolution {
        let Some(members) = outbound_members(outbound.get("outbounds")) else {
            return Resolution::Invalid;
        };
        let default = match outbound.get("default") {
            None => members[0],
            Some(Value::String(value)) if value.is_empty() => members[0],
            Some(value) => {
                let Some(default) = nonempty_string(value) else {
                    return Resolution::Invalid;
                };
                default
            }
        };
        if !members.contains(&default) {
            return Resolution::Invalid;
        }
        self.resolve_inner(default, visiting)
    }

    fn resolve_urltest(&self, outbound: &'a Value, visiting: &mut HashSet<&'a str>) -> Resolution {
        let Some(members) = outbound_members(outbound.get("outbounds")) else {
            return Resolution::Invalid;
        };
        let resolutions = members
            .iter()
            .map(|member| self.resolve_inner(member, visiting));
        combine_urltest_resolutions(resolutions)
    }
}

fn combine_urltest_resolutions(resolutions: impl Iterator<Item = Resolution>) -> Resolution {
    let values: Vec<_> = resolutions.collect();
    if values.is_empty() {
        return Resolution::Invalid;
    }
    for failure in [Resolution::Cycle, Resolution::Missing, Resolution::Invalid] {
        if values.contains(&failure) {
            return failure;
        }
    }
    if values
        .iter()
        .all(|resolution| *resolution == Resolution::Proxy)
    {
        Resolution::Proxy
    } else {
        Resolution::NonProxy
    }
}

fn outbound_members(value: Option<&Value>) -> Option<Vec<&str>> {
    let members = value?.as_array()?;
    if members.is_empty() {
        return None;
    }
    let members = members
        .iter()
        .map(nonempty_string)
        .collect::<Option<Vec<_>>>()?;
    let mut unique = HashSet::new();
    if members.iter().all(|member| unique.insert(*member)) {
        Some(members)
    } else {
        None
    }
}

fn nonempty_string(value: &Value) -> Option<&str> {
    value.as_str().filter(|value| !value.is_empty())
}

fn strict_listable_strings(value: Option<&Value>) -> Option<Vec<&str>> {
    match value? {
        Value::String(value) if !value.is_empty() => Some(vec![value]),
        Value::Array(values) if !values.is_empty() => {
            values.iter().map(nonempty_string).collect::<Option<_>>()
        }
        _ => None,
    }
}

fn is_proxy_endpoint(kind: &str, outbound: &Value) -> bool {
    match kind {
        "tor" => true,
        "ssh" => {
            outbound.get("server").and_then(nonempty_string).is_some()
                && valid_optional_port(outbound.get("server_port"))
        }
        "hysteria" | "hysteria2" => has_server_and_port_or_ports(outbound),
        "socks" | "http" | "shadowsocks" | "vmess" | "vless" | "trojan" | "tuic" | "shadowtls"
        | "anytls" | "naive" => has_server_and_port(outbound),
        _ => false,
    }
}

fn has_server_and_port(outbound: &Value) -> bool {
    outbound.get("server").and_then(nonempty_string).is_some()
        && outbound.get("server_port").is_some_and(valid_port)
}

fn has_server_and_port_or_ports(outbound: &Value) -> bool {
    outbound.get("server").and_then(nonempty_string).is_some()
        && (outbound.get("server_port").is_some_and(valid_port)
            || valid_server_ports(outbound.get("server_ports")))
}

fn valid_server_ports(value: Option<&Value>) -> bool {
    match value {
        Some(Value::String(value)) => valid_server_port_item(value),
        Some(Value::Array(values)) if !values.is_empty() => values
            .iter()
            .all(|value| value.as_str().is_some_and(valid_server_port_item)),
        _ => false,
    }
}

fn valid_server_port_item(value: &str) -> bool {
    if let Some((start, end)) = value.split_once(':') {
        if end.contains(':') {
            return false;
        }
        let (Ok(start), Ok(end)) = (start.parse::<u16>(), end.parse::<u16>()) else {
            return false;
        };
        start > 0 && start <= end
    } else {
        value.parse::<u16>().is_ok_and(|port| port > 0)
    }
}

fn valid_optional_port(value: Option<&Value>) -> bool {
    value.is_none_or(valid_port)
}

fn valid_port(value: &Value) -> bool {
    value
        .as_u64()
        .is_some_and(|port| (1..=u16::MAX as u64).contains(&port))
}

fn catchall_target_is_direct(rule: &Map<String, Value>, resolver: &OutboundResolver<'_>) -> bool {
    match rule.get("action").and_then(Value::as_str) {
        Some("direct" | "bypass") => true,
        None | Some("route") => rule
            .get("outbound")
            .and_then(nonempty_string)
            .is_some_and(|tag| resolver.resolve(tag) == Resolution::Direct),
        _ => false,
    }
}

fn classify_rule_condition(rule: &Map<String, Value>) -> RuleCondition {
    classify_rule_condition_inner(rule, 0)
}

fn classify_rule_condition_inner(rule: &Map<String, Value>, depth: usize) -> RuleCondition {
    if depth >= MAX_MATCHER_DEPTH {
        return RuleCondition::Invalid;
    }

    match rule.get("type") {
        None => classify_default_rule(rule),
        Some(Value::String(kind)) if kind.is_empty() || kind == "default" => {
            classify_default_rule(rule)
        }
        Some(Value::String(kind)) if kind == "logical" => classify_logical_rule(rule, depth),
        Some(_) => RuleCondition::Invalid,
    }
}

fn classify_default_rule(rule: &Map<String, Value>) -> RuleCondition {
    let mut effective = false;
    for (field, value) in rule {
        match classify_matcher_field(field, value) {
            MatcherFieldState::Invalid => return RuleCondition::Invalid,
            MatcherFieldState::Effective => effective = true,
            MatcherFieldState::Missing | MatcherFieldState::Ineffective => {}
        }
    }
    if effective {
        RuleCondition::Conditioned
    } else {
        RuleCondition::Unconditional
    }
}

fn classify_logical_rule(rule: &Map<String, Value>, depth: usize) -> RuleCondition {
    if !matches!(rule.get("mode").and_then(Value::as_str), Some("and" | "or")) {
        return RuleCondition::Invalid;
    }
    let Some(rules) = rule.get("rules").and_then(Value::as_array) else {
        return RuleCondition::Invalid;
    };
    if rules.is_empty() {
        return RuleCondition::Invalid;
    }
    if rules.iter().all(|nested| {
        nested.as_object().is_some_and(|nested| {
            classify_rule_condition_inner(nested, depth + 1) == RuleCondition::Conditioned
        })
    }) {
        RuleCondition::Conditioned
    } else {
        RuleCondition::Invalid
    }
}

fn classify_matcher_field(field: &str, value: &Value) -> MatcherFieldState {
    match field {
        "inbound" | "network" | "auth_user" | "protocol" | "client" | "domain"
        | "domain_suffix" | "domain_keyword" | "domain_regex" | "geosite" | "source_geoip"
        | "geoip" | "process_name" | "process_path" | "process_path_regex" | "package_name"
        | "user" | "wifi_ssid" | "wifi_bssid" | "preferred_by" | "rule_set" => {
            classify_string_listable(value)
        }
        "source_ip_cidr" | "ip_cidr" => classify_listable(value, valid_ip_or_prefix),
        "network_type" => classify_listable(value, valid_network_type),
        "clash_mode" => classify_scalar_string(value),
        "interface_address" => classify_address_map(value, valid_interface_name),
        "network_interface_address" => classify_address_map(value, valid_network_interface_type),
        "default_interface_address" => classify_listable(value, valid_ip_or_prefix),
        "source_ip_is_private"
        | "ip_is_private"
        | "network_is_expensive"
        | "network_is_constrained" => match value.as_bool() {
            Some(true) => MatcherFieldState::Effective,
            Some(false) => MatcherFieldState::Ineffective,
            None => MatcherFieldState::Invalid,
        },
        "ip_version" => classify_scalar(value, valid_ip_version),
        "source_port" | "port" => classify_listable(value, valid_matcher_port),
        "source_port_range" | "port_range" => classify_listable(value, valid_port_range_value),
        "user_id" => classify_listable(value, valid_user_id),
        _ => MatcherFieldState::Missing,
    }
}

fn classify_scalar(value: &Value, predicate: fn(&Value) -> bool) -> MatcherFieldState {
    if predicate(value) {
        MatcherFieldState::Effective
    } else {
        MatcherFieldState::Invalid
    }
}

fn classify_listable(value: &Value, predicate: fn(&Value) -> bool) -> MatcherFieldState {
    match value {
        Value::Array(values) if values.is_empty() => MatcherFieldState::Ineffective,
        Value::Array(values) if values.iter().all(predicate) => MatcherFieldState::Effective,
        Value::Array(_) => MatcherFieldState::Invalid,
        value if predicate(value) => MatcherFieldState::Effective,
        _ => MatcherFieldState::Invalid,
    }
}

fn classify_string_listable(value: &Value) -> MatcherFieldState {
    match value {
        Value::String(value) if value.is_empty() => MatcherFieldState::Ineffective,
        Value::Array(values) if values.is_empty() => MatcherFieldState::Ineffective,
        _ => classify_listable(value, valid_nonempty_string),
    }
}

fn classify_scalar_string(value: &Value) -> MatcherFieldState {
    match value {
        Value::String(value) if value.is_empty() => MatcherFieldState::Ineffective,
        Value::String(_) => MatcherFieldState::Effective,
        _ => MatcherFieldState::Invalid,
    }
}

fn classify_address_map(value: &Value, valid_key: fn(&str) -> bool) -> MatcherFieldState {
    let Some(entries) = value.as_object() else {
        return MatcherFieldState::Invalid;
    };
    let mut effective = false;
    for (key, addresses) in entries {
        if !valid_key(key) {
            return MatcherFieldState::Invalid;
        }
        match classify_listable(addresses, valid_ip_or_prefix) {
            MatcherFieldState::Effective => effective = true,
            MatcherFieldState::Ineffective => {}
            MatcherFieldState::Missing | MatcherFieldState::Invalid => {
                return MatcherFieldState::Invalid;
            }
        }
    }
    if effective {
        MatcherFieldState::Effective
    } else {
        MatcherFieldState::Ineffective
    }
}

fn valid_nonempty_string(value: &Value) -> bool {
    nonempty_string(value).is_some()
}

fn valid_interface_name(_value: &str) -> bool {
    true
}

fn valid_network_interface_type(value: &str) -> bool {
    matches!(value, "wifi" | "cellular" | "ethernet" | "other")
}

fn valid_network_type(value: &Value) -> bool {
    value.as_str().is_some_and(valid_network_interface_type)
}

fn valid_ip_or_prefix(value: &Value) -> bool {
    let Some(value) = value.as_str() else {
        return false;
    };
    let Some((address, prefix)) = value.split_once('/') else {
        return value.parse::<IpAddr>().is_ok();
    };
    if prefix.contains('/') {
        return false;
    }
    let (Ok(address), Ok(prefix)) = (address.parse::<IpAddr>(), prefix.parse::<u8>()) else {
        return false;
    };
    match address {
        IpAddr::V4(_) => prefix <= 32,
        IpAddr::V6(_) => prefix <= 128,
    }
}

fn valid_ip_version(value: &Value) -> bool {
    matches!(value.as_u64(), Some(4 | 6))
}

fn valid_matcher_port(value: &Value) -> bool {
    value.as_u64().is_some_and(|port| port <= u16::MAX as u64)
}

fn valid_port_range_value(value: &Value) -> bool {
    let Some(value) = value.as_str() else {
        return false;
    };
    let Some((start, end)) = value.split_once(':') else {
        return false;
    };
    match (start.parse::<u16>(), end.parse::<u16>()) {
        (Ok(start), Ok(end)) => start > 0 && start <= end,
        (Err(_), Ok(end)) if start.is_empty() => end > 0,
        (Ok(start), Err(_)) if end.is_empty() => start > 0,
        _ => false,
    }
}

fn valid_user_id(value: &Value) -> bool {
    value
        .as_i64()
        .is_some_and(|value| (i32::MIN as i64..=i32::MAX as i64).contains(&value))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use serde_json::{json, Value};

    use super::{
        analyze_config, analyze_text, routing_policy_check, CnPriority, JsonStatus, Resolution,
        RoutingPolicyStatus, CANONICAL_CN_RULE_SETS,
    };
    use crate::App;

    fn endpoint(kind: &str, tag: &str) -> Value {
        let mut endpoint = json!({
            "type": kind,
            "tag": tag,
            "server": "192.0.2.1",
            "server_port": 443
        });
        match kind {
            "shadowsocks" => {
                endpoint["method"] = json!("aes-128-gcm");
                endpoint["password"] = json!("test-password");
            }
            "vmess" => {
                endpoint["uuid"] = json!("00000000-0000-0000-0000-000000000001");
                endpoint["security"] = json!("auto");
            }
            "vless" => {
                endpoint["uuid"] = json!("00000000-0000-0000-0000-000000000001");
            }
            "trojan" => {
                endpoint["password"] = json!("test-password");
            }
            "hysteria" => {
                endpoint["up_mbps"] = json!(10);
                endpoint["down_mbps"] = json!(10);
                endpoint["tls"] = json!({"enabled": true, "insecure": true});
            }
            "hysteria2" | "anytls" => {
                endpoint["password"] = json!("test-password");
                endpoint["tls"] = json!({"enabled": true, "insecure": true});
            }
            "tuic" => {
                endpoint["uuid"] = json!("00000000-0000-0000-0000-000000000001");
                endpoint["password"] = json!("test-password");
                endpoint["tls"] = json!({"enabled": true, "insecure": true});
            }
            "shadowtls" => {
                endpoint["version"] = json!(3);
                endpoint["password"] = json!("test-password");
                endpoint["tls"] = json!({"enabled": true, "insecure": true});
            }
            "naive" => {
                endpoint["username"] = json!("test-user");
                endpoint["password"] = json!("test-password");
                endpoint["tls"] = json!({"enabled": true, "server_name": "example.com"});
            }
            "tor" => {
                endpoint
                    .as_object_mut()
                    .expect("fixture endpoint must be an object")
                    .remove("server");
                endpoint
                    .as_object_mut()
                    .expect("fixture endpoint must be an object")
                    .remove("server_port");
            }
            "ssh" => {
                endpoint
                    .as_object_mut()
                    .expect("fixture endpoint must be an object")
                    .remove("server_port");
            }
            _ => {}
        }
        endpoint
    }

    fn runtime_config() -> Value {
        json!({
            "outbounds": [
                {"type": "selector", "tag": "final", "outbounds": ["proxy", "direct"], "default": "proxy"},
                {"type": "selector", "tag": "proxy", "outbounds": ["proxy-auto", "node-a"], "default": "proxy-auto"},
                {"type": "urltest", "tag": "proxy-auto", "outbounds": ["node-a", "node-b"]},
                endpoint("socks", "node-a"),
                endpoint("socks", "node-b"),
                {"type": "selector", "tag": "cn-direct", "outbounds": ["direct", "proxy"], "default": "direct"},
                {"type": "direct", "tag": "direct"},
                {"type": "block", "tag": "block"}
            ],
            "route": {
                "final": "final",
                "rules": [
                    {
                        "rule_set": [
                            "lyc-geosite-cn",
                            "lyc-geosite-geolocation-cn",
                            "lyc-geoip-cn",
                            "metacubex-geoip-cn",
                            "ddch-direct",
                            "karing-acl4ssr-china-domain",
                            "karing-acl4ssr-china-ip"
                        ],
                        "outbound": "cn-direct"
                    }
                ]
            }
        })
    }

    fn status(config: Value) -> RoutingPolicyStatus {
        analyze_config(&config)
    }

    fn status_with_rule(rule: Value) -> RoutingPolicyStatus {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .push(rule);
        status(config)
    }

    #[test]
    fn nested_selector_and_urltest_proxy_chain_passes() {
        assert!(status(runtime_config()).ok());
    }

    #[test]
    fn all_seven_canonical_cn_rule_sets_are_required_for_health() {
        let status = status(runtime_config());

        assert_eq!(
            (status.ok(), status.detail()),
            (
                true,
                "valid_json=ok final=proxy cn_direct=direct cn_rule_sets=7 cn_priority=ok catchall_direct=0 invalid_rules=0".to_string()
            )
        );
    }

    #[test]
    fn removed_metacubex_geosite_cn_is_not_required_for_health() {
        assert!(!CANONICAL_CN_RULE_SETS.contains(&"metacubex-geosite-cn"));
        assert!(status(runtime_config()).ok());
    }

    #[test]
    fn metacubex_geoip_cn_remains_required_for_health() {
        let mut config = runtime_config();
        config["route"]["rules"][0]["rule_set"]
            .as_array_mut()
            .expect("fixture rule sets must be an array")
            .retain(|tag| tag != "metacubex-geoip-cn");

        let status = status(config);
        assert_eq!((status.cn_rule_sets, status.ok()), (6, false));
    }

    #[test]
    fn proxy_policy_rule_before_cn_rules_is_reordered() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .insert(
                0,
                json!({"rule_set": "custom-proxy-rules", "outbound": "ai-proxy"}),
            );

        let status = status(config);
        assert_eq!(
            (status.cn_priority, status.ok()),
            (CnPriority::Reordered, false)
        );
    }

    #[test]
    fn proxy_policy_rule_between_split_cn_groups_is_reordered() {
        let mut config = runtime_config();
        config["route"]["rules"] = json!([
            {
                "rule_set": [
                    "lyc-geosite-cn",
                    "lyc-geosite-geolocation-cn",
                    "lyc-geoip-cn"
                ],
                "outbound": "cn-direct"
            },
            {"rule_set": ["custom-proxy-rules"], "outbound": "dev-proxy"},
            {
                "rule_set": [
                    "metacubex-geoip-cn",
                    "ddch-direct",
                    "karing-acl4ssr-china-domain",
                    "karing-acl4ssr-china-ip"
                ],
                "outbound": "cn-direct"
            }
        ]);

        let status = status(config);
        assert_eq!(
            (status.cn_rule_sets, status.cn_priority, status.ok()),
            (7, CnPriority::Reordered, false)
        );
    }

    #[test]
    fn proxy_policy_rule_after_all_cn_rules_preserves_priority() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .push(json!({
                "rule_set": "custom-proxy-rules",
                "outbound": "media-proxy"
            }));

        let status = status(config);
        assert_eq!((status.cn_priority, status.ok()), (CnPriority::Ok, true));
    }

    #[test]
    fn scalar_and_array_proxy_rule_sets_both_enforce_cn_priority() {
        for rule_set in [json!("custom-proxy-rules"), json!(["custom-proxy-rules"])] {
            let mut config = runtime_config();
            config["route"]["rules"]
                .as_array_mut()
                .expect("fixture rules must be an array")
                .insert(0, json!({"rule_set": rule_set, "outbound": "proxy-rule"}));

            assert_eq!(status(config).cn_priority, CnPriority::Reordered);
        }
    }

    #[test]
    fn invalid_proxy_policy_rule_does_not_report_reordered_priority() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .insert(
                0,
                json!({
                    "type": "future-rule",
                    "rule_set": "custom-proxy-rules",
                    "outbound": "game-proxy"
                }),
            );

        let status = status(config);
        assert_eq!(
            (status.cn_priority, status.invalid_rules, status.ok()),
            (CnPriority::Ok, 1, false)
        );
    }

    #[test]
    fn six_of_seven_canonical_cn_rule_sets_report_actual_count_and_fail() {
        let mut config = runtime_config();
        config["route"]["rules"] = json!([{
            "rule_set": [
                "lyc-geosite-cn",
                "lyc-geosite-geolocation-cn",
                "lyc-geoip-cn",
                "metacubex-geoip-cn",
                "ddch-direct",
                "karing-acl4ssr-china-domain"
            ],
            "outbound": "cn-direct"
        }]);

        let status = status(config);
        assert_eq!(
            (status.ok(), status.detail()),
            (
                false,
                "valid_json=ok final=proxy cn_direct=direct cn_rule_sets=6 cn_priority=ok catchall_direct=0 invalid_rules=0".to_string()
            )
        );
    }

    #[test]
    fn two_of_seven_canonical_cn_rule_sets_report_actual_count_and_fail() {
        let mut config = runtime_config();
        config["route"]["rules"] = json!([{
            "rule_set": ["lyc-geosite-cn", "lyc-geoip-cn"],
            "outbound": "cn-direct"
        }]);

        let status = status(config);
        assert_eq!(
            (status.ok(), status.detail()),
            (
                false,
                "valid_json=ok final=proxy cn_direct=direct cn_rule_sets=2 cn_priority=ok catchall_direct=0 invalid_rules=0".to_string()
            )
        );
    }

    #[test]
    fn scalar_and_array_cn_rule_sets_are_counted() {
        let mut config = runtime_config();
        config["route"]["rules"] = json!([
            {"rule_set": "lyc-geosite-cn", "outbound": "cn-direct"},
            {"rule_set": ["lyc-geoip-cn", "unrelated"], "outbound": "cn-direct"}
        ]);

        assert_eq!(status(config).cn_rule_sets, 2);
    }

    #[test]
    fn mixed_rule_set_array_does_not_count_canonical_entries() {
        let mut config = runtime_config();
        config["route"]["rules"] = json!([
            {"rule_set": ["lyc-geosite-cn", null], "outbound": "cn-direct"}
        ]);

        assert_eq!(status(config).cn_rule_sets, 0);
    }

    #[test]
    fn final_direct_chain_fails() {
        let mut config = runtime_config();
        config["route"]["final"] = json!("direct");

        let status = status(config);
        assert_eq!(status.final_resolution, Resolution::Direct);
        assert!(!status.ok());
    }

    #[test]
    fn cn_direct_proxy_chain_fails() {
        let mut config = runtime_config();
        config["outbounds"][5]["default"] = json!("proxy");

        let status = status(config);
        assert_eq!(status.cn_direct_resolution, Resolution::Proxy);
        assert!(!status.ok());
    }

    #[test]
    fn selector_missing_default_uses_first_member() {
        let mut config = runtime_config();
        config["outbounds"][0]
            .as_object_mut()
            .expect("fixture outbound must be an object")
            .remove("default");

        assert_eq!(status(config).final_resolution, Resolution::Proxy);
    }

    #[test]
    fn selector_empty_default_uses_first_member() {
        let mut config = runtime_config();
        config["outbounds"][0]["default"] = json!("");

        assert_eq!(status(config).final_resolution, Resolution::Proxy);
    }

    #[test]
    fn selector_default_outside_members_fails() {
        let mut config = runtime_config();
        config["outbounds"][0]["default"] = json!("node-a");

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn scalar_selector_members_fail_for_pinned_schema() {
        let mut config = runtime_config();
        config["outbounds"][0]["outbounds"] = json!("proxy");

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn scalar_urltest_members_fail_for_pinned_schema() {
        let mut config = runtime_config();
        config["outbounds"][2]["outbounds"] = json!("node-a");

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn duplicate_urltest_members_fail() {
        let mut config = runtime_config();
        config["outbounds"][2]["outbounds"] = json!(["node-a", "node-a"]);

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn empty_and_non_string_urltest_members_fail() {
        for members in [json!(null), json!(""), json!([]), json!(["node-a", 7])] {
            let mut config = runtime_config();
            config["outbounds"][2]["outbounds"] = members;

            assert_eq!(status(config).final_resolution, Resolution::Invalid);
        }
    }

    #[test]
    fn urltest_missing_member_fails() {
        let mut config = runtime_config();
        config["outbounds"][2]["outbounds"] = json!(["node-a", "missing-node"]);

        assert_eq!(status(config).final_resolution, Resolution::Missing);
    }

    #[test]
    fn selector_cycle_fails() {
        let mut config = runtime_config();
        config["outbounds"][1]["default"] = json!("final");
        config["outbounds"][1]["outbounds"] = json!(["final"]);

        assert_eq!(status(config).final_resolution, Resolution::Cycle);
    }

    #[test]
    fn urltest_with_only_direct_members_fails() {
        let mut config = runtime_config();
        config["outbounds"][2]["outbounds"] = json!(["direct"]);

        assert_eq!(status(config).final_resolution, Resolution::NonProxy);
    }

    #[test]
    fn urltest_with_only_block_members_fails() {
        let mut config = runtime_config();
        config["outbounds"][2]["outbounds"] = json!(["block"]);

        assert_eq!(status(config).final_resolution, Resolution::NonProxy);
    }

    #[test]
    fn urltest_with_mixed_members_fails() {
        let mut config = runtime_config();
        config["outbounds"][2]["outbounds"] = json!(["node-a", "direct"]);

        assert_eq!(status(config).final_resolution, Resolution::NonProxy);
    }

    #[test]
    fn cn_direct_urltest_cannot_launder_direct() {
        let mut config = runtime_config();
        config["outbounds"][5] =
            json!({"type": "urltest", "tag": "cn-direct", "outbounds": ["direct"]});

        assert_eq!(status(config).cn_direct_resolution, Resolution::NonProxy);
    }

    #[test]
    fn tor_endpoint_passes_without_server_or_port() {
        let mut config = runtime_config();
        config["outbounds"][3] = json!({"type": "tor", "tag": "node-a"});

        assert!(status(config).ok());
    }

    #[test]
    fn ssh_endpoint_passes_without_port() {
        let mut config = runtime_config();
        config["outbounds"][3] = json!({"type": "ssh", "tag": "node-a", "server": "192.0.2.2"});

        assert!(status(config).ok());
    }

    #[test]
    fn ssh_endpoint_with_empty_server_fails() {
        let mut config = runtime_config();
        config["outbounds"][3] = json!({"type": "ssh", "tag": "node-a", "server": ""});

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn server_endpoint_with_zero_port_fails() {
        let mut config = runtime_config();
        config["outbounds"][3]["server_port"] = json!(0);

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn server_endpoint_without_server_fails() {
        let mut config = runtime_config();
        config["outbounds"][3]
            .as_object_mut()
            .expect("fixture outbound must be an object")
            .remove("server");

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn server_endpoint_with_empty_server_fails() {
        let mut config = runtime_config();
        config["outbounds"][3]["server"] = json!("");

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn server_endpoint_without_port_fails() {
        let mut config = runtime_config();
        config["outbounds"][3]
            .as_object_mut()
            .expect("fixture outbound must be an object")
            .remove("server_port");

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn server_endpoint_with_port_above_u16_fails() {
        let mut config = runtime_config();
        config["outbounds"][3]["server_port"] = json!(65536);

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn ssh_endpoint_with_invalid_present_port_fails() {
        let mut config = runtime_config();
        config["outbounds"][3] = json!({
            "type": "ssh",
            "tag": "node-a",
            "server": "192.0.2.2",
            "server_port": 65536
        });

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn reviewer_minimal_protocol_variants_are_proxy_paths() {
        for kind in [
            "socks",
            "http",
            "shadowsocks",
            "vmess",
            "vless",
            "trojan",
            "hysteria",
            "hysteria2",
            "tuic",
            "shadowtls",
            "anytls",
            "naive",
        ] {
            let mut config = runtime_config();
            config["outbounds"][3] = json!({
                "type": kind,
                "tag": "node-a",
                "server": "192.0.2.1",
                "server_port": 443
            });

            assert_eq!(
                status(config).final_resolution,
                Resolution::Proxy,
                "minimal endpoint rejected for {kind}"
            );
        }
    }

    #[test]
    fn hysteria_port_hopping_scalar_and_array_are_proxy_paths() {
        for (kind, server_ports) in [
            ("hysteria", json!("443")),
            ("hysteria", json!(["443", "443:443", "8443:8450"])),
            ("hysteria2", json!("443:445")),
            ("hysteria2", json!(["443", "8443:8450"])),
        ] {
            let mut config = runtime_config();
            config["outbounds"][3] = endpoint(kind, "node-a");
            config["outbounds"][3]
                .as_object_mut()
                .expect("fixture outbound must be an object")
                .remove("server_port");
            config["outbounds"][3]["server_ports"] = server_ports;

            assert_eq!(
                status(config).final_resolution,
                Resolution::Proxy,
                "valid port hopping rejected for {kind}"
            );
        }
    }

    #[test]
    fn invalid_hysteria_server_ports_are_rejected() {
        for server_ports in [
            json!(""),
            json!([]),
            json!(null),
            json!(443),
            json!([443]),
            json!("0"),
            json!("65536"),
            json!("500:400"),
            json!(":443"),
            json!("443:"),
            json!("abc"),
            json!("443:444:445"),
            json!(["443", "0"]),
        ] {
            let mut config = runtime_config();
            config["outbounds"][3] = endpoint("hysteria2", "node-a");
            config["outbounds"][3]
                .as_object_mut()
                .expect("fixture outbound must be an object")
                .remove("server_port");
            config["outbounds"][3]["server_ports"] = server_ports;

            assert_eq!(status(config).final_resolution, Resolution::Invalid);
        }
    }

    #[test]
    fn ordinary_proxy_cannot_use_server_ports_instead_of_server_port() {
        let mut config = runtime_config();
        config["outbounds"][3] = json!({
            "type": "socks",
            "tag": "node-a",
            "server": "192.0.2.1",
            "server_ports": ["443", "8443:8450"]
        });

        assert_eq!(status(config).final_resolution, Resolution::Invalid);
    }

    #[test]
    fn pinned_proxy_endpoint_matrix_passes() {
        for kind in [
            "socks",
            "http",
            "shadowsocks",
            "vmess",
            "vless",
            "trojan",
            "hysteria",
            "hysteria2",
            "tuic",
            "shadowtls",
            "anytls",
            "naive",
            "tor",
            "ssh",
        ] {
            let mut config = runtime_config();
            config["outbounds"][3] = endpoint(kind, "node-a");

            assert!(status(config).ok(), "supported endpoint rejected: {kind}");
        }
    }

    #[test]
    fn unsupported_snell_and_legacy_wireguard_fail() {
        for kind in ["snell", "wireguard"] {
            let mut config = runtime_config();
            config["outbounds"][3] = endpoint(kind, "node-a");

            assert_eq!(
                status(config).final_resolution,
                Resolution::Invalid,
                "unsupported endpoint accepted: {kind}"
            );
        }
    }

    #[test]
    fn unconditional_direct_rule_fails() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .push(json!({
                "action": "route",
                "outbound": "cn-direct",
                "override_address": "example.invalid",
                "fallback_network_type": ["wifi"],
                "tls_spoof": true
            }));

        let status = status(config);
        assert_eq!(status.catchall_direct, 1);
        assert!(!status.ok());
    }

    #[test]
    fn legacy_direct_action_is_a_catchall() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .push(json!({"action": "direct"}));

        assert_eq!(status(config).catchall_direct, 1);
    }

    #[test]
    fn direct_dialer_options_cannot_hide_catchall() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .push(json!({"action": "direct", "bind_interface": "lo"}));

        assert_eq!(status(config).catchall_direct, 1);
    }

    #[test]
    fn bypass_action_is_a_catchall_with_or_without_outbound() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .extend([
                json!({"action": "bypass"}),
                json!({"action": "bypass", "outbound": "proxy"}),
            ]);

        assert_eq!(status(config).catchall_direct, 2);
    }

    #[test]
    fn invert_false_cannot_hide_direct_catchall() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .push(json!({"action": "direct", "invert": false}));

        assert_eq!(status(config).catchall_direct, 1);
    }

    #[test]
    fn invert_true_cannot_hide_direct_catchall() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .push(json!({"action": "direct", "invert": true}));

        assert_eq!(status(config).catchall_direct, 1);
    }

    #[test]
    fn domain_with_either_invert_value_conditions_direct_rule() {
        for invert in [false, true] {
            let status = status_with_rule(json!({
                "domain": "example.cn",
                "invert": invert,
                "action": "direct"
            }));

            assert_eq!(
                status.catchall_direct, 0,
                "invert={invert} changed a real matcher's condition"
            );
        }
    }

    #[test]
    fn rule_set_source_modifiers_cannot_hide_direct_catchalls() {
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .extend([
                json!({"action": "direct", "rule_set_ipcidr_match_source": false}),
                json!({"action": "direct", "rule_set_ip_cidr_match_source": true}),
            ]);

        assert_eq!(status(config).catchall_direct, 2);
    }

    #[test]
    fn false_boolean_matchers_cannot_hide_direct_catchall() {
        for field in [
            "network_is_expensive",
            "network_is_constrained",
            "source_ip_is_private",
            "ip_is_private",
        ] {
            let mut config = runtime_config();
            let mut rule = json!({"action": "direct"});
            rule[field] = json!(false);
            config["route"]["rules"]
                .as_array_mut()
                .expect("fixture rules must be an array")
                .push(rule);

            assert_eq!(
                status(config).catchall_direct,
                1,
                "false matcher hid catchall: {field}"
            );
        }
    }

    #[test]
    fn malformed_matcher_values_cannot_hide_direct_catchall() {
        for (field, value) in [
            ("domain", json!(null)),
            ("domain", json!({})),
            ("domain", json!(["example.cn", null])),
            ("port", json!(0.5)),
            ("ip_version", json!(1)),
            ("ip_version", json!([null])),
            ("ip_version", json!([4, "6"])),
        ] {
            let mut config = runtime_config();
            let mut rule = json!({"action": "direct"});
            rule[field] = value;
            config["route"]["rules"]
                .as_array_mut()
                .expect("fixture rules must be an array")
                .push(rule);

            let status = status(config);
            assert_eq!(
                (status.invalid_rules, status.catchall_direct),
                (1, 0),
                "malformed matcher was not invalid: {field}"
            );
        }
    }

    #[test]
    fn empty_matchers_remain_ineffective_direct_catchalls() {
        for value in [json!(""), json!([])] {
            let status = status_with_rule(json!({"domain": value, "action": "direct"}));

            assert_eq!((status.invalid_rules, status.catchall_direct), (0, 1));
        }
    }

    #[test]
    fn valid_typed_matchers_condition_direct_rules() {
        for (field, value) in [
            ("domain", json!("example.cn")),
            ("domain", json!(["example.cn"])),
            ("port", json!(0)),
            ("port", json!(443)),
            ("port", json!([80, 443])),
            ("port_range", json!("8000:9000")),
            ("user_id", json!(1000)),
            ("user_id", json!(0)),
            ("user_id", json!(-1)),
            ("ip_version", json!(4)),
        ] {
            let mut config = runtime_config();
            let mut rule = json!({"action": "direct"});
            rule[field] = value;
            config["route"]["rules"]
                .as_array_mut()
                .expect("fixture rules must be an array")
                .push(rule);

            assert_eq!(
                status(config).catchall_direct,
                0,
                "valid matcher rejected: {field}"
            );
        }
    }

    #[test]
    fn mixed_matcher_is_invalid_even_when_it_targets_proxy() {
        let status = status_with_rule(json!({
            "domain": ["example.cn", null],
            "outbound": "proxy"
        }));

        assert_eq!((status.invalid_rules, status.catchall_direct), (1, 0));
    }

    #[test]
    fn malformed_cidrs_and_network_types_are_invalid_on_proxy_rules() {
        for (field, value) in [
            ("ip_cidr", json!("192.0.2.0/33")),
            ("source_ip_cidr", json!("not-an-ip")),
            ("ip_cidr", json!("2001:db8::/129")),
            ("network_type", json!("bluetooth")),
        ] {
            let mut rule = json!({"outbound": "proxy"});
            rule[field] = value;
            let status = status_with_rule(rule);

            assert_eq!(
                (status.invalid_rules, status.catchall_direct),
                (1, 0),
                "invalid matcher accepted: {field}"
            );
        }
    }

    #[test]
    fn valid_cidrs_and_network_types_are_effective() {
        for (field, value) in [
            ("ip_cidr", json!("192.0.2.0/24")),
            ("source_ip_cidr", json!("2001:db8::/32")),
            ("network_type", json!("wifi")),
            ("network_type", json!("cellular")),
            ("network_type", json!("ethernet")),
            ("network_type", json!("other")),
        ] {
            let mut rule = json!({"action": "direct"});
            rule[field] = value;
            let status = status_with_rule(rule);

            assert_eq!(
                (status.invalid_rules, status.catchall_direct),
                (0, 0),
                "valid matcher rejected: {field}"
            );
        }
    }

    #[test]
    fn valid_address_maps_condition_direct_rules() {
        for (field, value) in [
            (
                "interface_address",
                json!({"wlan0": ["192.0.2.1", "2001:db8::/32"]}),
            ),
            (
                "network_interface_address",
                json!({"wifi": "192.0.2.0/24", "cellular": ["2001:db8::1"]}),
            ),
            (
                "default_interface_address",
                json!(["192.0.2.1", "2001:db8::/32"]),
            ),
            ("interface_address", json!({"": "192.0.2.1"})),
            (
                "interface_address",
                json!({"wlan0": [], "eth0": "192.0.2.1"}),
            ),
        ] {
            let mut rule = json!({"action": "direct"});
            rule[field] = value;
            let status = status_with_rule(rule);

            assert_eq!(
                (status.invalid_rules, status.catchall_direct),
                (0, 0),
                "valid address matcher rejected: {field}"
            );
        }
    }

    #[test]
    fn empty_address_maps_and_entries_are_ineffective() {
        for (field, value) in [
            ("interface_address", json!({})),
            ("network_interface_address", json!({})),
            ("interface_address", json!({"wlan0": []})),
            ("network_interface_address", json!({"wifi": []})),
        ] {
            let mut rule = json!({"action": "direct"});
            rule[field] = value;
            let status = status_with_rule(rule);

            assert_eq!(
                (status.invalid_rules, status.catchall_direct),
                (0, 1),
                "ineffective address matcher was not a catchall: {field}"
            );
        }
    }

    #[test]
    fn malformed_address_maps_are_invalid() {
        for (field, value) in [
            (
                "network_interface_address",
                json!({"bluetooth": "192.0.2.1"}),
            ),
            ("interface_address", json!({"wlan0": "192.0.2.0/33"})),
            ("interface_address", json!({"wlan0": ["192.0.2.1", null]})),
        ] {
            let mut rule = json!({"outbound": "proxy"});
            rule[field] = value;
            let status = status_with_rule(rule);

            assert_eq!(
                (status.invalid_rules, status.catchall_direct),
                (1, 0),
                "malformed address matcher accepted: {field}"
            );
        }
    }

    #[test]
    fn out_of_range_and_mixed_user_ids_are_invalid() {
        for value in [json!(3_000_000_000_u64), json!(0.5), json!([0, null])] {
            let status = status_with_rule(json!({"user_id": value, "outbound": "proxy"}));

            assert_eq!((status.invalid_rules, status.catchall_direct), (1, 0));
        }
    }

    #[test]
    fn documented_open_port_ranges_condition_direct_rules() {
        for value in [
            json!(":3000"),
            json!("4000:"),
            json!(["1000:2000", ":3000"]),
        ] {
            let mut config = runtime_config();
            let mut rule = json!({"action": "direct"});
            rule["port_range"] = value;
            config["route"]["rules"]
                .as_array_mut()
                .expect("fixture rules must be an array")
                .push(rule);

            assert_eq!(status(config).catchall_direct, 0);
        }
    }

    #[test]
    fn empty_logical_rule_is_invalid_without_becoming_a_catchall() {
        let status = status_with_rule(
            json!({"type": "logical", "mode": "or", "rules": [], "action": "direct"}),
        );

        assert_eq!(
            (status.invalid_rules, status.catchall_direct, status.ok()),
            (1, 0, false)
        );
    }

    #[test]
    fn logical_rule_without_mode_is_invalid() {
        let status = status_with_rule(json!({
            "type": "logical",
            "rules": [{"domain": "example.cn"}],
            "action": "direct"
        }));

        assert_eq!((status.invalid_rules, status.ok()), (1, false));
    }

    #[test]
    fn logical_rule_with_unknown_mode_is_invalid() {
        let status = status_with_rule(json!({
            "type": "logical",
            "mode": "xor",
            "rules": [{"domain": "example.cn"}],
            "action": "direct"
        }));

        assert_eq!((status.invalid_rules, status.ok()), (1, false));
    }

    #[test]
    fn logical_rule_without_rules_is_invalid() {
        let status =
            status_with_rule(json!({"type": "logical", "mode": "and", "action": "direct"}));

        assert_eq!((status.invalid_rules, status.ok()), (1, false));
    }

    #[test]
    fn logical_rule_with_non_object_child_is_invalid() {
        let status = status_with_rule(json!({
            "type": "logical",
            "mode": "or",
            "rules": ["example.cn"],
            "action": "direct"
        }));

        assert_eq!((status.invalid_rules, status.ok()), (1, false));
    }

    #[test]
    fn nested_empty_logical_rule_is_invalid_once() {
        let status = status_with_rule(json!({
            "type": "logical",
            "mode": "and",
            "rules": [{"type": "logical", "mode": "or", "rules": []}],
            "action": "direct"
        }));

        assert_eq!((status.invalid_rules, status.ok()), (1, false));
    }

    #[test]
    fn logical_rule_with_empty_default_child_is_invalid_once() {
        let status = status_with_rule(json!({
            "type": "logical",
            "mode": "and",
            "rules": [{}],
            "action": "direct"
        }));

        assert_eq!((status.invalid_rules, status.ok()), (1, false));
    }

    #[test]
    fn unknown_top_level_rule_type_is_invalid() {
        let status = status_with_rule(json!({
            "type": "future-rule",
            "domain": "example.cn",
            "action": "direct"
        }));

        assert_eq!((status.invalid_rules, status.ok()), (1, false));
    }

    #[test]
    fn scalar_top_level_rule_is_invalid() {
        let status = status_with_rule(json!("example.cn"));

        assert_eq!((status.invalid_rules, status.ok()), (1, false));
    }

    #[test]
    fn invalid_rule_detail_reports_only_the_safe_count() {
        let status = status_with_rule(json!({
            "type": "future-rule",
            "domain": "private.example",
            "action": "direct"
        }));

        assert_eq!(
            status.detail(),
            "valid_json=ok final=proxy cn_direct=direct cn_rule_sets=7 cn_priority=ok catchall_direct=0 invalid_rules=1"
        );
    }

    #[test]
    fn valid_nested_logical_rule_is_conditioned() {
        let status = status_with_rule(json!({
            "type": "logical",
            "mode": "and",
            "rules": [{
                "type": "logical",
                "mode": "or",
                "rules": [{"package_name": "com.example.app"}]
            }],
            "action": "direct"
        }));

        assert_eq!((status.invalid_rules, status.catchall_direct), (0, 0));
    }

    #[test]
    fn matcher_recursion_limit_fails_closed() {
        let mut nested = json!({"domain": "example.cn"});
        for _ in 0..16 {
            nested = json!({"type": "logical", "mode": "and", "rules": [nested]});
        }
        nested["action"] = json!("direct");
        let mut config = runtime_config();
        config["route"]["rules"]
            .as_array_mut()
            .expect("fixture rules must be an array")
            .push(nested);

        let status = status(config);
        assert_eq!((status.invalid_rules, status.catchall_direct), (1, 0));
    }

    #[test]
    fn true_boolean_matchers_condition_direct_rule() {
        for field in [
            "network_is_expensive",
            "network_is_constrained",
            "source_ip_is_private",
            "ip_is_private",
        ] {
            let mut config = runtime_config();
            let mut rule = json!({"action": "direct"});
            rule[field] = json!(true);
            config["route"]["rules"]
                .as_array_mut()
                .expect("fixture rules must be an array")
                .push(rule);

            assert_eq!(
                status(config).catchall_direct,
                0,
                "true matcher did not condition rule: {field}"
            );
        }
    }

    #[test]
    fn conditioned_direct_rules_pass() {
        let mut config = runtime_config();
        config["route"]["rules"] = json!([
            {
                "rule_set": [
                    "lyc-geosite-cn",
                    "lyc-geosite-geolocation-cn",
                    "lyc-geoip-cn",
                    "metacubex-geoip-cn",
                    "ddch-direct",
                    "karing-acl4ssr-china-domain",
                    "karing-acl4ssr-china-ip"
                ],
                "outbound": "cn-direct"
            },
            {"clash_mode": "Direct", "outbound": "direct"},
            {"protocol": "ntp", "port": 123, "outbound": "direct"},
            {"package_name": "com.example.app", "outbound": "direct"},
            {"domain": "example.cn", "outbound": "direct"},
            {"rule_set": ["lyc-geoip-cn"], "outbound": "direct"},
            {"network_is_expensive": true, "action": "direct"},
            {"type": "logical", "mode": "or", "rules": [{"domain": "nested.example"}], "outbound": "direct"}
        ]);

        let status = status(config);
        assert_eq!(status.catchall_direct, 0);
        assert!(status.ok());
    }

    #[test]
    fn missing_canonical_cn_rule_set_fails() {
        let mut config = runtime_config();
        config["route"]["rules"] = json!([
            {"rule_set": ["unrelated"], "outbound": "cn-direct"}
        ]);

        let status = status(config);
        assert_eq!(
            (status.cn_rule_sets, status.cn_priority, status.ok()),
            (0, CnPriority::Ok, false)
        );
    }

    #[test]
    fn invalid_json_fails_without_token_matching() {
        let status = analyze_text(
            r#"{"route":{"final":"proxy"},"outbounds":["cn-direct","shadowsocks"],"token":"secret""#,
        );

        assert_eq!(
            (status.ok(), status.detail()),
            (
                false,
                "valid_json=invalid final=invalid cn_direct=invalid cn_rule_sets=0 cn_priority=invalid catchall_direct=0 invalid_rules=0".to_string()
            )
        );
    }

    #[test]
    fn missing_config_fails_with_stable_safe_detail() {
        let app = App::for_test(
            std::env::temp_dir().join(format!("magicnet-routing-missing-{}", std::process::id())),
        );

        assert_eq!(
            routing_policy_check(&app),
            (
                false,
                "valid_json=missing final=invalid cn_direct=invalid cn_rule_sets=0 cn_priority=invalid catchall_direct=0 invalid_rules=0".to_string()
            )
        );
    }

    #[test]
    fn source_config_fails_closed_without_subscription_nodes() {
        // Bundled MagicSingBox template lives in the sing-box config submodule.
        // Prefer a runtime read so `cargo check` still works before
        // `git submodule update --init src/MagicNet/.config/sing-box`.
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../src/MagicNet/.config/sing-box/config.json");
        let text = fs::read_to_string(&path).unwrap_or_else(|err| {
            panic!(
                "bundled sing-box config missing at {}: {err}; run `git submodule update --init src/MagicNet/.config/sing-box`",
                path.display()
            )
        });
        let status = analyze_text(&text);

        assert_eq!(
            status,
            RoutingPolicyStatus {
                valid_json: JsonStatus::Ok,
                final_resolution: Resolution::Block,
                cn_direct_resolution: Resolution::Direct,
                cn_rule_sets: 7,
                cn_priority: CnPriority::Ok,
                catchall_direct: 0,
                invalid_rules: 0,
            }
        );
    }
}
