#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${MAGICNET_ROUTING_CONFIG_DIR:-$ROOT/src/MagicNet/.config/sing-box}"
CONFIG_FILE="$CONFIG_DIR/config.json"

[[ -f "$CONFIG_FILE" ]] || {
    printf 'Action routing test failed: missing config: %s\n' "$CONFIG_FILE" >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    printf 'Action routing test failed: python3 is required\n' >&2
    exit 1
}

python3 - "$CONFIG_FILE" <<'PY'
import ipaddress
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

route_rules = config["route"]["rules"]
chatgpt_packages = {"com.openai.chatgpt", "com.openai.chat", "ai.openai.chatgpt"}
x_packages = {"com.twitter.android"}

if config.get("dns", {}).get("reverse_mapping") is not True:
    raise AssertionError(
        "DNS reverse_mapping must preserve domain ownership for IP-only Android flows"
    )


def values(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def exact_indexes(expected):
    return [index for index, rule in enumerate(route_rules) if rule == expected]


def package_indexes(packages, outbound):
    return [
        index
        for index, rule in enumerate(route_rules)
        if rule.get("outbound") == outbound
        and set(values(rule.get("package_name"))) == packages
        and set(rule) == {"package_name", "outbound"}
    ]


chatgpt_indexes = package_indexes(chatgpt_packages, "ai-chatgpt")
x_indexes = package_indexes(x_packages, "social-proxy")
if len(chatgpt_indexes) != 1:
    raise AssertionError(f"expected one exact ChatGPT package route, got {chatgpt_indexes}")
if len(x_indexes) != 1:
    raise AssertionError(f"expected one exact X package route, got {x_indexes}")

x_domain_rule = {
    "domain_suffix": ["twitter.com", "x.com", "twimg.com"],
    "outbound": "social-proxy",
}
cn_ip_rule = {
    "rule_set": ["lyc-geoip-cn", "metacubex-geoip-cn", "karing-acl4ssr-china-ip"],
    "outbound": "cn-direct",
}
invalid_destination_rule = {
    "ip_cidr": ["0.0.0.0/8"],
    "outbound": "block",
}
x_domain_indexes = [index for index, rule in enumerate(route_rules) if rule == x_domain_rule]
cn_ip_indexes = [index for index, rule in enumerate(route_rules) if rule == cn_ip_rule]
invalid_destination_indexes = [
    index for index, rule in enumerate(route_rules) if rule == invalid_destination_rule
]
if len(x_domain_indexes) != 1 or len(cn_ip_indexes) != 1 or len(invalid_destination_indexes) != 1:
    raise AssertionError(
        f"expected one invalid-destination guard, one early X route and one canonical CN IP route: "
        f"invalid={invalid_destination_indexes} x={x_domain_indexes} cn={cn_ip_indexes}"
    )
if x_domain_indexes[0] >= cn_ip_indexes[0]:
    raise AssertionError(
        "X domains must be routed before the canonical CN IP rule so CDN/API IPs "
        f"cannot be sent direct: x={x_domain_indexes[0]} cn={cn_ip_indexes[0]}"
    )
def domain_matches(rule, domain):
    return any(
        domain == suffix or domain.endswith("." + suffix)
        for suffix in values(rule.get("domain_suffix"))
    )


def ip_matches(rule, destination_ip):
    cidrs = values(rule.get("ip_cidr"))
    if not cidrs:
        return True
    address = ipaddress.ip_address(destination_ip)
    return any(address in ipaddress.ip_network(cidr) for cidr in cidrs)


def package_matches(rule, package_name):
    packages = values(rule.get("package_name"))
    return not packages or package_name in packages


def first_modeled_outbound(
    domain,
    destination_ip,
    package_name,
    *,
    network="tcp",
    port=443,
):
    for index, rule in enumerate(route_rules):
        if "outbound" not in rule:
            continue
        if rule.get("clash_mode") is not None:
            continue
        if rule.get("protocol") not in (None, "tls"):
            continue
        networks = values(rule.get("network"))
        if networks and network not in networks:
            continue
        ports = values(rule.get("port"))
        if ports and port not in ports:
            continue
        if not package_matches(rule, package_name):
            continue
        if rule.get("domain_suffix") and not domain_matches(rule, domain):
            continue
        if not ip_matches(rule, destination_ip):
            continue
        if any(key in rule for key in ("domain", "domain_keyword", "rule_set", "ip_is_private")):
            continue
        return index, rule["outbound"]
    raise AssertionError("action flow did not match any modeled route")


if first_modeled_outbound("invalid-action.invalid", "0.0.0.1", None) != (
    invalid_destination_indexes[0],
    "block",
):
    raise AssertionError("reserved 0.0.0.0/8 destinations must fail closed before direct routing")


for package_name, expected_index, expected_outbound in (
    ("com.openai.chatgpt", chatgpt_indexes[0], "ai-chatgpt"),
    ("com.twitter.android", x_indexes[0], "social-proxy"),
):
    index, outbound = first_modeled_outbound(
        "unclassified-action.invalid",
        "203.0.113.10",
        package_name,
    )
    if (index, outbound) != (expected_index, expected_outbound):
        raise AssertionError(
            f"{package_name} package-first action flow matched index={index} outbound={outbound}"
        )

for domain in ("api.x.com", "upload.twitter.com", "abs.twimg.com"):
    index, outbound = first_modeled_outbound(
        domain,
        "203.0.113.10",
        "com.twitter.android",
    )
    if (index, outbound) != (x_indexes[0], "social-proxy"):
        raise AssertionError(
            f"X posting domain {domain} did not keep the package-first social-proxy route: "
            f"index={index} outbound={outbound}"
        )

    mapped_index, mapped_outbound = first_modeled_outbound(
        domain,
        "203.0.113.10",
        "",
    )
    if mapped_outbound != "social-proxy":
        raise AssertionError(
            f"reverse-mapped X domain {domain} did not select social-proxy: "
            f"index={mapped_index} outbound={mapped_outbound}"
        )

for domain in ("api.x.com", "upload.twitter.com", "abs.twimg.com"):
    index, outbound = first_modeled_outbound(
        domain,
        "203.0.113.10",
        None,
    )
    if (index, outbound) != (x_domain_indexes[0], "social-proxy"):
        raise AssertionError(
            f"X domain-only action flow did not beat CN IP routing for {domain}: "
            f"index={index} outbound={outbound}"
        )

for domain in ("api.openai.com", "auth.openai.com", "ws.chatgpt.com", "events.oaistatsig.com"):
    index, outbound = first_modeled_outbound(
        domain,
        "203.0.113.10",
        "com.openai.chatgpt",
    )
    if (index, outbound) != (chatgpt_indexes[0], "ai-chatgpt"):
        raise AssertionError(
            f"ChatGPT voice/auth domain {domain} did not keep the package-first ai-chatgpt route: "
            f"index={index} outbound={outbound}"
        )

    mapped_index, mapped_outbound = first_modeled_outbound(
        domain,
        "203.0.113.10",
        "",
    )
    if mapped_outbound != "ai-chatgpt":
        raise AssertionError(
            f"reverse-mapped ChatGPT domain {domain} did not select ai-chatgpt: "
            f"index={mapped_index} outbound={mapped_outbound}"
        )

voice_rules = [
    (index, rule)
    for index, rule in enumerate(route_rules)
    if rule.get("network") == "udp"
    and rule.get("port") == 3478
    and rule.get("outbound") == "ai-chatgpt"
    and set(rule) == {"network", "port", "ip_cidr", "outbound"}
]
if len(voice_rules) != 1:
    raise AssertionError(f"expected one exact ChatGPT Voice route, got {voice_rules}")
voice_index, voice_rule = voice_rules[0]
voice_cidrs = values(voice_rule.get("ip_cidr"))
if not voice_cidrs:
    raise AssertionError("ChatGPT Voice route must contain the official IP prefixes")
for prefix in voice_cidrs:
    ipaddress.ip_network(prefix)

cn_ip_indexes = [
    index
    for index, rule in enumerate(route_rules)
    if rule.get("outbound") == "cn-direct"
    and (rule.get("ip_cidr") or rule.get("rule_set"))
]
if not cn_ip_indexes or voice_index >= min(cn_ip_indexes):
    raise AssertionError(
        f"ChatGPT Voice route must precede CN IP ownership: voice={voice_index} cn={cn_ip_indexes}"
    )

voice_address = str(ipaddress.ip_network(voice_cidrs[0]).network_address)
matched_index, matched_outbound = first_modeled_outbound(
    "",
    voice_address,
    "",
    network="udp",
    port=3478,
)
if (matched_index, matched_outbound) != (voice_index, "ai-chatgpt"):
    raise AssertionError(
        "official ChatGPT Voice IP-only flow did not select ai-chatgpt: "
        f"index={matched_index} outbound={matched_outbound}"
    )

chatgpt_domain_rules = [
    rule
    for rule in route_rules
    if rule.get("outbound") == "ai-chatgpt"
    and "domain_suffix" in rule
]
oaistatsig_owners = [
    rule for rule in chatgpt_domain_rules if domain_matches(rule, "events.oaistatsig.com")
]
if len(oaistatsig_owners) != 1:
    raise AssertionError(
        "OpenAI feature/auth traffic must have one ai-chatgpt owner for oaistatsig.com"
    )

print("ChatGPT/X action routing policy test passed")
PY
