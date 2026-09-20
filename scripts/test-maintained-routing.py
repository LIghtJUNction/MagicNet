#!/usr/bin/env python3
"""Check routing contracts and first matches against the actual upstream assets.

The structural mode needs no network/assets; --assets also executes sing-box's
rule-set matcher. The only service-domain exception is the audited WeChat DNS
projection; mixed domain/IP rule sets must remain routing-only.
"""

import functools
import ipaddress
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = Path(
    os.environ.get(
        "MAGICNET_ROUTING_CONFIG_DIR", ROOT / "src/MagicNet/.config/sing-box"
    )
)
config = json.loads((CONFIG_DIR / "config.json").read_text())
routes, dns = config["route"]["rules"], config["dns"]["rules"]
definitions = {entry["tag"]: entry for entry in config["route"]["rule_set"]}
assert len(definitions) == len(config["route"]["rule_set"])
outbounds = {entry["tag"]: entry for entry in config["outbounds"]}

# MagicSingBox projects only the domain component of the mixed Karing WeChat
# classifier into DNS. Keep this exception exact: broader Tencent domains, IP
# matchers, scoped/inverted rules and different resolvers must not pass it.
WECHAT_ROUTE_TAG = "karing-acl4ssr-wechat"
WECHAT_DNS_SUFFIXES = [
    "qlogo.cn",
    "qpic.cn",
    "servicewechat.com",
    "tenpay.com",
    "wechat.com",
    "wechatlegal.net",
    "wechatpay.com",
    "weixin.com",
    "weixin.qq.com",
    "weixinbridge.com",
    "weixinsxy.com",
    "wxapp.tc.qq.com",
]
WECHAT_DNS_RULE = {
    "domain_suffix": WECHAT_DNS_SUFFIXES,
    "server": "bootstrap-local-dns",
}
assert dns.count(WECHAT_DNS_RULE) == 1, "expected one exact WeChat DNS domain projection"


def values(value):
    return value if isinstance(value, list) else [value]


def index(tag):
    return next(i for i, rule in enumerate(routes) if tag in rule.get("rule_set", []))


assert all(
    WECHAT_ROUTE_TAG not in values(rule.get("rule_set", [])) for rule in dns
), "the mixed WeChat domain/IP rule set must not be used in DNS"

for rule in routes + dns:
    for tag in rule.get("rule_set", []):
        assert tag in definitions, tag
    assert "domain_keyword" not in rule, (
        "broad hand-maintained keyword routing returned"
    )
    if "domain_suffix" in rule and rule != WECHAT_DNS_RULE:
        assert set(rule["domain_suffix"]) <= {
            "local",
            "home.arpa",
            "lan",
            "tailscale.net",
            "ts.net",
            "cn",
            "中国",
            "公司",
            "网络",
        }
    if "ip_cidr" in rule:
        assert rule.get("outbound") in ("lan", "block"), (
            "service IP lists belong upstream"
        )
    if rule.get("outbound"):
        assert rule["outbound"] in outbounds

for service in ("google", "youtube", "github", "discord", "netflix", "spotify", "twitter", "whatsapp", "telegram"):
    assert outbounds[service + "-proxy"]["default"] == "proxy"
    assert index("meta-" + service) < index("lyc-geosite-cn")
assert index("meta-google-play") < index("lyc-geosite-ads")
assert index("meta-google-gemini") < index("meta-google")
assert index("meta-youtube") < index("meta-google")
assert index("meta-discord") < index("meta-category-communication")
assert index("meta-icloud") < index("meta-apple")
assert index("meta-bing") < index("meta-microsoft")
assert index("meta-category-game-platforms-download") < index("meta-category-games-!cn")
assert index("meta-openai") < index("meta-category-ai-!cn")
assert index("meta-category-social-media-!cn") < index("lyc-geoip-cn")
assert index("sukka-chatgpt-voice") < index("lyc-geoip-cn")
assert not any(
    rule.get("outbound") == "cn-direct" and "package_name" in rule for rule in routes
)
voice = [r for r in routes if "sukka-chatgpt-voice" in r.get("rule_set", [])]
assert {(r["network"], r["port"], r["outbound"]) for r in voice} == {
    ("udp", 3478, "ai-chatgpt"),
    ("tcp", 443, "ai-chatgpt"),
}
assert outbounds["ad-block"]["default"] == "block"
for tag in (
    "lan",
    "cn-direct",
    "download-direct",
    "icloud",
    "apple-cn",
    "microsoft-cn",
):
    assert outbounds[tag]["default"] == "direct", tag
