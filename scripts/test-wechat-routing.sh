#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${MAGICNET_ROUTING_CONFIG_DIR:-$ROOT/src/MagicNet/.config/sing-box}"
CONFIG_FILE="$CONFIG_DIR/config.json"

[[ -f "$CONFIG_FILE" ]] || {
    printf 'WeChat routing test failed: missing config: %s\n' "$CONFIG_FILE" >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    printf 'WeChat routing test failed: python3 is required\n' >&2
    exit 1
}

python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

route_rules = config["route"]["rules"]


def exact_indexes(rules, expected):
    return [index for index, rule in enumerate(rules) if rule == expected]


cn_routes = [
    index for index, rule in enumerate(route_rules)
    if rule.get("outbound") == "cn-direct" and rule.get("rule_set")
]
if not cn_routes:
    raise AssertionError("domestic traffic must use generic CN rule-set routing")
if any(server.get("type") == "fakeip" or server.get("tag") == "fakeip" for server in config["dns"]["servers"]):
    raise AssertionError("generic domestic routing must use real DNS answers, not FakeIP")
if config.get("experimental", {}).get("cache_file", {}).get("store_fakeip") is True:
    raise AssertionError("generic domestic routing must not persist stale FakeIP mappings")
if any(
    rule.get("outbound") == "block"
    and ({"198.18.0.0/16", "28.0.0.0/8"} & set(rule.get("ip_cidr", [])))
    for rule in route_rules
):
    raise AssertionError("generic routing must not blackhole benchmark or public address space")


def domain_matches(rule, domain):
    return any(
        domain == suffix or domain.endswith("." + suffix)
        for suffix in rule.get("domain_suffix", [])
    )


if any(
    any(
        token in suffix
        for suffix in rule.get("domain_suffix", [])
        for token in ("qq", "wechat", "weixin", "qpic", "qlogo", "tencent")
    )
    for rule in route_rules
):
    raise AssertionError("routing policy must not contain QQ/WeChat/Tencent-specific exceptions")

print("Generic domestic routing policy test passed")
PY
