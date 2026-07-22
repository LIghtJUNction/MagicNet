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
import ipaddress
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
wechat_dns = {"package_name": ["com.tencent.mm"], "server": "bootstrap-local-dns"}
fakeip_guard = {
    "ip_cidr": ["127.0.0.1/32", "::1/128", "198.18.0.0/16", "28.0.0.0/8"],
    "outbound": "block",
}


def exact_indexes(rules, expected):
    return [index for index, rule in enumerate(rules) if rule == expected]


wechat_route_indexes = exact_indexes(route_rules, wechat_route)
guard_indexes = exact_indexes(route_rules, fakeip_guard)
wechat_dns_indexes = exact_indexes(dns_rules, wechat_dns)
if len(wechat_route_indexes) != 1:
    raise AssertionError(f"expected one exact WeChat route, got {wechat_route_indexes}")
if len(guard_indexes) != 1:
    raise AssertionError(f"expected one exact FakeIP guard, got {guard_indexes}")
if len(wechat_dns_indexes) != 1:
    raise AssertionError(f"expected one exact WeChat DNS rule, got {wechat_dns_indexes}")
if wechat_route_indexes[0] >= guard_indexes[0]:
    raise AssertionError("WeChat media route must precede the FakeIP guard")

for domain in wechat_domains:
    owners = [
        index
        for index, rule in enumerate(route_rules)
        if rule.get("outbound") == "cn-direct"
        and domain in (rule.get("domain_suffix") or [])
    ]
    if owners != wechat_route_indexes:
        raise AssertionError(f"{domain} has non-canonical cn-direct owners: {owners}")

global_dns_indexes = [
    index
    for index, rule in enumerate(dns_rules)
    if rule.get("clash_mode") == "Global"
]
if global_dns_indexes and wechat_dns_indexes[0] <= global_dns_indexes[-1]:
    raise AssertionError("Global DNS mode must retain priority over the WeChat local resolver")


def domain_matches(rule, domain):
    return any(
        domain == suffix or domain.endswith("." + suffix)
        for suffix in rule.get("domain_suffix", [])
    )


def ip_matches(rule, destination_ip):
    cidrs = rule.get("ip_cidr")
    if not cidrs:
        return True
    address = ipaddress.ip_address(destination_ip)
    return any(address in ipaddress.ip_network(cidr) for cidr in cidrs)


def package_matches(rule, package_name):
    packages = rule.get("package_name")
    return packages is None or package_name in packages


def first_media_outbound(domain, destination_ip, package_name):
    for index, rule in enumerate(route_rules):
        if "outbound" not in rule:
            continue
        if rule.get("clash_mode") is not None:
            continue
        if rule.get("protocol") not in (None, "tls"):
            continue
        if rule.get("network") not in (None, "tcp"):
            continue
        ports = rule.get("port")
        if ports is not None and 443 not in (ports if isinstance(ports, list) else [ports]):
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
    raise AssertionError("WeChat media flow did not match any modeled route")


index, outbound = first_media_outbound("upload.qpic.cn", "198.18.1.1", "com.tencent.mm")
if (index, outbound) != (wechat_route_indexes[0], "cn-direct"):
    raise AssertionError(
        f"cached-FakeIP WeChat media flow matched index={index} outbound={outbound}"
    )

print("WeChat routing policy test passed")
PY