for tag in (
    "proxy-rule",
    "media-proxy",
    "game-proxy",
    "social-proxy",
    "telegram-proxy",
):
    assert outbounds[tag]["default"] == "proxy", tag
for tag in ("ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude", "ai-proxy"):
    assert outbounds[tag]["default"] != "direct", tag

# Every domain classifier has the same match conditions and relative order in
# DNS. Protocol/IP-only routing is deliberately not projected into DNS. The
# mixed WeChat classifier maps to its exact domain-only projection below.
expected = []
for rule in routes:
    if "outbound" not in rule or any(
        k in rule
        for k in ("network", "port", "package_name", "ip_cidr", "ip_is_private")
    ):
        continue
    if any("geoip" in definitions[t].get("path", "") for t in rule.get("rule_set", [])):
        continue
    expected.append({k: v for k, v in rule.items() if k != "outbound"})


def expand_rule_sets(rules):
    # Adjacent DNS classifiers with the same server may be coalesced. Compare
    # their ordered atomic matches, preserving all other match conditions.
    return [
        dict(rule, rule_set=[tag]) if "rule_set" in rule else rule
        for rule in rules
        for tag in rule.get("rule_set", [None])
    ]


expected_domains = [
    {"domain_suffix": WECHAT_DNS_SUFFIXES}
    if rule == {"rule_set": [WECHAT_ROUTE_TAG]}
    else rule
    for rule in expand_rule_sets(expected)
]
assert expected_domains == expand_rule_sets(
    [{k: v for k, v in r.items() if k != "server"} for r in dns]
), "DNS domain classifiers must retain routing order and the WeChat projection"

if "--assets" not in sys.argv:
    print("Maintained routing structural contracts passed")
    sys.exit(0)


@functools.cache
def set_matches(tag, target):
    if not target:
        return False
    definition = definitions[tag]
    path = CONFIG_DIR / definition["path"]
    assert path.is_file(), str(path)
    result = subprocess.run(
        [
            "sing-box",
            "rule-set",
            "match",
            "-f",
            definition["format"],
            str(path),
            target,
        ],
        capture_output=True,
        text=True,
        timeout=15,
        check=True,
    )
    return bool(result.stdout.strip() or result.stderr.strip())


def matches(
    rule,
    domain="",
    address="203.0.113.99",
    network="tcp",
    port=443,
    package="",
    mode="Rule",
):
    if "clash_mode" in rule and rule["clash_mode"] != mode:
        return False
    if "protocol" in rule or "action" in rule:
        return False
    if "network" in rule and network not in values(rule["network"]):
        return False
    if "port" in rule and port not in values(rule["port"]):
        return False
    if "package_name" in rule and package not in values(rule["package_name"]):
        return False
    if "domain" in rule and domain not in values(rule["domain"]):
        return False
    if "domain_suffix" in rule and not any(
        domain == s or domain.endswith("." + s) for s in values(rule["domain_suffix"])
    ):
        return False
    if "ip_cidr" in rule and not any(
        ipaddress.ip_address(address) in ipaddress.ip_network(c)
        for c in values(rule["ip_cidr"])
    ):
        return False
    if rule.get("ip_is_private") and not any(
        ipaddress.ip_address(address) in ipaddress.ip_network(c)
        for c in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7")
    ):
        return False
    if "rule_set" in rule and not any(
        set_matches(t, domain) or set_matches(t, address) for t in rule["rule_set"]
    ):
        return False
    return True


def first(rules, field, fallback, **flow):
    return next(
        (r[field] for r in rules if field in r and matches(r, **flow)), fallback
    )


