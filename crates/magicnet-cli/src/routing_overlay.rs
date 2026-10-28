//! Additive user routing carried by the existing private override transaction.
use std::collections::{BTreeMap, BTreeSet};

use serde_json::{json, Value};

pub(crate) const KEY: &str = "$magicnet_routing";
type Result<T> = std::result::Result<T, &'static str>;

fn text(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
        .ok_or("override.routing_invalid")
}

fn fields(value: &Value, allowed: &[&str]) -> Result<()> {
    let object = value.as_object().ok_or("override.routing_invalid")?;
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err("override.routing_invalid");
    }
    Ok(())
}

fn array<'a>(value: &'a Value, key: &str, limit: usize) -> Result<&'a [Value]> {
    let items = value[key].as_array().ok_or("override.routing_invalid")?;
    if items.len() > limit {
        return Err("override.routing_limit");
    }
    Ok(items)
}

fn references(item: &Value) -> Vec<&str> {
    item["outbounds"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .chain(item["detour"].as_str())
        .collect()
}

fn visit<'a>(
    tag: &'a str,
    nodes: &BTreeMap<&'a str, &'a Value>,
    path: &mut BTreeSet<&'a str>,
    done: &mut BTreeSet<&'a str>,
) -> Result<()> {
    if done.contains(tag) {
        return Ok(());
    }
    if !path.insert(tag) || path.len() > 128 {
        return Err("override.routing_cycle");
    }
    if let Some(item) = nodes.get(tag) {
        for target in references(item) {
            if !nodes.contains_key(target) {
                return Err("override.routing_target_missing");
            }
            visit(target, nodes, path, done)?;
        }
    }
    path.remove(tag);
    done.insert(tag);
    Ok(())
}

fn protected_rule(rule: &Value) -> bool {
    rule.get("clash_mode").is_some()
        || rule.get("ip_is_private").is_some()
        || rule.get("preferred_by").is_some()
        || rule["outbound"] == "lan"
        || matches!(rule["action"].as_str(), Some("sniff" | "hijack-dns"))
}

fn direct_target(tag: &str, nodes: &BTreeMap<&str, &Value>, depth: usize) -> bool {
    if depth > 64 {
        return false;
    }
    let Some(item) = nodes.get(tag) else {
        return false;
    };
    if item["type"] == "direct" {
        return true;
    }
    item["default"]
        .as_str()
        .is_some_and(|next| direct_target(next, nodes, depth + 1))
}

