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
dns_rules = config["dns"]["rules"]
wechat_domains = [
    "qq.com", "weixin.qq.com", "wechat.com", "wechatapp.com", "wechatpay.cn",
    "tenpay.com", "tencent.com", "tencent-cloud.com", "myqcloud.com", "qcloud.com",
    "gtimg.com", "idqqimg.com", "qpic.cn", "qlogo.cn", "qmail.com", "smtcdns.com",
    "servicewechat.com", "weixinbridge.com", "weixinsxy.com", "wx.gtimg.com", "wx.qq.com",
]
wechat_route = {"domain_suffix": wechat_domains, "outbound": "cn-direct"}
wechat_dns = {"domain_suffix": wechat_domains, "server": "bootstrap-local-dns"}
wechat_rule_set_tag = "karing-acl4ssr-wechat"
wechat_ip_route = {"rule_set": wechat_rule_set_tag, "outbound": "cn-direct"}


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


wechat_route_indexes = exact_indexes(route_rules, wechat_route)
wechat_dns_indexes = exact_indexes(dns_rules, wechat_dns)
wechat_ip_route_indexes = exact_indexes(route_rules, wechat_ip_route)
if len(wechat_route_indexes) != 1:
    raise AssertionError(f"expected one canonical WeChat direct route, got {wechat_route_indexes}")
if len(wechat_dns_indexes) != 1:
    raise AssertionError(f"expected one canonical WeChat local-DNS rule, got {wechat_dns_indexes}")
if len(wechat_ip_route_indexes) != 1:
    raise AssertionError(f"expected one maintained WeChat IP route, got {wechat_ip_route_indexes}")

wechat_rule_set_definitions = [
    rule for rule in config["route"]["rule_set"]
    if rule.get("tag") == wechat_rule_set_tag
]
if wechat_rule_set_definitions != [{
    "type": "local",
    "tag": wechat_rule_set_tag,
    "format": "binary",
    "path": "rules/karing-acl4ssr-wechat.srs",
}]:
    raise AssertionError(
        f"expected one packaged WeChat rule-set definition, got {wechat_rule_set_definitions}"
    )

global_route_indexes = [
    index for index, rule in enumerate(route_rules) if rule.get("clash_mode") == "Global"
]
global_dns_indexes = [
    index for index, rule in enumerate(dns_rules) if rule.get("clash_mode") == "Global"
]
if global_route_indexes and wechat_route_indexes[0] <= global_route_indexes[-1]:
    raise AssertionError("Global route mode must retain priority over the WeChat direct route")
if global_dns_indexes and wechat_dns_indexes[0] <= global_dns_indexes[-1]:
    raise AssertionError("Global DNS mode must retain priority over the WeChat local resolver")
if wechat_ip_route_indexes[0] != wechat_route_indexes[0] + 1:
    raise AssertionError("maintained WeChat IP routing must immediately follow its domain route")

if any(
    "com.tencent.mm" in rule.get("package_name", [])
    and rule.get("outbound") == "cn-direct"
    for rule in route_rules
):
    raise AssertionError("WeChat must not be forced wholly direct by package name")

for domain in ("mmbiz.qpic.cn", "wx.qlogo.cn", "res.wx.qq.com", "weixin.qq.com"):
    if not domain_matches(wechat_route, domain):
        raise AssertionError(f"WeChat media domain is missing from direct routing: {domain}")
    if not domain_matches(wechat_dns, domain):
        raise AssertionError(f"WeChat media domain is missing from local DNS: {domain}")

print("WeChat media routing policy test passed")
PY

WECHAT_RULE_FILE="$CONFIG_DIR/rules/karing-acl4ssr-wechat.srs"
if command -v sing-box >/dev/null 2>&1 && [[ -s "$WECHAT_RULE_FILE" ]]; then
    match_output=$(sing-box rule-set match -f binary "$WECHAT_RULE_FILE" 101.32.104.4 2>&1)
    [[ "$match_output" == *"match rules."* ]] || {
        printf 'WeChat routing test failed: packaged rule set misses a dedicated WeChat IP\n' >&2
        exit 1
    }
    non_match_output=$(sing-box rule-set match -f binary "$WECHAT_RULE_FILE" 8.8.8.8 2>&1)
    [[ -z "$non_match_output" ]] || {
        printf 'WeChat routing test failed: packaged rule set captures unrelated public IPs\n' >&2
        exit 1
    }
fi