cases = [
    ("play.google.com", "google-proxy", "doh-google"),
    ("play.googleapis.com", "google-proxy", "doh-google"),
    ("play-fe.googleapis.com", "google-proxy", "doh-google"),
    ("play-lh.googleusercontent.com", "google-proxy", "doh-google"),
    ("redirector.c.play.google.com", "google-proxy", "doh-google"),
    ("accounts.google.com", "google-proxy", "doh-google"),
    ("android.clients.google.com", "google-proxy", "doh-google"),
    ("oauth2.googleapis.com", "google-proxy", "doh-google"),
    ("mtalk.google.com", "google-proxy", "doh-google"),

    ("router.lan", "lan", "bootstrap-local-dns"),
    ("host.ts.net", "lan", "bootstrap-local-dns"),
    ("mmbiz.qpic.cn", "cn-direct", "bootstrap-local-dns"),
    ("weixin.qq.com", "cn-direct", "bootstrap-local-dns"),
    ("wechat.com", "cn-direct", "bootstrap-local-dns"),
    ("www.wechat.com", "cn-direct", "bootstrap-local-dns"),
    ("servicewechat.com", "cn-direct", "bootstrap-local-dns"),
    ("baidu.com", "cn-direct", "bootstrap-local-dns"),
    ("doubleclick.net", "ad-block", "doh-cloudflare"),
    ("www.icloud.com", "icloud", "bootstrap-local-dns"),
    ("www.apple.com", "apple-cn", "bootstrap-local-dns"),
    ("www.bing.com", "bing", "doh-google"),
    ("chatgpt.com", "ai-chatgpt", "doh-google"),
    ("api.openai.com", "ai-chatgpt", "doh-google"),
    ("gemini.google.com", "ai-gemini", "doh-google"),
    ("grok.com", "ai-grok", "doh-google"),
    ("claude.ai", "ai-claude", "doh-google"),
    ("github.com", "github-proxy", "doh-google"),
    ("youtube.com", "youtube-proxy", "doh-google"),
    ("steamcommunity.com", "game-proxy", "doh-google"),
    ("cache10-fra1.steamcontent.com", "download-direct", "bootstrap-local-dns"),
    ("discord.com", "discord-proxy", "doh-google"),
    ("www.google.com", "google-proxy", "doh-google"),
    ("mail.google.com", "google-proxy", "doh-google"),
    ("x.com", "twitter-proxy", "doh-google"),
    ("web.whatsapp.com", "whatsapp-proxy", "doh-google"),
    ("netflix.com", "netflix-proxy", "doh-google"),
    ("spotify.com", "spotify-proxy", "doh-google"),
    ("t.me", "telegram-proxy", "doh-google"),
    ("www.speedtest.net", "network-test", "doh-google"),
]
for domain, outbound, server in cases:
    for network in ("tcp", "udp"):
        flow = dict(domain=domain, network=network)
        actual = first(routes, "outbound", config["route"]["final"], **flow)
        resolver = first(dns, "server", config["dns"]["final"], **flow)
        assert (actual, resolver) == (outbound, server), (
            domain,
            network,
            actual,
            resolver,
            outbound,
            server,
        )

# These names must not be captured simply because they contain old keywords.
for domain in (
    "analytics.example.invalid",
    "tracker.example.invalid",
    "mygithub.example.invalid",
):
    assert (
        first(routes, "outbound", config["route"]["final"], domain=domain)
        == config["route"]["final"]
    ), domain
for domain in ("chatgpt.com", "doubleclick.net", "baidu.com"):
    assert first(routes, "outbound", "", domain=domain, mode="Direct") == "direct"
    assert first(routes, "outbound", "", domain=domain, mode="Global") == "select"
# Known foreign services keep their route even on an address classified as CN.
for domain, outbound in [("chatgpt.com", "ai-chatgpt"), ("www.bing.com", "bing")]:
    assert (
        first(routes, "outbound", "", domain=domain, address="114.114.114.114")
        == outbound
    )
# Native client hints do not take priority over an explicit mode choice.
assert (
    first(routes, "outbound", "", domain="", package="com.openai.chatgpt")
    == "ai-chatgpt"
)
assert (
    first(
        routes, "outbound", "", domain="", package="com.openai.chatgpt", mode="Direct"
    )
    == "direct"
)
voice_source = json.loads(
    (CONFIG_DIR / definitions["sukka-chatgpt-voice"]["path"]).read_text()
)
voice_ip = str(
    ipaddress.ip_network(voice_source["rules"][0]["ip_cidr"][0]).network_address
)
for network, port in [("udp", 3478), ("tcp", 443)]:
    assert (
        first(routes, "outbound", "", address=voice_ip, network=network, port=port)
        == "ai-chatgpt"
    )
for network, port in [("udp", 443), ("tcp", 3478)]:
    assert not any(
        matches(r, address=voice_ip, network=network, port=port) for r in voice
    )
print(
    f"Maintained routing: {len(cases) * 2} TCP/UDP + DNS cases, mode overrides, keyword negatives and voice scope passed"
)