/// Return exactly the entries this layer owns, for a later subscription rebase.
pub(crate) fn apply(config: &mut Value, overlay: &Value) -> Result<Value> {
    if overlay.is_null() {
        return Ok(json!({}));
    }
    fields(overlay, &["schema", "rules", "outbounds"])?;
    if overlay["schema"] != 1 {
        return Err("override.routing_invalid");
    }
    let custom = array(overlay, "outbounds", 64)?;
    let rules = array(overlay, "rules", 256)?;
    let existing = config["outbounds"]
        .as_array()
        .ok_or("override.routing_invalid")?;
    let mut nodes = BTreeMap::new();
    for item in existing
        .iter()
        .chain(config["endpoints"].as_array().into_iter().flatten())
    {
        nodes.insert(text(&item["tag"])?, item);
    }
    for item in custom {
        let tag = text(&item["tag"])?;
        if nodes.insert(tag, item).is_some() {
            return Err("override.routing_tag_collision");
        }
        let kind = text(&item["type"])?;
        if matches!(kind, "selector" | "urltest") {
            fields(
                item,
                &["type", "tag", "outbounds", "default", "url", "interval"],
            )?;
            let members = array(item, "outbounds", 128)?;
            if members.is_empty() || members.iter().any(|v| text(v).is_err()) {
                return Err("override.routing_invalid");
            }
            if item.get("default").is_some_and(|v| !members.contains(v)) {
                return Err("override.routing_invalid");
            }
        } else {
            if !matches!(
                kind,
                "socks"
                    | "http"
                    | "shadowsocks"
                    | "trojan"
                    | "vless"
                    | "vmess"
                    | "hysteria2"
                    | "tuic"
                    | "anytls"
            ) {
                return Err("override.routing_invalid");
            }
            fields(
                item,
                &[
                    "type",
                    "tag",
                    "server",
                    "server_port",
                    "username",
                    "password",
                    "method",
                    "uuid",
                    "tls",
                    "detour",
                    "version",
                    "security",
                    "alter_id",
                ],
            )?;
            text(&item["server"])?;
            if !item["server_port"]
                .as_u64()
                .is_some_and(|p| (1..=65535).contains(&p))
            {
                return Err("override.routing_invalid");
            }
        }
    }
    let mut done = BTreeSet::new();
    for item in custom {
        visit(text(&item["tag"])?, &nodes, &mut BTreeSet::new(), &mut done)?;
    }
    let mut compiled = Vec::new();
    let mut dns_rules = Vec::new();
    let mut dns_servers: Vec<Value> = Vec::new();
    let mut resolvers: BTreeMap<&str, String> = BTreeMap::new();
    let mut seen = BTreeSet::new();
    for rule in rules {
        fields(rule, &["kind", "value", "outbound"])?;
        let kind = text(&rule["kind"])?;
        let value = text(&rule["value"])?;
        let target = text(&rule["outbound"])?;
        if !nodes.contains_key(target) {
            return Err("override.routing_target_missing");
        }
        if !seen.insert((kind, value)) {
            return Err("override.routing_duplicate");
        }
        let field = match kind {
            "domain"
                if value.len() <= 253
                    && value.contains('.')
                    && value.split('.').all(|part| {
                        !part.is_empty()
                            && part.len() <= 63
                            && !part.starts_with('-')
                            && !part.ends_with('-')
                            && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                    }) =>
            {
                "domain_suffix"
            }
            "app"
                if value.contains('.')
                    && value.split('.').all(|part| {
                        !part.is_empty()
                            && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                    }) =>
            {
                "package_name"
            }
            _ => return Err("override.routing_invalid"),
        };
        compiled.push(json!({field:[value], "action":"route", "outbound":target}));
        if config.get("dns").is_some() {
            if nodes
                .get(target)
                .is_some_and(|item| item["type"] == "block")
            {
                dns_rules.push(json!({field:[value],"action":"reject"}));
                continue;
            }
            let resolver = if let Some(tag) = resolvers.get(target) {
                tag.clone()
            } else {
                let template = if direct_target(target, &nodes, 0) {
                    "bootstrap-local-dns"
                } else {
                    "doh-google"
                };
                let existing_servers = config["dns"]["servers"]
                    .as_array()
                    .ok_or("override.routing_dns_missing")?;
                let mut server = existing_servers
                    .iter()
                    .find(|item| item["tag"] == template)
                    .cloned()
                    .ok_or("override.routing_dns_missing")?;
                let tag = format!("magicnet-routing-dns-{}", dns_servers.len());
                if existing_servers.iter().any(|item| item["tag"] == tag) {
                    return Err("override.routing_tag_collision");
                }
                server["tag"] = json!(tag);
                server["detour"] = json!(target);
                dns_servers.push(server);
                resolvers.insert(target, tag.clone());
                tag
            };
            dns_rules.push(json!({field:[value],"server":resolver}));
        }
    }
    let mut outbounds = existing.clone();
    outbounds.extend_from_slice(custom);
    config["outbounds"] = Value::Array(outbounds);
    let current = config
        .pointer_mut("/route/rules")
        .and_then(Value::as_array_mut)
        .ok_or("override.routing_invalid")?;
    // Preserve explicit mode, DNS interception, LAN and Tailnet guards ahead of
    // user policy. Other base rules retain their relative order and contents.
    compiled.retain(|rule| !current.contains(rule));
    let at = current
        .iter()
        .rposition(protected_rule)
        .map_or(0, |index| index + 1);
    current.splice(at..at, compiled.iter().cloned());
    if !dns_rules.is_empty() {
        config["dns"]["servers"]
            .as_array_mut()
            .ok_or("override.routing_dns_missing")?
            .extend(dns_servers.iter().cloned());
        let current = config
            .pointer_mut("/dns/rules")
            .and_then(Value::as_array_mut)
            .ok_or("override.routing_invalid")?;
        dns_rules.retain(|rule| !current.contains(rule));
        let at = current
            .iter()
            .rposition(|rule| {
                rule.get("clash_mode").is_some()
                    || rule["domain_suffix"].as_array().is_some_and(|domains| {
                        !domains.is_empty()
                            && domains.iter().all(|domain| {
                                matches!(
                                    domain.as_str(),
                                    Some(
                                        "local" | "home.arpa" | "lan" | "tailscale.net" | "ts.net"
                                    )
                                )
                            })
                    })
            })
            .map_or(0, |i| i + 1);
        current.splice(at..at, dns_rules.iter().cloned());
    }
    Ok(
        json!({"outbounds":custom, "route_rules":compiled,"dns_rules":dns_rules,"dns_servers":dns_servers}),
    )
}

