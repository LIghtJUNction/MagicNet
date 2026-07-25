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
fakeip_guard = {
    "ip_cidr": ["127.0.0.1/32", "::1/128", "198.18.0.0/16", "28.0.0.0/8"],
    "outbound": "block",
}
chatgpt_packages = {"com.openai.chatgpt", "com.openai.chat", "ai.openai.chatgpt"}
x_packages = {"com.twitter.android"}


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


guard_indexes = exact_indexes(fakeip_guard)
chatgpt_indexes = package_indexes(chatgpt_packages, "ai-chatgpt")
x_indexes = package_indexes(x_packages, "social-proxy")
if len(guard_indexes) != 1:
    raise AssertionError(f"expected one exact FakeIP guard, got {guard_indexes}")
if len(chatgpt_indexes) != 1:
    raise AssertionError(f"expected one exact ChatGPT package route, got {chatgpt_indexes}")
if len(x_indexes) != 1:
    raise AssertionError(f"expected one exact X package route, got {x_indexes}")

guard_index = guard_indexes[0]
if chatgpt_indexes[0] >= guard_index or x_indexes[0] >= guard_index:
    raise AssertionError(
        "ChatGPT and X package routes must precede the FakeIP guard: "
        f"chatgpt={chatgpt_indexes[0]} x={x_indexes[0]} guard={guard_index}"
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


def first_modeled_outbound(domain, destination_ip, package_name):
    for index, rule in enumerate(route_rules):
        if "outbound" not in rule:
            continue
        if rule.get("clash_mode") is not None:
            continue
        if rule.get("protocol") not in (None, "tls"):
            continue
        if rule.get("network") not in (None, "tcp"):
            continue
        ports = values(rule.get("port"))
        if ports and 443 not in ports:
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


for package_name, expected_index, expected_outbound in (
    ("com.openai.chatgpt", chatgpt_indexes[0], "ai-chatgpt"),
    ("com.twitter.android", x_indexes[0], "social-proxy"),
):
    index, outbound = first_modeled_outbound(
        "unclassified-action.invalid",
        "198.18.1.1",
        package_name,
    )
    if (index, outbound) != (expected_index, expected_outbound):
        raise AssertionError(
            f"{package_name} FakeIP action flow matched index={index} outbound={outbound}"
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