pub(crate) fn undo(config: &mut Value, owned: &Value) -> Result<()> {
    for (path, key) in [
        ("/outbounds", "outbounds"),
        ("/route/rules", "route_rules"),
        ("/dns/rules", "dns_rules"),
        ("/dns/servers", "dns_servers"),
    ] {
        let Some(entries) = owned[key].as_array() else {
            continue;
        };
        if entries.is_empty() {
            continue;
        }
        let Some(current) = config.pointer_mut(path).and_then(Value::as_array_mut) else {
            return Err("override.routing_conflict");
        };
        for entry in entries {
            if let Some(index) = current.iter().position(|v| v == entry) {
                current.remove(index);
            } else if (matches!(key, "outbounds" | "dns_servers")
                && current.iter().any(|v| v["tag"] == entry["tag"]))
                || (!matches!(key, "outbounds" | "dns_servers")
                    && current.iter().any(|v| {
                        ["domain_suffix", "package_name"]
                            .iter()
                            .any(|key| entry.get(key).is_some() && v.get(key) == entry.get(key))
                    }))
            {
                return Err("override.routing_conflict");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn base() -> Value {
        json!({"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[{"ip_is_private":true,"outbound":"direct"},{"domain_suffix":["base.test"],"outbound":"block"}]}})
    }
    fn overlay() -> Value {
        json!({"schema":1,"outbounds":[{"type":"selector","tag":"My route","outbounds":["direct","block"],"default":"direct"}],"rules":[{"kind":"domain","value":"user.test","outbound":"My route"},{"kind":"app","value":"com.example.app","outbound":"My route"}]})
    }
    #[test]
    fn additive_policy_keeps_base_and_can_be_removed_after_subscription_updates() {
        let old = base();
        let mut c = old.clone();
        let owned = apply(&mut c, &overlay()).unwrap();
        assert_eq!(c["route"]["rules"][0], old["route"]["rules"][0]);
        assert_eq!(
            c["route"]["rules"][1]["domain_suffix"],
            json!(["user.test"])
        );
        c["outbounds"]
            .as_array_mut()
            .unwrap()
            .push(json!({"type":"direct","tag":"new-subscription"}));
        undo(&mut c, &owned).unwrap();
        assert_eq!(c["route"], old["route"]);
        assert_eq!(c["outbounds"].as_array().unwrap().len(), 3);
    }
    #[test]
    fn app_and_domain_dns_follow_the_target_and_precede_business_categories() {
        let mut c = base();
        c["dns"] = json!({"servers":[{"tag":"bootstrap-local-dns","type":"https","server":"223.5.5.5"},{"tag":"doh-google","type":"https","server":"8.8.8.8","detour":"proxy"}],"rules":[{"clash_mode":"Direct","server":"bootstrap-local-dns"},{"domain_suffix":["local","lan"],"server":"bootstrap-local-dns"},{"rule_set":["business"],"server":"bootstrap-local-dns"}]});
        let old = c.clone();
        let owned = apply(&mut c, &overlay()).unwrap();
        assert_eq!(c["dns"]["rules"][2]["domain_suffix"], json!(["user.test"]));
        assert_eq!(
            c["dns"]["rules"][3]["package_name"],
            json!(["com.example.app"])
        );
        let server = c["dns"]["servers"].as_array().unwrap().last().unwrap();
        assert_eq!(server["detour"], "My route");
        assert_eq!(server["server"], "223.5.5.5");
        undo(&mut c, &owned).unwrap();
        assert_eq!(c, old);
    }
    #[test]
    fn collisions_cycles_and_missing_targets_are_rejected() {
        let mut o = overlay();
        o["outbounds"][0]["tag"] = json!("direct");
        assert_eq!(
            apply(&mut base(), &o),
            Err("override.routing_tag_collision")
        );
        let mut o = overlay();
        o["outbounds"][0]["outbounds"] = json!(["My route"]);
        o["outbounds"][0]["default"] = json!("My route");
        assert_eq!(apply(&mut base(), &o), Err("override.routing_cycle"));
        let mut o = overlay();
        o["rules"][0]["outbound"] = json!("absent");
        assert_eq!(
            apply(&mut base(), &o),
            Err("override.routing_target_missing")
        );
    }
    #[test]
    fn externally_modified_owned_outbound_is_a_conflict() {
        let mut c = base();
        let owned = apply(&mut c, &overlay()).unwrap();
        c["outbounds"][2]["default"] = json!("block");
        assert_eq!(undo(&mut c, &owned), Err("override.routing_conflict"));
    }
    #[test]
    fn arbitrary_labels_are_data_and_invalid_fields_fail_closed() {
        for tag in ["constructor", "__proto__", "toString", "hasOwnProperty"] {
            let mut o = overlay();
            o["outbounds"][0]["tag"] = json!(tag);
            for r in o["rules"].as_array_mut().unwrap() {
                r["outbound"] = json!(tag);
            }
            assert!(apply(&mut base(), &o).is_ok());
        }
        let mut o = overlay();
        o["rules"][0]["value"] = json!("bad.test; id");
        assert_eq!(apply(&mut base(), &o), Err("override.routing_invalid"));
    }
}
