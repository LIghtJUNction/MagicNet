#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${MAGICNET_ROUTING_CONFIG_DIR:-$ROOT/src/MagicNet/.config/sing-box}"
CONFIG_FILE="$CONFIG_DIR/config.json"

fail() {
    printf 'default routing policy test failed: %s\n' "$*" >&2
    exit 1
}

[[ "$CONFIG_DIR" == /* ]] || fail "routing config directory must be absolute"
[[ -f "$CONFIG_FILE" ]] || fail "routing config is missing: $CONFIG_FILE"

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sing-box >/dev/null 2>&1 || fail "sing-box is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

jq -e '
  [
    "192.168.0.0/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "224.0.0.0/4",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8",
    "fd7a:115c:a1e0::/48"
  ] as $expected
  | [.inbounds[] | select(.type == "tun" and .tag == "tun-in")] as $managed_tuns
  | ($managed_tuns | length) == 1
    and $managed_tuns[0].route_exclude_address == $expected
' "$CONFIG_FILE" >/dev/null || fail "base TUN exclusions are not canonical or exactly ordered"

jq -e '
  .dns.strategy == "prefer_ipv4"
    and ([.inbounds[] | select(
      .type == "tun"
      and .tag == "tun-in"
      and .stack == "mixed"
      and .mtu == 1400
      and .udp_timeout == "5m"
      and (.exclude_uid | index(0)) != null
      and (.address | any(contains(":")))
    )] | length) == 1
    and ([.route.rules[] | select(
      . == {"ip_version": 6, "action": "reject", "method": "default", "no_drop": true}
      or . == {"ip_version": 6, "action": "reject", "no_drop": true}
      or . == {"ip_version": 6, "outbound": "block"}
    )] | length) == 0
' "$CONFIG_FILE" >/dev/null || fail "base UDP/IPv6 policy is not canonical dual stack"

jq -e '
  .dns.cache_capacity == 4096
    and (.dns.disable_cache? != true)
    and (.dns.independent_cache? != true)
' "$CONFIG_FILE" >/dev/null || fail "DNS cache must be enabled, shared, and sized to 4096 entries"

jq -e '
  {
    type: "https",
    tag: "doh-cloudflare",
    detour: "proxy",
    server: "1.1.1.1",
    server_port: 443,
    path: "/dns-query",
    tls: {enabled: true, server_name: "cloudflare-dns.com"}
  } as $canonical
  | ([.dns.servers[] | select(.tag? == "default-remote-dns")] | length) == 0
    and ([.dns.servers[] | select(. == $canonical)] | length) == 1
    and ([.dns.servers[]
      | select(.type? == "https"
          and .server? == "1.1.1.1"
          and .server_port? == 443
          and .path? == "/dns-query"
          and .detour? == "proxy"
          and .tls.server_name? == "cloudflare-dns.com")]
      | length) == 1
' "$CONFIG_FILE" >/dev/null ||
    fail "DNS servers must contain exactly one canonical Cloudflare HTTPS endpoint and no legacy tag"

package_cn_direct_count=$(jq '[.route.rules[] | select(.outbound? == "cn-direct" and .package_name? != null)] | length' "$CONFIG_FILE")
[[ "$package_cn_direct_count" -eq 0 ]] ||
    fail "cn-direct must be selected by destination/rule-set, not package catalog"

multi_package_dns_count=$(jq '[.dns.rules[] | select((.package_name? | type) == "array" and (.package_name | length) > 1)] | length' "$CONFIG_FILE")
[[ "$multi_package_dns_count" -eq 0 ]] ||
    fail "DNS policy must not contain a hardcoded application catalog"

dns_package_rule_count=$(jq '[.dns.rules[] | select(has("package_name"))] | length' "$CONFIG_FILE")
[[ "$dns_package_rule_count" -eq 0 ]] ||
    fail "DNS policy must not contain application package selectors"

fakeip_server_count=$(jq '[.dns.servers[] | select(.type == "fakeip" or .tag == "fakeip")] | length' "$CONFIG_FILE")
[[ "$fakeip_server_count" -eq 0 ]] ||
    fail "default DNS policy must not enable an unconsumed FakeIP server"

fakeip_rule_count=$(jq '[.dns.rules[] | select(.server == "fakeip")] | length' "$CONFIG_FILE")
[[ "$fakeip_rule_count" -eq 0 ]] ||
    fail "default DNS policy must return real addresses instead of FakeIP answers"

store_fakeip=$(jq -r '.experimental.cache_file.store_fakeip // false' "$CONFIG_FILE")
[[ "$store_fakeip" == "false" ]] ||
    fail "default DNS policy must not persist stale FakeIP mappings"

fakeip_blackhole_count=$(jq '[
    .route.rules[]
    | select(.outbound == "block")
    | select(any(.ip_cidr[]?; . == "198.18.0.0/16" or . == "28.0.0.0/8"))
] | length' "$CONFIG_FILE")
[[ "$fakeip_blackhole_count" -eq 0 ]] ||
    fail "routing policy must not blackhole benchmark or public address space as a FakeIP guard"

first_matching_value() {
    local rules_path="$1"
    local value_key="$2"
    local domain="$3"
    jq -er --arg rules_path "$rules_path" --arg value_key "$value_key" --arg domain "$domain" '
      def values($value):
        if $value == null then []
        elif ($value | type) == "array" then $value
        else [$value]
        end;
      def domain_matches($rule; $name):
        ((values($rule.domain?) | index($name)) != null)
        or any(values($rule.domain_suffix?)[]; . as $suffix
          | $name == $suffix or ($name | endswith("." + $suffix)))
        or any(values($rule.domain_keyword?)[]; . as $keyword
          | $name | contains($keyword));
      (if $rules_path == "route" then .route.rules else .dns.rules end) as $rules
      | ([$rules[] | select(domain_matches(.; $domain))][0] // null) as $rule
      | if $rule == null then error("no matching rule")
        elif ($rule | has($value_key)) and $rule[$value_key] != null then $rule[$value_key]
        else error("first matching rule is missing " + $value_key)
        end
    ' "$CONFIG_FILE"
}

helper_fixture=$(mktemp)
trap 'rm -f "$helper_fixture"' EXIT
cat >"$helper_fixture" <<'JSON'
{
  "route": {
    "rules": [
      {"domain": "exact.example", "outbound": "exact"},
      {"domain_suffix": "scalar.example", "outbound": "scalar-suffix"},
      {"domain_keyword": "keyword", "outbound": "scalar-keyword"},
      {"domain_suffix": "missing.example"},
      {"domain_suffix": "missing.example", "outbound": "must-not-skip"}
    ]
  }
}
JSON
original_config_file="$CONFIG_FILE"
CONFIG_FILE="$helper_fixture"
[[ "$(first_matching_value route outbound exact.example)" == "exact" ]] ||
    fail "first-match helper rejected scalar domain"
if first_matching_value route outbound xact.example >/dev/null 2>&1; then
    fail "first-match helper treated scalar domain as a substring"
fi
[[ "$(first_matching_value route outbound www.scalar.example)" == "scalar-suffix" ]] ||
    fail "first-match helper rejected scalar domain_suffix"
[[ "$(first_matching_value route outbound has-keyword.example)" == "scalar-keyword" ]] ||
    fail "first-match helper rejected scalar domain_keyword"
if first_matching_value route outbound missing.example >/dev/null 2>&1; then
    fail "first-match helper skipped a matching rule with no outbound"
fi
CONFIG_FILE="$original_config_file"
rm -f "$helper_fixture"
helper_fixture=
trap - EXIT
unset original_config_file

python3 - "$CONFIG_FILE" "$CONFIG_DIR" <<'PY'
import functools
import ipaddress
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

config_path, config_dir = sys.argv[1:]
with open(config_path, encoding="utf-8") as handle:
    config = json.load(handle)

rules = config["route"]["rules"]
dns_rules = config["dns"]["rules"]
rule_set_definitions = config["route"]["rule_set"]
outbound_list = config["outbounds"]
proxy_dns_tags = {
    server["tag"]
    for server in config["dns"]["servers"]
    if server.get("detour") == "proxy"
}
apple_icloud_dns_rule = {
    "domain_suffix": ["apple.com", "icloud.com", "icloud-content.com", "me.com"],
    "server": "bootstrap-local-dns",
}
direct_mode_dns_rule = {"clash_mode": "Direct", "server": "bootstrap-local-dns"}
global_mode_dns_rule = {"clash_mode": "Global", "server": "doh-cloudflare"}
wechat_media_dns_rule = {
    "domain_suffix": [
        "qq.com", "weixin.qq.com", "wechat.com", "wechatapp.com", "wechatpay.cn",
        "tenpay.com", "tencent.com", "tencent-cloud.com", "myqcloud.com", "qcloud.com",
        "gtimg.com", "idqqimg.com", "qpic.cn", "qlogo.cn", "qmail.com", "smtcdns.com",
        "servicewechat.com", "weixinbridge.com", "weixinsxy.com", "wx.gtimg.com", "wx.qq.com",
    ],
    "server": "bootstrap-local-dns",
}
domestic_connectivity_dns_rule = {
    "domain_suffix": ["connect.rom.miui.com", "connectivitycheck.platform.hicloud.com"],
    "server": "bootstrap-local-dns",
}
msft_network_test_suffixes = ["msftconnecttest.com", "msftncsi.com"]
foreign_network_test_suffixes = [
    "connectivitycheck.gstatic.com", "connectivitycheck.android.com",
    "clients3.google.com", "www.gstatic.com", "gstatic.com", "gvt1.com", "gvt2.com",
    "captive.apple.com", "cp.cloudflare.com", "speed.cloudflare.com", "speedtest.net",
    "ooklaserver.net", "speedtestcdn.com", "fast.com", "nperf.com", "nperf.net",
    "testmy.net", "browserscan.net", "measurementlab.net", "speed.measurementlab.net",
    "speedof.me", "speedcheck.org",
]
foreign_network_test_dns_rule = {
    "domain_suffix": msft_network_test_suffixes + foreign_network_test_suffixes,
    "server": "doh-google",
}
dedicated_leak_test_suffixes = [
    "bash.ws", "browserscan.net", "browserleaks.com", "browserleaks.org", "dns.sb",
    "dnscheck.tools", "dnschecker.org", "doileak.com", "dns-oarc.net", "dnsleak.com",
    "dnsleaktest.com", "dnsleaktest.org", "dnslytics.com", "ipleak.net", "ipleak.org",
    "ip-api.com", "perfect-privacy.com", "test.nextdns.io", "surfsharkdns.com",
    "whatsmydnsserver.com", "whoer.net",
]
dedicated_leak_test_dns_rule = {
    "domain_suffix": dedicated_leak_test_suffixes,
    "server": "doh-cloudflare",
}
network_test_leak_overlap = set(dedicated_leak_test_suffixes) & set(
    foreign_network_test_dns_rule["domain_suffix"]
)
if network_test_leak_overlap != {"browserscan.net"}:
    raise AssertionError(
        "dedicated leak-test and merged network-test DNS suffixes must overlap only at "
        f"browserscan.net: {sorted(network_test_leak_overlap)}"
    )
legacy_early_local_msft_dns_rule = {
    "domain_suffix": msft_network_test_suffixes,
    "server": "bootstrap-local-dns",
}
if legacy_early_local_msft_dns_rule in dns_rules:
    raise AssertionError("legacy early local Microsoft connectivity DNS rule must be absent")
msft_network_test_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == {"domain_suffix": msft_network_test_suffixes, "outbound": "network-test"}
]
foreign_network_test_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == {"domain_suffix": foreign_network_test_suffixes, "outbound": "network-test"}
]
if len(msft_network_test_routes) != 1 or len(foreign_network_test_routes) != 1:
    raise AssertionError("network-test suffix routes must remain unique")
if foreign_network_test_dns_rule["domain_suffix"] != (
    msft_network_test_routes[0][1]["domain_suffix"] + foreign_network_test_routes[0][1]["domain_suffix"]
):
    raise AssertionError("foreign network-test DNS suffixes must equal route rules 27 + 29")
cn_bing_dns_rule = {
    "domain_suffix": ["cn.bing.com"],
    "server": "bootstrap-local-dns",
}
global_bing_dns_rule = {
    "domain_suffix": [
        "bing.com", "bingapis.com", "bing.net", "msn.com", "login.live.com",
        "account.live.com", "edgeservices.bing.com", "assets.msn.com",
        "c.bing.com", "r.bing.com", "www.bing.com",
    ],
    "server": "doh-google",
}
legacy_remote_microsoft_dns_rule = {
    "domain_suffix": ["login.live.com", "account.live.com", "msn.com"],
    "server": "doh-google",
}
if legacy_remote_microsoft_dns_rule in dns_rules:
    raise AssertionError("legacy three-domain Microsoft/Bing DNS rule must be absent")
local_microsoft_dns_rule = {
    "domain_suffix": [
        "microsoft.com", "windows.com", "windowsupdate.com", "msftauth.net",
        "msauth.net", "office.com", "office365.com", "live.com",
        "steamserver.net", "steamcontent.com", "steamusercontent.com",
        "akamaihd.net", "hwcdn.net",
    ],
    "server": "bootstrap-local-dns",
}
x_social_dns_rule = {
    "domain_suffix": ["twitter.com", "x.com", "twimg.com"],
    "server": "doh-google",
}
ad_suffix_dns_rule = {
    "domain_suffix": [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "adservice.google.com", "adsystem.com", "adnxs.com", "scorecardresearch.com",
        "umeng.com", "umengcloud.com",
    ],
    "server": "doh-cloudflare",
}
ad_keyword_dns_rule = {
    "domain_keyword": ["adservice", "analytics", "tracking", "tracker"],
    "server": "doh-cloudflare",
}
ad_rule_set_dns_rule = {
    "rule_set": [
        "lyc-geosite-ads", "hagezi-light", "hagezi-normal",
        "hagezi-anti-piracy", "karing-acl4ssr-banad",
    ],
    "server": "doh-cloudflare",
}
ordered_dns_policy_indexes = []
for expected_rule in (
    direct_mode_dns_rule,
    global_mode_dns_rule,
    wechat_media_dns_rule,
    domestic_connectivity_dns_rule,
    foreign_network_test_dns_rule,
    apple_icloud_dns_rule,
    cn_bing_dns_rule,
    global_bing_dns_rule,
    local_microsoft_dns_rule,
):
    matches = [index for index, rule in enumerate(dns_rules) if rule == expected_rule]
    if len(matches) != 1:
        raise AssertionError(f"expected one exact ordered DNS policy rule: indexes={matches}")
    ordered_dns_policy_indexes.append(matches[0])
if not all(
    right == left + 1
    for left, right in zip(ordered_dns_policy_indexes, ordered_dns_policy_indexes[1:])
):
    raise AssertionError(
        "required DNS order is Direct -> Global -> WeChat media -> domestic connectivity "
        "-> foreign network-test -> Apple -> cn Bing -> global Bing -> local Microsoft: "
        f"indexes={ordered_dns_policy_indexes}"
    )
(
    direct_mode_dns_index,
    global_mode_dns_index,
    wechat_media_dns_index,
    domestic_connectivity_dns_index,
    foreign_network_test_dns_index,
    apple_icloud_dns_index,
    cn_bing_dns_index,
    global_bing_dns_index,
    local_microsoft_dns_index,
) = ordered_dns_policy_indexes
def exact_dns_index(expected_rule):
    matches = [index for index, rule in enumerate(dns_rules) if rule == expected_rule]
    if len(matches) != 1:
        raise AssertionError(f"expected one exact DNS rule: indexes={matches}")
    return matches[0]


ad_suffix_dns_index = exact_dns_index(ad_suffix_dns_rule)
ad_keyword_dns_index = exact_dns_index(ad_keyword_dns_rule)
ad_rule_set_dns_index = exact_dns_index(ad_rule_set_dns_rule)
x_social_dns_index = exact_dns_index(x_social_dns_rule)
cn_dns_rule_indexes = [
    index for index, rule in enumerate(dns_rules)
    if "lyc-geosite-cn" in (
        rule.get("rule_set")
        if isinstance(rule.get("rule_set"), list)
        else [rule.get("rule_set")]
    )
]
if not cn_dns_rule_indexes or not local_microsoft_dns_index < x_social_dns_index < min(cn_dns_rule_indexes):
    raise AssertionError(
        "explicit X/Twitter DNS rule must follow the canonical explicit DNS block and precede "
        "the domestic China rule-set classifier: "
        f"local_index={local_microsoft_dns_index} x_index={x_social_dns_index} "
        f"cn_rule_set_index={min(cn_dns_rule_indexes) if cn_dns_rule_indexes else None}"
    )
dedicated_leak_test_dns_indexes = [
    index for index, rule in enumerate(dns_rules) if rule == dedicated_leak_test_dns_rule
]
if len(dedicated_leak_test_dns_indexes) != 1:
    raise AssertionError(
        "expected one exact dedicated leak-test DNS rule: "
        f"indexes={dedicated_leak_test_dns_indexes}"
    )
dedicated_leak_test_dns_index = dedicated_leak_test_dns_indexes[0]
if not dedicated_leak_test_dns_index < foreign_network_test_dns_index:
    raise AssertionError("dedicated leak-test DNS rule must precede merged network-test DNS")
default_mode = config.get("experimental", {}).get("clash_api", {}).get("default_mode", "Rule")
media_targets = ("youtube.com", "ytimg.com", "googlevideo.com")
required_media_sets = {"yuu-geosite-stream-global", "karing-acl4ssr-proxy-media"}
download_suffixes = [
    "steamserver.net",
    "steamcontent.com",
    "steamusercontent.com",
    "akamaihd.net",
    "hwcdn.net",
    "windowsupdate.com",
    "download.windowsupdate.com",
]
download_expectations = {
    "steamserver.net": "download-direct",
    "steamcontent.com": "download-direct",
    "steamusercontent.com": "download-direct",
    "akamaihd.net": "download-direct",
    "hwcdn.net": "download-direct",
    "windowsupdate.com": "download-direct",
    "download.windowsupdate.com": "download-direct",
}
expected_download_selector = {
    "type": "selector",
    "tag": "download-direct",
    "outbounds": ["direct", "proxy", "block"],
    "default": "direct",
}
game_domain_suffixes = [
    "steamcommunity.com", "steampowered.com", "steamstatic.com", "epicgames.com",
    "epicgames.dev", "unrealengine.com", "paragon.com", "playstation.com",
    "playstation.net", "playstationnetwork.com", "sonyentertainmentnetwork.com",
    "xboxlive.com", "nintendo.net",
]
private_dns_rule = {
    "rule_set": ["lyc-geosite-private", "lyc-geoip-private"],
    "server": "bootstrap-local-dns",
}
mmstat_local_dns_rule = {
    "domain_suffix": ["mmstat.com"],
    "server": "bootstrap-local-dns",
}
game_dns_rule = {
    "domain_suffix": game_domain_suffixes,
    "server": "doh-cloudflare",
}
foreign_priority_domains = (
    "acm.org",
    "acs.org",
    "aiaa.org",
    "amd.com",
    "annualreviews.org",
    "asm.org",
    "asme.org",
    "astm.org",
    "bmj.com",
    "cambridge.org",
    "cdn.jetbrains.com",
    "ieee.org",
    "nature.com",
    "sciencedirect.com",
    "springer.com",
    "wiley.com",
)
additional_foreign_priority_domains = (
    "ams.org",
    "aps.org",
    "ascelibrary.org",
    "cas.org",
    "clarivate.com",
    "ebscohost.com",
    "emerald.com",
    "engineeringvillage.com",
    "icevirtuallibrary.com",
    "iop.org",
    "jamanetwork.com",
    "jstor.org",
    "karger.com",
    "oecd-ilibrary.org",
    "osapublishing.org",
    "oup.com",
    "ovid.com",
    "oxfordartonline.com",
    "oxfordbibliographies.com",
    "oxfordmusiconline.com",
    "pnas.org",
    "proquest.com",
    "rsc.org",
    "sagepub.com",
    "scopus.com",
    "siam.org",
    "spiedigitallibrary.org",
    "springerlink.com",
    "tandfonline.com",
    "udacity.com",
    "un.org",
    "webofknowledge.com",
    "westlaw.com",
    "worldscientific.com",
    "oracle.com",
)
foreign_priority_domains += additional_foreign_priority_domains
legacy_foreign_priority_domains = foreign_priority_domains
karing_false_positive_domains = (
    "sony.com",
    "teamviewer.com",
    "abercrombie.com",
    "hollisterco.com",
    "weather.com",
)
foreign_priority_domains += karing_false_positive_domains
foreign_priority_dns_rule = {
    "domain_suffix": list(foreign_priority_domains),
    "server": "doh-google",
}
canonical_cn_dns_rule = {
    "rule_set": [
        "lyc-geosite-cn", "lyc-geosite-geolocation-cn", "lyc-geoip-cn",
        "metacubex-geoip-cn", "ddch-direct",
        "karing-acl4ssr-china-domain", "karing-acl4ssr-china-ip", "yuu-geosite-pcdn-cn",
    ],
    "server": "bootstrap-local-dns",
}
generic_foreign_dns_rule = {
    "rule_set": [
        "lyc-geosite-ai", "yuu-geosite-ai", "karing-acl4ssr-ai", "lyc-geosite-gfw",
        "ddch-gfw", "lyc-geosite-proxy", "metacubex-geosite-geolocation-not-cn",
        "ddch-proxy", "karing-acl4ssr-proxy-lite", "karing-acl4ssr-proxy-gfwlist",
    ],
    "server": "doh-google",
}
specialized_foreign_dns_rule = {
    "rule_set": [
        "lyc-geosite-dev", "lyc-geosite-media", "yuu-geosite-stream-global",
        "karing-acl4ssr-proxy-media", "lyc-geosite-games", "lyc-geosite-social",
        "lyc-geosite-telegram", "lyc-geoip-telegram",
    ],
    "server": "doh-cloudflare",
}
specialized_fallback_specs = [
    (
        ["challenges.cloudflare.com", "turnstile.cloudflare.com", "perplexity.ai", "deepmind.com"],
        "ai-proxy",
    ),
    (
        [
            "github.com", "githubusercontent.com", "githubassets.com", "githubcopilot.com",
            "gitlab.com", "docker.com", "docker.io", "dockerhub.com", "npmjs.com",
            "npmjs.org", "pypi.org", "pythonhosted.org", "rubygems.org", "crates.io",
            "rust-lang.org", "golang.org", "go.dev",
        ],
        "dev-proxy",
    ),
    (
        [
            "youtube.com", "ytimg.com", "googlevideo.com", "netflix.com", "nflxvideo.net",
            "disneyplus.com", "hulu.com", "spotify.com", "twitch.tv",
        ],
        "media-proxy",
    ),
    (
        [
            "facebook.com", "fbcdn.net", "instagram.com", "threads.net", "whatsapp.com",
            "twitter.com", "x.com", "twimg.com", "reddit.com", "discord.com", "discord.gg",
            "discordapp.com",
        ],
        "social-proxy",
    ),
    (["telegram.org", "t.me", "tdesktop.com"], "telegram-proxy"),
]
affected_specialized_expectations = {
    "challenges.cloudflare.com": "ai-proxy",
    "turnstile.cloudflare.com": "ai-proxy",
    "dockerhub.com": "dev-proxy",
    "whatsapp.com": "social-proxy",
    "reddit.com": "social-proxy",
    "discord.com": "social-proxy",
    "discord.gg": "social-proxy",
    "discordapp.com": "social-proxy",
    "githubcopilot.com": "ai-proxy",
}
fail_closed_ai_tags = ("ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude", "ai-proxy")
telegram_ip_cidrs = [
    "91.108.0.0/16", "91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22",
    "91.108.16.0/22", "91.108.56.0/22", "149.154.160.0/20", "2001:67c:4e8::/48",
    "2001:b28:f23c::/47", "2001:b28:f23f::/48",
]
final_foreign_keywords = [
    "google", "youtube", "facebook", "instagram", "twitter", "x.com", "github",
    "telegram", "wikipedia", "reddit", "discord",
]
expected_dns_tail = [
    private_dns_rule,
    mmstat_local_dns_rule,
    ad_suffix_dns_rule,
    ad_keyword_dns_rule,
    ad_rule_set_dns_rule,
    game_dns_rule,
    foreign_priority_dns_rule,
    x_social_dns_rule,
    canonical_cn_dns_rule,
    generic_foreign_dns_rule,
    specialized_foreign_dns_rule,
]
dns_tail_start = next(
    (index for index, rule in enumerate(dns_rules) if rule == expected_dns_tail[0]),
    None,
)
if (
    dns_tail_start is None
    or dns_rules[dns_tail_start:dns_tail_start + len(expected_dns_tail)] != expected_dns_tail
    or dns_tail_start + len(expected_dns_tail) != len(dns_rules)
):
    raise AssertionError(
        "required DNS order is private < mmstat local < ad suffix < ad keyword < ad rule-set < game < "
        "foreign priority < explicit X/Twitter < canonical CN < generic foreign < specialized: "
        f"tail_start={dns_tail_start} tail="
        f"{dns_rules[dns_tail_start:] if dns_tail_start is not None else None}"
    )
for expected_rule in expected_dns_tail:
    matches = [index for index, rule in enumerate(dns_rules) if rule == expected_rule]
    if len(matches) != 1:
        raise AssertionError(
            f"canonical DNS tail rule must have one owner: {expected_rule} indexes={matches}"
        )
domestic_targets = (
    "speedtest.cn",
    "speedtest.mi.com",
    "mirrors.tuna.tsinghua.edu.cn",
    "connectivitycheck.baidu.com",
    "generate_204.miui.com",
    "captive.huawei.com",
    "nperf.cn",
    "ookla.cn",
    "speedtest.iqiyi.com",
    "connectivitycheck.suning.com",
    "nperf.douyu.com",
    "ookla.vip.com",
    "captive.ctrip.com",
)
domestic_srs_only_targets = {
    "speedtest.iqiyi.com",
    "connectivitycheck.suning.com",
    "nperf.douyu.com",
    "ookla.vip.com",
}
domestic_srs_probe_targets = domestic_srs_only_targets | {
    "captive.ctrip.com",
}
foreign_targets = (
    "speedtest.net",
    "connectivitycheck.gstatic.com",
    "api.nperf.com",
    "www.ookla.com",
)
network_test_keywords = ["connectivitycheck", "generate_204", "captive", "speedtest", "ookla", "nperf"]
network_test_suffixes = [
    "connectivitycheck.gstatic.com",
    "connectivitycheck.android.com",
    "clients3.google.com",
    "www.gstatic.com",
    "gstatic.com",
    "gvt1.com",
    "gvt2.com",
    "captive.apple.com",
    "cp.cloudflare.com",
    "speed.cloudflare.com",
    "speedtest.net",
    "ooklaserver.net",
    "speedtestcdn.com",
    "fast.com",
    "nperf.com",
    "nperf.net",
    "testmy.net",
    "browserscan.net",
    "measurementlab.net",
    "speed.measurementlab.net",
    "speedof.me",
    "speedcheck.org",
]
canonical_cn_rule_sets = {
    "lyc-geosite-cn",
    "lyc-geosite-geolocation-cn",
    "lyc-geoip-cn",
    "metacubex-geoip-cn",
    "ddch-direct",
    "karing-acl4ssr-china-domain",
    "karing-acl4ssr-china-ip",
}
canonical_cn_ip_rule = {
    "rule_set": ["lyc-geoip-cn", "metacubex-geoip-cn", "karing-acl4ssr-china-ip"],
    "outbound": "cn-direct",
}
canonical_cn_ip_routes = [
    (index, rule) for index, rule in enumerate(rules) if rule == canonical_cn_ip_rule
]
if len(canonical_cn_ip_routes) != 1:
    raise AssertionError(
        f"expected one early CN IP-only route before ad rule-sets: {canonical_cn_ip_routes}"
    )
canonical_cn_ip_index = canonical_cn_ip_routes[0][0]
invalid_destination_rule = {
    "ip_cidr": ["0.0.0.0/8"],
    "outbound": "block",
}
invalid_destination_routes = [
    (index, rule) for index, rule in enumerate(rules) if rule == invalid_destination_rule
]
if len(invalid_destination_routes) != 1:
    raise AssertionError(
        f"expected one reserved 0.0.0.0/8 fail-closed route: {invalid_destination_routes}"
    )
invalid_destination_index = invalid_destination_routes[0][0]
if not invalid_destination_index < canonical_cn_ip_index:
    raise AssertionError(
        "reserved 0.0.0.0/8 destinations must fail closed before CN IP routing: "
        f"invalid={invalid_destination_index} cn={canonical_cn_ip_index}"
    )
x_domain_rule = {
    "domain_suffix": ["twitter.com", "x.com", "twimg.com"],
    "outbound": "social-proxy",
}
x_domain_routes = [
    (index, rule) for index, rule in enumerate(rules) if rule == x_domain_rule
]
if len(x_domain_routes) != 1:
    raise AssertionError(f"expected one early X domain route: {x_domain_routes}")
x_domain_index = x_domain_routes[0][0]
if not x_domain_index < canonical_cn_ip_index:
    raise AssertionError(
        "X API/CDN domains must precede the canonical CN IP route so domain-sniffed "
        f"connections cannot fall back to direct: x={x_domain_index} cn={canonical_cn_ip_index}"
    )
ad_rule_set_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule.get("outbound") == "ad-block" and "rule_set" in rule
]
if len(ad_rule_set_routes) != 2:
    raise AssertionError(f"expected two ad rule-set routes, found {ad_rule_set_routes}")
if not canonical_cn_ip_index < ad_rule_set_routes[0][0]:
    raise AssertionError(
        "CN IP-only routing must precede ad IP rule-sets so domestic CDN IPs are not blocked"
    )
if set(canonical_cn_ip_rule["rule_set"]) & {"lyc-geosite-cn", "lyc-geosite-geolocation-cn", "ddch-direct"}:
    raise AssertionError("CN IP-only route must not include domain or mixed direct rule-sets")
cn_overlap_evidence_rule_sets = canonical_cn_rule_sets | {"metacubex-geosite-cn"}
generic_foreign_rule_sets = {
    "lyc-geosite-gfw",
    "ddch-gfw",
    "lyc-geosite-proxy",
    "metacubex-geosite-geolocation-not-cn",
    "ddch-proxy",
    "karing-acl4ssr-proxy-lite",
    "karing-acl4ssr-proxy-gfwlist",
}
retained_canonical_cn_rule_sets = canonical_cn_rule_sets
metacubex_false_positive_expectations = {
    "gandi.net": "proxy-rule",
    "java.com": "dev-proxy",
    "kaspersky-labs.com": "proxy-rule",
    "supercell.com": "game-proxy",
}
metacubex_false_positive_foreign_rule_sets = generic_foreign_rule_sets | {
    "lyc-geosite-dev",
    "lyc-geosite-games",
}
karing_false_positive_foreign_rule_sets = generic_foreign_rule_sets | {
    "lyc-geosite-dev",
    "lyc-geosite-media",
    "yuu-geosite-stream-global",
    "karing-acl4ssr-proxy-media",
    "lyc-geosite-games",
    "lyc-geosite-social",
    "lyc-geosite-telegram",
    "lyc-geoip-telegram",
}
foreign_priority_route_rule = {
    "domain_suffix": list(foreign_priority_domains),
    "outbound": "proxy-rule",
}
if (
    len(foreign_priority_domains) != 56
    or len(set(foreign_priority_domains)) != 56
    or foreign_priority_domains[:len(legacy_foreign_priority_domains)]
    != legacy_foreign_priority_domains
    or foreign_priority_domains[-len(karing_false_positive_domains):]
    != karing_false_positive_domains
):
    raise AssertionError("foreign-priority domain sequence must preserve 51 entries and append 5")
foreign_priority_route_indexes = [
    index for index, rule in enumerate(rules) if rule == foreign_priority_route_rule
]
foreign_priority_dns_indexes = [
    index for index, rule in enumerate(dns_rules) if rule == foreign_priority_dns_rule
]
if len(foreign_priority_route_indexes) != 1 or len(foreign_priority_dns_indexes) != 1:
    raise AssertionError("exact 56-domain foreign-priority route/DNS ownership changed")
foreign_priority_route_index = foreign_priority_route_indexes[0]
foreign_priority_dns_index = foreign_priority_dns_indexes[0]
if rules[foreign_priority_route_index]["domain_suffix"] != dns_rules[foreign_priority_dns_index]["domain_suffix"]:
    raise AssertionError("foreign-priority route/DNS domain lists must remain identical")
flows = (
    {
        "name": "tcp-tls",
        "inbound": "tun-in",
        "network": "tcp",
        "port": 443,
        "protocol": "tls",
        "clash_mode": default_mode,
        "ip_version": 4,
        "package_name": None,
        "process_name": None,
        "destination_ip": None,
    },
    {
        "name": "udp-quic",
        "inbound": "tun-in",
        "network": "udp",
        "port": 443,
        "protocol": "quic",
        "clash_mode": default_mode,
        "ip_version": 4,
        "package_name": None,
        "process_name": None,
        "destination_ip": None,
    },
)
allowed_outbound_rule_keys = {
    "outbound",
    "inbound",
    "network",
    "port",
    "protocol",
    "clash_mode",
    "ip_version",
    "package_name",
    "process_name",
    "ip_cidr",
    "ip_is_private",
    "domain",
    "domain_suffix",
    "domain_keyword",
    "rule_set",
}
string_value_keys = {
    "inbound",
    "network",
    "protocol",
    "clash_mode",
    "package_name",
    "process_name",
    "ip_cidr",
    "domain",
    "domain_suffix",
    "domain_keyword",
    "rule_set",
}


def values(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def validate_string_values(index, key, value):
    candidates = value if isinstance(value, list) else [value]
    if not candidates or any(not isinstance(candidate, str) or not candidate for candidate in candidates):
        raise AssertionError(
            f"route index={index} field {key} must be a non-empty string "
            "or non-empty list of non-empty strings"
        )


def validate_integer_values(index, key, value, allowed_values=None):
    candidates = value if isinstance(value, list) else [value]
    if not candidates or any(isinstance(candidate, bool) or not isinstance(candidate, int) for candidate in candidates):
        raise AssertionError(f"route index={index} field {key} must contain integers")
    if allowed_values is not None and any(candidate not in allowed_values for candidate in candidates):
        raise AssertionError(f"route index={index} field {key} contains unsupported values: {candidates}")


def validate_outbound_route(index, rule):
    if not isinstance(rule, dict):
        raise AssertionError(f"route index={index} must be an object")
    unknown_keys = sorted(set(rule) - allowed_outbound_rule_keys)
    if unknown_keys:
        raise AssertionError(
            f"route index={index} has unmodeled outbound matcher/modifier keys: {unknown_keys}"
        )
    if not isinstance(rule.get("outbound"), str) or not rule["outbound"]:
        raise AssertionError(f"route index={index} field outbound must be a non-empty string")
    for key in string_value_keys & set(rule):
        validate_string_values(index, key, rule[key])
    if "network" in rule and any(network not in {"tcp", "udp"} for network in values(rule["network"])):
        raise AssertionError(f"route index={index} field network contains unsupported values")
    if "port" in rule:
        validate_integer_values(index, "port", rule["port"])
        if any(port < 1 or port > 65535 for port in values(rule["port"])):
            raise AssertionError(f"route index={index} field port is outside 1..65535")
    if "ip_version" in rule:
        validate_integer_values(index, "ip_version", rule["ip_version"], {4, 6})
    if "ip_is_private" in rule and not isinstance(rule["ip_is_private"], bool):
        raise AssertionError(f"route index={index} field ip_is_private must be boolean")


def expect_validation_failure(rule, expected_message):
    try:
        validate_outbound_route("fixture", rule)
    except AssertionError as error:
        if expected_message not in str(error):
            raise AssertionError(f"validator fixture failed for the wrong reason: {error}") from error
    else:
        raise AssertionError(f"validator fixture unexpectedly accepted: {rule}")


expect_validation_failure(
    {"outbound": "media-proxy", "rule_set": "yuu-geosite-stream-global", "source_port": 1},
    "unmodeled outbound matcher/modifier keys: ['source_port']",
)
expect_validation_failure(
    {"outbound": "media-proxy", "domain_suffix": {"invalid": "shape"}},
    "field domain_suffix must be a non-empty string or non-empty list of non-empty strings",
)

for index, rule in enumerate(rules):
    if not isinstance(rule, dict):
        raise AssertionError(f"route index={index} must be an object")
    if "outbound" in rule:
        validate_outbound_route(index, rule)


def domain_group_matches(rule, domain):
    return (
        domain in values(rule.get("domain"))
        or any(domain == suffix or domain.endswith("." + suffix) for suffix in values(rule.get("domain_suffix")))
        or any(keyword in domain for keyword in values(rule.get("domain_keyword")))
    )


@functools.lru_cache(maxsize=None)
def binary_rule_set_matches(tag, domain):
    definitions = [definition for definition in rule_set_definitions if definition.get("tag") == tag]
    if len(definitions) != 1:
        raise AssertionError(f"rule-set {tag} has {len(definitions)} definitions")
    definition = definitions[0]
    if definition.get("type") != "local" or definition.get("format") != "binary":
        raise AssertionError(f"rule-set {tag} is not a local binary rule-set")
    rule_set_path = definition.get("path")
    if not isinstance(rule_set_path, str) or not rule_set_path:
        raise AssertionError(f"rule-set {tag} has no valid path")
    if not os.path.isabs(rule_set_path):
        rule_set_path = os.path.join(config_dir, rule_set_path)
    if not os.path.isfile(rule_set_path):
        raise AssertionError(f"rule-set binary does not exist: {rule_set_path}")
    result = subprocess.run(
        ["sing-box", "rule-set", "match", "-f", "binary", rule_set_path, domain],
        check=True,
        capture_output=True,
        text=True,
    )
    return bool(result.stdout.strip() or result.stderr.strip())


def route_rule_matches(rule, domain, flow):
    if "inbound" in rule and flow["inbound"] not in values(rule["inbound"]):
        return False
    if "network" in rule and flow["network"] not in values(rule["network"]):
        return False
    if "port" in rule and flow["port"] not in values(rule["port"]):
        return False
    if "protocol" in rule and flow["protocol"] not in values(rule["protocol"]):
        return False
    if "clash_mode" in rule and flow["clash_mode"] not in values(rule["clash_mode"]):
        return False
    if "ip_version" in rule and flow["ip_version"] not in values(rule["ip_version"]):
        return False
    if "package_name" in rule and flow["package_name"] not in values(rule["package_name"]):
        return False
    if "process_name" in rule and flow["process_name"] not in values(rule["process_name"]):
        return False
    destination_ip = flow["destination_ip"]
    if any(key in rule for key in ("ip_cidr", "ip_is_private")):
        if destination_ip is None:
            return False
        destination = ipaddress.ip_address(destination_ip)
        if "ip_cidr" in rule and not any(
            destination.version == network.version and destination in network
            for network in (ipaddress.ip_network(cidr) for cidr in values(rule["ip_cidr"]))
        ):
            return False
        if "ip_is_private" in rule and destination.is_private != rule["ip_is_private"]:
            return False
    if any(key in rule for key in ("domain", "domain_suffix", "domain_keyword")):
        if not domain_group_matches(rule, domain):
            return False
    if "rule_set" in rule:
        rule_set_targets = [domain]
        if destination_ip is not None:
            rule_set_targets.append(destination_ip)
        if not any(
            binary_rule_set_matches(tag, target)
            for tag in values(rule["rule_set"])
            for target in rule_set_targets
        ):
            return False
    return True


def first_matching_outbound(domain, flow):
    for index, rule in enumerate(rules):
        if "outbound" in rule and route_rule_matches(rule, domain, flow):
            rule_set_targets = [domain]
            if flow["destination_ip"] is not None:
                rule_set_targets.append(flow["destination_ip"])
            matching_rule_sets = {
                tag
                for tag in values(rule.get("rule_set"))
                if any(binary_rule_set_matches(tag, target) for target in rule_set_targets)
            }
            return index, rule, matching_rule_sets
    raise AssertionError(f"{flow['name']} {domain} has no matching outbound route")


def first_matching_dns(domain, flow):
    for index, rule in enumerate(dns_rules):
        if "server" in rule and route_rule_matches(rule, domain, flow):
            rule_set_targets = [domain]
            if flow["destination_ip"] is not None:
                rule_set_targets.append(flow["destination_ip"])
            matching_rule_sets = {
                tag
                for tag in values(rule.get("rule_set"))
                if any(binary_rule_set_matches(tag, target) for target in rule_set_targets)
            }
            return index, rule, matching_rule_sets
    return None


google_play_proxy_rule = {
    "package_name": [
        "com.android.vending",
        "com.google.android.gms",
        "com.google.android.gsf",
    ],
    "outbound": "proxy-rule",
}
google_play_proxy_indexes = [
    index for index, rule in enumerate(rules) if rule == google_play_proxy_rule
]
if len(google_play_proxy_indexes) != 1:
    raise AssertionError(
        "Google Play package routing must have one early proxy owner: "
        f"indexes={google_play_proxy_indexes}"
    )
google_play_proxy_index = google_play_proxy_indexes[0]
for package_name in google_play_proxy_rule["package_name"]:
    for base_flow in flows:
        flow = dict(base_flow, package_name=package_name)
        index, rule, _ = first_matching_outbound("play.googleapis.com", flow)
        if index != google_play_proxy_index or rule != google_play_proxy_rule:
            raise AssertionError(
                f"{package_name} {base_flow['name']} must proxy before destination rules: "
                f"index={index} rule={rule}"
            )


metacubex_false_positive_failures = []
for domain, expected_outbound in metacubex_false_positive_expectations.items():
    if not binary_rule_set_matches("metacubex-geosite-cn", domain):
        raise AssertionError(f"{domain} must match metacubex-geosite-cn before correction")
    retained_cn_matches = {
        tag
        for tag in retained_canonical_cn_rule_sets
        if binary_rule_set_matches(tag, domain)
    }
    foreign_matches = {
        tag
        for tag in metacubex_false_positive_foreign_rule_sets
        if binary_rule_set_matches(tag, domain)
    }
    if retained_cn_matches or not foreign_matches:
        raise AssertionError(
            f"metacubex correction evidence changed for {domain}: "
            f"retained_cn={sorted(retained_cn_matches)} foreign={sorted(foreign_matches)}"
        )
    route_index, route_rule, _ = first_matching_outbound(domain, flows[0])
    dns_match = first_matching_dns(domain, flows[0])
    if dns_match is None:
        dns_index = "final"
        dns_server = config["dns"].get("final")
    else:
        dns_index, dns_rule, _ = dns_match
        dns_server = dns_rule.get("server")
    if route_rule.get("outbound") != expected_outbound or dns_server != "doh-google":
        metacubex_false_positive_failures.append(
            f"{domain}: route_index={route_index} outbound={route_rule.get('outbound')} "
            f"expected_outbound={expected_outbound} dns_index={dns_index} "
            f"dns_server={dns_server} foreign={sorted(foreign_matches)}"
        )
if metacubex_false_positive_failures:
    raise AssertionError(
        "metacubex-geosite-cn false-positive routing remains active: "
        + "; ".join(metacubex_false_positive_failures)
    )

karing_false_positive_failures = []
for domain in karing_false_positive_domains:
    if not binary_rule_set_matches("karing-acl4ssr-china-domain", domain):
        raise AssertionError(f"{domain} must retain Karing China-domain SRS overlap evidence")
    foreign_matches = {
        tag
        for tag in karing_false_positive_foreign_rule_sets
        if binary_rule_set_matches(tag, domain)
    }
    if domain in {"sony.com", "teamviewer.com"} and not foreign_matches:
        raise AssertionError(f"{domain} must retain foreign rule-set overlap evidence")
    route_index, route_rule, _ = first_matching_outbound(domain, flows[0])
    dns_match = first_matching_dns(domain, flows[0])
    if dns_match is None:
        dns_index = "final"
        dns_server = config["dns"].get("final")
    else:
        dns_index, dns_rule, _ = dns_match
        dns_server = dns_rule.get("server")
    if (
        route_index != foreign_priority_route_index
        or route_rule.get("outbound") != "proxy-rule"
        or dns_index != foreign_priority_dns_index
        or dns_server != "doh-google"
    ):
        karing_false_positive_failures.append(
            f"{domain}: route_index={route_index} outbound={route_rule.get('outbound')} "
            f"dns_index={dns_index} dns_server={dns_server} "
            f"foreign={sorted(foreign_matches)}"
        )
if karing_false_positive_failures:
    raise AssertionError(
        "Karing China-domain false-positive routing remains active: "
        + "; ".join(karing_false_positive_failures)
    )

for domain in ("sony.com.cn", "teamviewer.cn"):
    route_index, route_rule, _ = first_matching_outbound(domain, flows[0])
    dns_match = first_matching_dns(domain, flows[0])
    if dns_match is None:
        raise AssertionError(f"domestic control {domain} unexpectedly used dns.final")
    dns_index, dns_rule, _ = dns_match
    if route_rule.get("outbound") != "cn-direct" or dns_rule.get("server") != "bootstrap-local-dns":
        raise AssertionError(
            f"domestic control {domain} changed: route_index={route_index} "
            f"outbound={route_rule.get('outbound')} dns_index={dns_index} "
            f"dns_server={dns_rule.get('server')}"
        )


for domain in legacy_foreign_priority_domains:
    cn_matches = {
        tag for tag in cn_overlap_evidence_rule_sets if binary_rule_set_matches(tag, domain)
    }
    foreign_matches = {
        tag for tag in generic_foreign_rule_sets if binary_rule_set_matches(tag, domain)
    }
    if not cn_matches or not foreign_matches:
        raise AssertionError(
            f"foreign-priority overlap evidence missing for {domain}: "
            f"cn={sorted(cn_matches)} foreign={sorted(foreign_matches)}"
        )
    route_index, route_rule, _ = first_matching_outbound(domain, flows[0])
    if route_rule.get("outbound") != "proxy-rule":
        raise AssertionError(
            f"foreign-priority {domain} must first-match proxy-rule routing: "
            f"index={route_index} outbound={route_rule.get('outbound')} "
            f"cn={sorted(cn_matches)} foreign={sorted(foreign_matches)}"
        )
    dns_match = first_matching_dns(domain, flows[0])
    if dns_match is None:
        raise AssertionError(f"foreign-priority {domain} unexpectedly used dns.final")
    dns_index, dns_rule, _ = dns_match
    if dns_rule.get("server") != "doh-google":
        raise AssertionError(
            f"foreign-priority {domain} must first-match proxy-detoured doh-google DNS: "
            f"index={dns_index} server={dns_rule.get('server')} "
            f"cn={sorted(cn_matches)} foreign={sorted(foreign_matches)}"
        )


def selector_for(tag):
    matches = [outbound for outbound in outbound_list if outbound.get("tag") == tag]
    if len(matches) != 1:
        raise AssertionError(f"expected exactly one outbound selector {tag}, found {len(matches)}")
    selector = matches[0]
    if selector.get("type") != "selector" or selector.get("default") not in selector.get("outbounds", []):
        raise AssertionError(f"outbound {tag} is not a valid selector with a selectable default")
    return selector


def recursively_effective_outbound(tag):
    visited = []
    current = tag
    while True:
        if current in visited:
            raise AssertionError(f"selector cycle while resolving {tag}: {visited + [current]}")
        visited.append(current)
        matches = [outbound for outbound in outbound_list if outbound.get("tag") == current]
        if len(matches) != 1:
            raise AssertionError(
                f"expected exactly one outbound {current} while resolving {tag}, found {len(matches)}"
            )
        outbound = matches[0]
        if outbound.get("type") != "selector":
            return current
        default = outbound.get("default")
        if not isinstance(default, str) or default not in outbound.get("outbounds", []):
            raise AssertionError(f"selector {current} has an invalid default while resolving {tag}")
        current = default


proxy_node_types = {"shadowsocks", "vmess", "vless", "trojan", "hysteria2", "anytls", "tuic", "socks"}
base_proxy_nodes = [
    outbound for outbound in outbound_list if outbound.get("type") in proxy_node_types
]
if base_proxy_nodes:
    raise AssertionError("base config must represent the zero-node state")
expected_zero_node_proxy = {
    "type": "selector",
    "tag": "proxy",
    "outbounds": ["block"],
    "default": "block",
}
proxy_selectors = [outbound for outbound in outbound_list if outbound.get("tag") == "proxy"]
if proxy_selectors != [expected_zero_node_proxy]:
    raise AssertionError(f"base zero-node proxy selector is not canonical fail-closed: {proxy_selectors}")
for tag in (
    "proxy",
    "select",
    "final",
    "proxy-rule",
    "dev-proxy",
    "media-proxy",
    "game-proxy",
    "social-proxy",
    "telegram-proxy",
    "network-test",
    "dns-guard",
):
    effective = recursively_effective_outbound(tag)
    if effective != "block":
        raise AssertionError(f"zero-node selector {tag} recursively resolves to {effective}, expected block")
for tag in ("lan", "hotspot", "cn-direct", "apple-cn", "microsoft-cn", "icloud", "download-direct"):
    effective = recursively_effective_outbound(tag)
    if effective != "direct":
        raise AssertionError(f"domestic selector {tag} recursively resolves to {effective}, expected direct")
for tag in ("ai-proxy", "ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"):
    effective = recursively_effective_outbound(tag)
    if effective != "block":
        raise AssertionError(f"AI selector {tag} recursively resolves to {effective}, expected block")


download_selectors = [outbound for outbound in outbound_list if outbound.get("tag") == "download-direct"]
if download_selectors != [expected_download_selector]:
    raise AssertionError(f"download-direct selector is not canonical direct-default: {download_selectors}")

expected_hotspot_selector = {
    "type": "selector",
    "tag": "hotspot",
    "outbounds": ["direct", "proxy"],
    "default": "direct",
}
hotspot_selectors = [outbound for outbound in outbound_list if outbound.get("tag") == "hotspot"]
if hotspot_selectors != [expected_hotspot_selector]:
    raise AssertionError(f"hotspot selector is not canonical direct/proxy: {hotspot_selectors}")

for tag in fail_closed_ai_tags:
    expected_selector = {"type": "selector", "tag": tag, "outbounds": ["block"], "default": "block"}
    matches = [outbound for outbound in outbound_list if outbound.get("tag") == tag]
    if matches != [expected_selector]:
        raise AssertionError(f"{tag} selector is not canonical fail-closed: {matches}")

lan_rules = [
    {"domain_suffix": ["local", "home.arpa", "lan"], "outbound": "lan"},
    {"domain_suffix": ["tailscale.net", "ts.net"], "outbound": "lan"},
    {"ip_is_private": True, "outbound": "lan"},
    {
        "ip_cidr": [
            "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
            "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "::1/128",
            "fc00::/7", "fe80::/10", "ff00::/8", "fd7a:115c:a1e0::/48",
        ],
        "outbound": "lan",
    },
]
ad_rules = [
    {
        "domain_suffix": [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com",
            "adservice.google.com", "adsystem.com", "adnxs.com", "scorecardresearch.com",
            "umeng.com", "umengcloud.com",
        ],
        "outbound": "ad-block",
    },
    {"domain_keyword": ["adservice", "analytics", "tracking", "tracker"], "outbound": "ad-block"},
]

lan_route_probes = {
    "analytics.local": "192.168.32.50",
    "tracker.lan": "10.42.0.8",
    "tracking.foo.ts.net": "100.64.12.34",
    "tracker.home.arpa": "fd7a:115c:a1e0::123",
}
public_ad_probes = {
    "google-analytics.com": "1.1.1.1",
    "doubleclick.net": "8.8.8.8",
}
for base_flow in flows:
    for domain, destination_ip in lan_route_probes.items():
        flow = dict(base_flow, destination_ip=destination_ip,
                    ip_version=ipaddress.ip_address(destination_ip).version)
        index, rule, _ = first_matching_outbound(domain, flow)
        effective = recursively_effective_outbound(rule["outbound"])
        print(
            f"{flow['name']} {domain}/{destination_ip} first-match index={index} "
            f"outbound={rule['outbound']} effective={effective}"
        )
        if rule["outbound"] != "lan" or effective != "direct":
            raise AssertionError(
                f"{flow['name']} {domain}/{destination_ip}: index={index} "
                f"outbound={rule['outbound']} effective={effective}, expected=lan/direct"
            )
    for domain, destination_ip in public_ad_probes.items():
        flow = dict(base_flow, destination_ip=destination_ip,
                    ip_version=ipaddress.ip_address(destination_ip).version)
        index, rule, _ = first_matching_outbound(domain, flow)
        effective = recursively_effective_outbound(rule["outbound"])
        if rule["outbound"] != "ad-block" or effective != "block":
            raise AssertionError(
                f"{flow['name']} {domain}/{destination_ip}: index={index} "
                f"outbound={rule['outbound']} effective={effective}, expected=ad-block/block"
            )
expected_lan_ad_block = lan_rules + ad_rules
lan_ad_indexes = [
    next((index for index, rule in enumerate(rules) if rule == expected_rule), None)
    for expected_rule in lan_rules
]
ad_rule_indexes = [
    next((index for index, rule in enumerate(rules) if rule == expected_rule), None)
    for expected_rule in ad_rules
]
if (
    any(index is None for index in [*lan_ad_indexes, *ad_rule_indexes])
    or lan_ad_indexes != list(range(lan_ad_indexes[0], lan_ad_indexes[0] + len(lan_rules)))
    or ad_rule_indexes != list(range(ad_rule_indexes[0], ad_rule_indexes[0] + len(ad_rules)))
    or lan_ad_indexes[-1] + 1 != ad_rule_indexes[0]
):
    raise AssertionError(
        "LAN/ad canonical blocks must remain unique and contiguous: "
        f"lan={lan_ad_indexes} ad={ad_rule_indexes}"
    )
for expected_rule in expected_lan_ad_block:
    matches = [index for index, rule in enumerate(rules) if rule == expected_rule]
    if len(matches) != 1:
        raise AssertionError(f"canonical guard/LAN/ad rule must have one owner: {expected_rule} indexes={matches}")

google_cn_direct_rule = {
    "domain_suffix": ["google.cn", "g.cn", "googleapis.cn"],
    "outbound": "cn-direct",
}
legacy_mixed_google_rule = {
    "domain_suffix": ["google.cn", "g.cn", "googleapis.cn", "google-analytics.com"],
    "outbound": "google-cn",
}
google_cn_outbounds = [outbound for outbound in outbound_list if outbound.get("tag") == "google-cn"]
if google_cn_outbounds:
    raise AssertionError(f"google-cn outbound selector must be absent: {google_cn_outbounds}")
google_cn_routes = [
    (index, rule) for index, rule in enumerate(rules) if rule.get("outbound") == "google-cn"
]
if google_cn_routes:
    raise AssertionError(f"google-cn route outbound must be absent: {google_cn_routes}")
google_cn_direct_indexes = [
    index for index, rule in enumerate(rules) if rule == google_cn_direct_rule
]
if len(google_cn_direct_indexes) != 1:
    raise AssertionError(f"expected one exact domestic Google route, found {google_cn_direct_indexes}")
if legacy_mixed_google_rule in rules:
    raise AssertionError("legacy mixed Google route rule must be absent")

google_route_expectations = {
    "google.cn": ("cn-direct", "direct"),
    "g.cn": ("cn-direct", "direct"),
    "fonts.googleapis.cn": ("cn-direct", "direct"),
    "google-analytics.com": ("ad-block", "block"),
}
for domain, (expected_outbound, expected_effective) in google_route_expectations.items():
    index, rule, matching_rule_sets = first_matching_outbound(domain, flows[0])
    actual_outbound = rule.get("outbound")
    actual_effective = recursively_effective_outbound(actual_outbound)
    print(
        f"tcp-tls {domain} first-match index={index} outbound={actual_outbound} "
        f"effective={actual_effective} matching_rule_sets={sorted(matching_rule_sets)}"
    )
    if actual_outbound != expected_outbound or actual_effective != expected_effective:
        raise AssertionError(
            f"{domain}: index={index} outbound={actual_outbound} effective={actual_effective}, "
            f"expected={expected_outbound}/{expected_effective}"
        )

bing_cn_direct_rule = {
    "domain_suffix": ["cn.bing.com"],
    "outbound": "cn-direct",
}
bing_cn_direct_indexes = [
    index for index, rule in enumerate(rules) if rule == bing_cn_direct_rule
]
if len(bing_cn_direct_indexes) != 1:
    raise AssertionError(f"expected one exact cn.bing.com direct route, found {bing_cn_direct_indexes}")
if any(
    rule.get("outbound") == "bing" and "cn.bing.com" in values(rule.get("domain_suffix"))
    for rule in rules
):
    raise AssertionError("bing routes must not explicitly contain cn.bing.com")

for domain, (expected_outbound, expected_effective) in {
    "cn.bing.com": ("cn-direct", "direct"),
    "www.bing.com": ("bing", "block"),
    "r.bing.com": ("bing", "block"),
}.items():
    index, rule, matching_rule_sets = first_matching_outbound(domain, flows[0])
    actual_outbound = rule.get("outbound")
    actual_effective = recursively_effective_outbound(actual_outbound)
    print(
        f"tcp-tls {domain} first-match index={index} outbound={actual_outbound} "
        f"effective={actual_effective} matching_rule_sets={sorted(matching_rule_sets)}"
    )
    if actual_outbound != expected_outbound or actual_effective != expected_effective:
        raise AssertionError(
            f"{domain}: index={index} outbound={actual_outbound} effective={actual_effective}, "
            f"expected={expected_outbound}/{expected_effective}"
        )

r_bing_cn_rule_sets = {
    tag for tag in canonical_cn_rule_sets if binary_rule_set_matches(tag, "r.bing.com")
}
if not r_bing_cn_rule_sets:
    raise AssertionError("r.bing.com must overlap a canonical CN rule-set to prove route ordering")

for domain in ("login.live.com", "account.live.com", "www.msn.com"):
    index, rule, matching_rule_sets = first_matching_outbound(domain, flows[0])
    actual_outbound = rule.get("outbound")
    actual_effective = recursively_effective_outbound(actual_outbound)
    if actual_outbound != "bing" or actual_effective != "block":
        raise AssertionError(
            f"{domain}: index={index} outbound={actual_outbound} effective={actual_effective}, "
            "expected=bing/block"
        )

for domain in ("www.microsoft.com", "msftauth.net", "www.office.com", "www.live.com"):
    index, rule, matching_rule_sets = first_matching_outbound(domain, flows[0])
    actual_outbound = rule.get("outbound")
    actual_effective = recursively_effective_outbound(actual_outbound)
    if actual_outbound != "microsoft-cn" or actual_effective != "direct":
        raise AssertionError(
            f"{domain}: index={index} outbound={actual_outbound} effective={actual_effective}, "
            "expected=microsoft-cn/direct"
        )

domestic_package_flow = dict(
    flows[0], name="tcp-tls-domestic-package", package_name="com.taobao.taobao"
)
for domain, (expected_outbound, expected_effective) in {
    "github.com": ("dev-proxy", "block"),
    "x.com": ("social-proxy", "block"),
    "doubleclick.net": ("ad-block", "block"),
    "baidu.com": ("cn-direct", "direct"),
}.items():
    index, rule, matching_rule_sets = first_matching_outbound(domain, domestic_package_flow)
    actual_outbound = rule.get("outbound")
    actual_effective = recursively_effective_outbound(actual_outbound)
    print(
        f"domestic-package {domain} first-match index={index} outbound={actual_outbound} "
        f"effective={actual_effective} matching_rule_sets={sorted(matching_rule_sets)}"
    )
    if actual_outbound != expected_outbound or actual_effective != expected_effective:
        raise AssertionError(
            f"domestic package {domain}: index={index} outbound={actual_outbound} "
            f"effective={actual_effective}, expected={expected_outbound}/{expected_effective}"
        )
    if index >= len(rules) - 1:
        raise AssertionError(f"destination policy did not precede the generic final route for {domain}")

x_domain_flow = dict(
    flows[0],
    name="tcp-tls-x-domain-only",
    package_name=None,
    destination_ip="114.114.114.114",
)
for domain in ("api.x.com", "upload.twitter.com", "abs.twimg.com"):
    index, rule, matching_rule_sets = first_matching_outbound(domain, x_domain_flow)
    if index != x_domain_index or rule != x_domain_rule:
        raise AssertionError(
            f"{domain} must keep the early social route even when its destination IP "
            f"matches CN data: index={index} rule={rule} matching_rule_sets={sorted(matching_rule_sets)}"
        )

if first_matching_dns("unclassified.magicnet-probe", domestic_package_flow) is not None:
    raise AssertionError("unclassified application DNS must use dns.final instead of a package fallback")

for domain, expected_index, expected_rule in (
    ("doubleclick.net", ad_suffix_dns_index, ad_suffix_dns_rule),
    ("www.google-analytics.com", ad_keyword_dns_index, ad_keyword_dns_rule),
    ("outbrain.com", ad_rule_set_dns_index, ad_rule_set_dns_rule),
):
    result = first_matching_dns(domain, domestic_package_flow)
    if result is None:
        raise AssertionError(f"domestic-package {domain} DNS unexpectedly used dns.final")
    index, rule, matching_rule_sets = result
    if index != expected_index or rule != expected_rule or rule.get("server") != "doh-cloudflare":
        raise AssertionError(
            f"domestic-package {domain} DNS must use its earlier ad classifier: "
            f"index={index} server={rule.get('server')} matching_rule_sets={sorted(matching_rule_sets)}"
        )
    if domain == "outbrain.com" and matching_rule_sets != {"lyc-geosite-ads"}:
        raise AssertionError(
            "outbrain.com must prove the non-explicit ad rule-set path via lyc-geosite-ads: "
            f"matching_rule_sets={sorted(matching_rule_sets)}"
        )

tracker_lan_dns = first_matching_dns("tracker.lan", domestic_package_flow)
if tracker_lan_dns is None:
    raise AssertionError("domestic-package tracker.lan DNS unexpectedly used dns.final")
index, rule, matching_rule_sets = tracker_lan_dns
if index != 0 or rule.get("server") != "bootstrap-local-dns":
    raise AssertionError(
        "private tracker.lan DNS must remain local before the ad keyword classifier: "
        f"index={index} server={rule.get('server')}"
    )

github_dns = first_matching_dns("github.com", domestic_package_flow)
if github_dns is None:
    raise AssertionError("domestic-package github.com DNS unexpectedly used dns.final")
index, rule, matching_rule_sets = github_dns
if rule.get("server") not in proxy_dns_tags:
    raise AssertionError(
        "domestic-package github.com DNS must use an earlier proxy-detoured server: "
        f"index={index} server={rule.get('server')}"
    )

x_dns = first_matching_dns("x.com", domestic_package_flow)
if x_dns is None:
    raise AssertionError("domestic-package x.com DNS unexpectedly used dns.final")
index, rule, matching_rule_sets = x_dns
if rule != x_social_dns_rule:
    raise AssertionError(
        "domestic-package x.com DNS must use the explicit social proxy DNS rule: "
        f"index={index} rule={rule} matching_rule_sets={sorted(matching_rule_sets)}"
    )
for x_domain in ("api.x.com", "upload.twitter.com", "abs.twimg.com"):
    x_domain_dns = first_matching_dns(x_domain, domestic_package_flow)
    if x_domain_dns is None:
        raise AssertionError(f"domestic-package {x_domain} DNS unexpectedly used dns.final")
    index, rule, matching_rule_sets = x_domain_dns
    if rule != x_social_dns_rule:
        raise AssertionError(
            f"domestic-package {x_domain} DNS must use the explicit social proxy DNS rule: "
            f"index={index} rule={rule} matching_rule_sets={sorted(matching_rule_sets)}"
        )

baidu_dns = first_matching_dns("baidu.com", domestic_package_flow)
if baidu_dns is None:
    raise AssertionError("domestic-package baidu.com DNS unexpectedly used dns.final")
index, rule, matching_rule_sets = baidu_dns
if rule.get("server") != "bootstrap-local-dns":
    raise AssertionError(
        "domestic-package baidu.com DNS precedence changed: "
        f"index={index} server={rule.get('server')}"
    )

mmstat_dns_indexes = [
    index for index, rule in enumerate(dns_rules) if rule == mmstat_local_dns_rule
]
if len(mmstat_dns_indexes) != 1:
    raise AssertionError(f"expected one exact mmstat local DNS rule: {mmstat_dns_indexes}")
mmstat_dns_index = mmstat_dns_indexes[0]
route_index, route_rule, matching_rule_sets = first_matching_outbound("mmstat.com", flows[0])
route_outbound = route_rule.get("outbound")
route_effective = recursively_effective_outbound(route_outbound)
if route_outbound != "ad-block" or route_effective != "block" or "lyc-geosite-ads" not in matching_rule_sets:
    raise AssertionError(
        "mmstat.com must use the generic ad rule-set route instead of a vendor direct exception: "
        f"index={route_index} outbound={route_outbound} effective={route_effective} "
        f"matching_rule_sets={sorted(matching_rule_sets)}"
    )
mmstat_dns = first_matching_dns("mmstat.com", flows[0])
if mmstat_dns is None:
    raise AssertionError("mmstat.com DNS unexpectedly used dns.final")
index, rule, matching_rule_sets = mmstat_dns
if index != mmstat_dns_index or rule != mmstat_local_dns_rule:
    raise AssertionError(
        f"mmstat.com DNS must use exact local rule: index={index} server={rule.get('server')}"
    )
mmstat_cn_rule_sets = {
    tag for tag in canonical_cn_rule_sets if binary_rule_set_matches(tag, "mmstat.com")
}
if not mmstat_cn_rule_sets:
    raise AssertionError("mmstat.com must overlap at least one canonical CN rule-set")
if not binary_rule_set_matches("lyc-geosite-ads", "mmstat.com"):
    raise AssertionError("mmstat.com must overlap lyc-geosite-ads")
mmstat_hagezi_rule_sets = {
    tag
    for tag in ("hagezi-light", "hagezi-normal", "hagezi-anti-piracy")
    if binary_rule_set_matches(tag, "mmstat.com")
}
if not mmstat_hagezi_rule_sets:
    raise AssertionError("mmstat.com must overlap at least one Hagezi ad rule-set")

explicit_route_domains = sorted({
    domain
    for route_rule in rules
    for key in ("domain", "domain_suffix")
    for domain in values(route_rule.get(key))
})
if not explicit_route_domains:
    raise AssertionError(
        "explicit route-domain audit coverage is empty; destination policy has no explicit domain probes"
    )

def audit_explicit_route_dns_parity(domain):
    route_index, route_rule, _ = first_matching_outbound(domain, flows[0])
    route_outbound = route_rule.get("outbound")
    route_effective = recursively_effective_outbound(route_outbound)
    dns_match = first_matching_dns(domain, flows[0])
    if dns_match is None:
        dns_index = "final"
        dns_server = config["dns"].get("final")
    else:
        dns_index, dns_rule, _ = dns_match
        dns_server = dns_rule.get("server")
    parity_ok = (
        dns_server == "bootstrap-local-dns"
        if route_effective == "direct"
        else dns_server in proxy_dns_tags
    )
    if parity_ok:
        return None
    expected_dns = "bootstrap-local-dns" if route_effective == "direct" else "proxy-detoured DNS"
    return (
        f"domain={domain} route_index={route_index} outbound={route_outbound} "
        f"effective={route_effective} dns_index={dns_index} server={dns_server} "
        f"expected={expected_dns}"
    )

audit_started = time.monotonic()
with ThreadPoolExecutor(max_workers=16) as executor:
    explicit_route_dns_failures = [
        failure
        for failure in executor.map(audit_explicit_route_dns_parity, explicit_route_domains)
        if failure is not None
    ]
audit_duration = time.monotonic() - audit_started
if explicit_route_dns_failures:
    raise AssertionError(
        "explicit route/DNS parity audit failed:\n" + "\n".join(explicit_route_dns_failures)
    )
print(
    f"explicit route/DNS parity audit count={len(explicit_route_domains)} "
    f"duration_seconds={audit_duration:.3f}"
)

for domain, expected_index, expected_rule, expected_server in (
    ("cn.bing.com", cn_bing_dns_index, cn_bing_dns_rule, "bootstrap-local-dns"),
    ("www.bing.com", global_bing_dns_index, global_bing_dns_rule, "doh-google"),
    ("r.bing.com", global_bing_dns_index, global_bing_dns_rule, "doh-google"),
):
    result = first_matching_dns(domain, flows[0])
    if result is None:
        raise AssertionError(f"{domain} DNS unexpectedly used dns.final")
    index, rule, matching_rule_sets = result
    if index != expected_index or rule != expected_rule or rule.get("server") != expected_server:
        raise AssertionError(
            f"{domain} DNS split changed: index={index} server={rule.get('server')} "
            f"expected_index={expected_index} expected_server={expected_server}"
        )

network_test_dns_probes = (
    "msftconnecttest.com",
    "msftncsi.com",
    "captive.apple.com",
    "connectivitycheck.android.com",
)
for domain in network_test_dns_probes:
    result = first_matching_dns(domain, flows[0])
    if result is None:
        raise AssertionError(f"Rule-mode {domain} DNS unexpectedly used dns.final")
    index, rule, matching_rule_sets = result
    if (
        index != foreign_network_test_dns_index
        or rule != foreign_network_test_dns_rule
        or rule.get("server") != "doh-google"
    ):
        raise AssertionError(
            f"Rule-mode {domain} DNS must use foreign network-test policy: "
            f"index={index} server={rule.get('server')}"
        )
    route_index, route_rule, matching_rule_sets = first_matching_outbound(domain, flows[0])
    route_outbound = route_rule.get("outbound")
    route_effective = recursively_effective_outbound(route_outbound)
    if route_outbound != "network-test" or route_effective != "block":
        raise AssertionError(
            f"Rule-mode {domain} route must use network-test/block: "
            f"index={route_index} outbound={route_outbound} effective={route_effective}"
        )

for clash_mode, expected_index, expected_server in (
    ("Direct", direct_mode_dns_index, "bootstrap-local-dns"),
    ("Global", global_mode_dns_index, "doh-cloudflare"),
):
    mode_flow = dict(flows[0], name=f"tcp-tls-{clash_mode.lower()}", clash_mode=clash_mode)
    for domain in network_test_dns_probes:
        result = first_matching_dns(domain, mode_flow)
        if result is None:
            raise AssertionError(f"{clash_mode}-mode {domain} DNS unexpectedly used dns.final")
        index, rule, matching_rule_sets = result
        if index != expected_index or rule.get("server") != expected_server:
            raise AssertionError(
                f"{clash_mode}-mode {domain} DNS override changed: "
                f"index={index} server={rule.get('server')}"
            )

ordinary_unclassified_dns = first_matching_dns("unclassified.magicnet-probe", flows[0])
if ordinary_unclassified_dns is not None:
    index, rule, matching_rule_sets = ordinary_unclassified_dns
    raise AssertionError(
        "ordinary unclassified DNS must use dns.final: "
        f"matched_index={index} server={rule.get('server')}"
    )
if config["dns"].get("final") != "bootstrap-local-dns":
    raise AssertionError(
        "ordinary unclassified DNS must use local encrypted resolution so a previously "
        "unknown domestic CDN can be classified by CN destination IP: "
        f"actual={config['dns'].get('final')}"
    )

unclassified_domestic_flow = dict(
    flows[0],
    name="tcp-tls-unclassified-domestic-ip",
    destination_ip="223.5.5.5",
)
route_index, route_rule, matching_rule_sets = first_matching_outbound(
    "unclassified.magicnet-probe", unclassified_domestic_flow
)
if route_rule.get("outbound") != "cn-direct" or not (
    {"lyc-geoip-cn", "metacubex-geoip-cn", "karing-acl4ssr-china-ip"}
    & matching_rule_sets
):
    raise AssertionError(
        "unclassified domain resolved to a CN IP must use destination-based cn-direct: "
        f"index={route_index} outbound={route_rule.get('outbound')} "
        f"matching_rule_sets={sorted(matching_rule_sets)}"
    )

unclassified_foreign_flow = dict(
    flows[0],
    name="tcp-tls-unclassified-foreign-ip",
    destination_ip="8.8.8.8",
)
unclassified_foreign_matches = [
    (index, rule)
    for index, rule in enumerate(rules)
    if "outbound" in rule
    and route_rule_matches(rule, "unclassified.magicnet-probe", unclassified_foreign_flow)
]
if (
    unclassified_foreign_matches
    or config["route"].get("final") != "final"
    or selector_for("final").get("default") != "proxy"
):
    raise AssertionError(
        "unclassified domain resolved to a non-CN IP must retain final proxy routing: "
        f"explicit_matches={unclassified_foreign_matches} "
        f"route_final={config['route'].get('final')}"
    )

for domain in foreign_network_test_dns_rule["domain_suffix"]:
    result = first_matching_dns(domain, flows[0])
    if result is None:
        raise AssertionError(f"network-test DNS {domain} unexpectedly used dns.final")
    index, rule, matching_rule_sets = result
    if domain in network_test_leak_overlap:
        expected_index = dedicated_leak_test_dns_index
        expected_server = "doh-cloudflare"
        expected_rule = dedicated_leak_test_dns_rule
    else:
        expected_index = foreign_network_test_dns_index
        expected_server = "doh-google"
        expected_rule = foreign_network_test_dns_rule
    if index != expected_index or rule != expected_rule or rule.get("server") != expected_server:
        raise AssertionError(
            f"network-test DNS precedence changed for {domain}: index={index} "
            f"server={rule.get('server')} expected_index={expected_index} "
            f"expected_server={expected_server}"
        )

browserscan_route = first_matching_outbound("browserscan.net", flows[0])
index, rule, matching_rule_sets = browserscan_route
network_test_route_indexes = [
    route_index for route_index, route_rule in enumerate(rules)
    if route_rule == {"domain_suffix": foreign_network_test_suffixes, "outbound": "network-test"}
]
if (
    rule.get("outbound") != "dns-guard"
    or recursively_effective_outbound(rule["outbound"]) != "block"
    or len(network_test_route_indexes) != 1
    or not index < network_test_route_indexes[0]
):
    raise AssertionError(
        "browserscan.net must first-match the earlier dns-guard route before network-test: "
        f"first_index={index} rule={rule} network_indexes={network_test_route_indexes}"
    )

for flow in flows:
    for domain in media_targets:
        index, rule, matching_rule_sets = first_matching_outbound(domain, flow)
        if rule.get("outbound") != "media-proxy" or not required_media_sets <= matching_rule_sets:
            raise AssertionError(
                f"{flow['name']} {domain} first matched route index={index} "
                f"outbound={rule.get('outbound')} matching_rule_sets={sorted(matching_rule_sets)} "
                "instead of media-proxy via binary media rule-sets"
            )
        print(f"{flow['name']} {domain} first-match index={index} outbound=media-proxy")

download_failures = []
download_results = {}
for flow in flows:
    for domain, expected_outbound in download_expectations.items():
        index, rule, matching_rule_sets = first_matching_outbound(domain, flow)
        actual_outbound = rule.get("outbound")
        selector = selector_for(actual_outbound)
        effective_outbound = selector["default"]
        print(
            f"{flow['name']} {domain} first-match index={index} outbound={actual_outbound} "
            f"effective={effective_outbound}"
        )
        download_results[(flow["name"], domain)] = (index, actual_outbound, effective_outbound)
        if actual_outbound != expected_outbound or effective_outbound != "direct":
            download_failures.append(
                f"{flow['name']} {domain}: index={index} outbound={actual_outbound} "
                f"effective={effective_outbound}, expected={expected_outbound}/direct"
            )
if download_failures:
    raise AssertionError("download routing failures: " + "; ".join(download_failures))

specialized_failures = []
for flow in flows:
    for domain, expected_outbound in affected_specialized_expectations.items():
        index, rule, _ = first_matching_outbound(domain, flow)
        actual_outbound = rule.get("outbound")
        print(f"{flow['name']} {domain} first-match index={index} outbound={actual_outbound}")
        if actual_outbound != expected_outbound:
            specialized_failures.append(
                f"{flow['name']} {domain}: index={index} outbound={actual_outbound}, "
                f"expected={expected_outbound}"
            )
if specialized_failures:
    raise AssertionError("specialized fallback routing failures: " + "; ".join(specialized_failures))

foreign_game_failures = []
for flow in flows:
    for domain in game_domain_suffixes:
        index, rule, _ = first_matching_outbound(domain, flow)
        actual_outbound = rule.get("outbound")
        effective_outbound = recursively_effective_outbound(actual_outbound)
        print(
            f"{flow['name']} {domain} first-match index={index} outbound={actual_outbound} "
            f"effective={effective_outbound}"
        )
        if actual_outbound != "game-proxy" or effective_outbound != "block":
            foreign_game_failures.append(
                f"{flow['name']} {domain}: index={index} outbound={actual_outbound} "
                f"effective={effective_outbound}, expected=game-proxy/block"
            )
for domain in (
    "epicgames.dev", "unrealengine.com", "paragon.com", "playstation.com",
    "playstationnetwork.com", "sonyentertainmentnetwork.com",
):
    if not binary_rule_set_matches("karing-acl4ssr-china-domain", domain):
        foreign_game_failures.append(f"{domain}: expected overlapping karing China SRS evidence")
if foreign_game_failures:
    raise AssertionError("foreign game routing failures: " + "; ".join(foreign_game_failures))

tcp_flow = flows[0]
domestic_failures = []
for domain in domestic_targets:
    index, rule, matching_rule_sets = first_matching_outbound(domain, tcp_flow)
    print(f"tcp-tls {domain} first-match index={index} outbound={rule.get('outbound')}")
    if rule.get("outbound") != "cn-direct":
        domestic_failures.append(f"{domain}: index={index} outbound={rule.get('outbound')}")
    elif domain in domestic_srs_only_targets and not matching_rule_sets:
        domestic_failures.append(f"{domain}: cn-direct match skipped binary CN rule-sets")
    retained_cn_matches = {
        tag for tag in retained_canonical_cn_rule_sets if binary_rule_set_matches(tag, domain)
    }
    if not retained_cn_matches:
        domestic_failures.append(f"{domain}: did not match any retained canonical CN rule-set")
    dns_match = first_matching_dns(domain, tcp_flow)
    if dns_match is None:
        domestic_failures.append(f"{domain}: domestic DNS unexpectedly used dns.final")
    else:
        dns_index, dns_rule, _ = dns_match
        if dns_rule.get("server") != "bootstrap-local-dns":
            domestic_failures.append(
                f"{domain}: DNS index={dns_index} server={dns_rule.get('server')} expected local"
            )
for domain in domestic_srs_probe_targets:
    matching_cn_rule_sets = {
        tag for tag in retained_canonical_cn_rule_sets if binary_rule_set_matches(tag, domain)
    }
    if not matching_cn_rule_sets:
        domestic_failures.append(f"{domain}: did not match any canonical binary CN rule-set")
if domestic_failures:
    raise AssertionError("domestic-first routing failures: " + "; ".join(domestic_failures))

foreign_results = {}
for domain in foreign_targets:
    index, rule, matching_rule_sets = first_matching_outbound(domain, tcp_flow)
    print(f"tcp-tls {domain} first-match index={index} outbound={rule.get('outbound')}")
    if rule.get("outbound") != "network-test":
        raise AssertionError(
            f"{domain} first matched route index={index} outbound={rule.get('outbound')} instead of network-test"
        )
    foreign_results[domain] = (index, rule, matching_rule_sets)

canonical_keyword_rule = {"domain_keyword": network_test_keywords, "outbound": "network-test"}
keyword_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == canonical_keyword_rule
]
if len(keyword_routes) != 1:
    raise AssertionError(f"expected one unchanged network-test keyword route, found {len(keyword_routes)}")
keyword_index, keyword_rule = keyword_routes[0]
network_test_keyword_set = set(network_test_keywords)
keyword_owners = [
    (index, rule, sorted(network_test_keyword_set & set(values(rule.get("domain_keyword")))))
    for index, rule in enumerate(rules)
    if network_test_keyword_set & set(values(rule.get("domain_keyword")))
]
if len(keyword_owners) != 1:
    owner_evidence = [
        {
            "index": index,
            "keywords": keywords,
            "outbound": rule.get("outbound"),
            "constraints": {
                key: value for key, value in rule.items() if key not in {"domain_keyword", "outbound"}
            },
        }
        for index, rule, keywords in keyword_owners
    ]
    raise AssertionError(f"broad network-test keywords must have one exclusive owner: {owner_evidence}")
if keyword_owners[0][0] != keyword_index or keyword_owners[0][1] != canonical_keyword_rule:
    raise AssertionError("broad network-test keyword owner is not the canonical unchanged route")
exact_suffix_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == {"domain_suffix": network_test_suffixes, "outbound": "network-test"}
]
if len(exact_suffix_routes) != 1:
    raise AssertionError(f"expected one unchanged foreign network-test suffix route, found {len(exact_suffix_routes)}")
exact_suffix_index, _ = exact_suffix_routes[0]
cn_direct_indexes = [
    index for index, rule in enumerate(rules)
    if rule.get("outbound") == "cn-direct"
]
if not cn_direct_indexes or not all(
    index < keyword_index for index in cn_direct_indexes
):
    raise AssertionError(
        f"destination/rule-set cn-direct routes must precede keyword route index={keyword_index}"
    )
canonical_cn_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule.get("outbound") == "cn-direct" and canonical_cn_rule_sets <= set(values(rule.get("rule_set")))
]
if len(canonical_cn_routes) != 1:
    raise AssertionError(f"expected one canonical CN rule-set route, found {len(canonical_cn_routes)}")
canonical_cn_index, _ = canonical_cn_routes[0]
pcdn_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == {"rule_set": "yuu-geosite-pcdn-cn", "outbound": "download-direct"}
]
explicit_game_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == {"domain_suffix": game_domain_suffixes, "outbound": "game-proxy"}
]
foreign_priority_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == foreign_priority_route_rule
]
if len(pcdn_routes) != 1 or len(explicit_game_routes) != 1 or len(foreign_priority_routes) != 1:
    raise AssertionError(
        "expected unique PCDN, explicit game, and foreign-priority routes: "
        f"pcdn={pcdn_routes} game={explicit_game_routes} foreign={foreign_priority_routes}"
    )
pcdn_index = pcdn_routes[0][0]
explicit_game_index = explicit_game_routes[0][0]
foreign_priority_index = foreign_priority_routes[0][0]
if not (
    pcdn_index + 1 == explicit_game_index
    and explicit_game_index + 1 == foreign_priority_index
    and foreign_priority_index + 1 == canonical_cn_index
):
    raise AssertionError(
        "required route order is PCDN < explicit game < foreign priority < canonical CN: "
        f"pcdn={pcdn_index} game={explicit_game_index} foreign={foreign_priority_index} "
        f"cn={canonical_cn_index}"
    )
if keyword_index != canonical_cn_index + 1:
    raise AssertionError(
        f"network-test keyword route index={keyword_index} must immediately follow canonical CN route index={canonical_cn_index}"
    )
generic_foreign_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule.get("outbound") == "proxy-rule" and generic_foreign_rule_sets <= set(values(rule.get("rule_set")))
]
if len(generic_foreign_routes) != 1 or not keyword_index < generic_foreign_routes[0][0]:
    raise AssertionError("network-test keyword route must precede the canonical generic foreign route")
specialized_outbounds = {"ai-proxy", "dev-proxy", "media-proxy", "game-proxy", "social-proxy", "telegram-proxy"}
specialized_rule_set_indexes = [
    index for index, rule in enumerate(rules)
    if rule.get("outbound") in specialized_outbounds and "rule_set" in rule
]
if not specialized_rule_set_indexes or not all(keyword_index < index for index in specialized_rule_set_indexes):
    raise AssertionError("network-test keyword route must precede specialized foreign rule-set routes")
if not exact_suffix_index < keyword_index:
    raise AssertionError("exact foreign network-test suffix route must precede keyword fallback")
for domain in ("speedtest.net", "connectivitycheck.gstatic.com", "api.nperf.com"):
    if foreign_results[domain][0] != exact_suffix_index:
        raise AssertionError(f"{domain} must use exact foreign network-test suffix route index={exact_suffix_index}")
if foreign_results["www.ookla.com"][0] != keyword_index:
    raise AssertionError(f"www.ookla.com must use keyword fallback index={keyword_index}")

download_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == {"domain_suffix": download_suffixes, "outbound": "download-direct"}
]
if len(download_routes) != 1:
    raise AssertionError(f"expected one unchanged all-network download route, found {len(download_routes)}")
download_index, _ = download_routes[0]
microsoft_route = {
    "domain_suffix": [
        "microsoft.com", "windows.com", "windowsupdate.com", "msftauth.net",
        "msauth.net", "office.com", "office365.com", "live.com", "msn.com",
    ],
    "outbound": "microsoft-cn",
}
microsoft_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule == microsoft_route
]
if len(microsoft_routes) != 1:
    raise AssertionError(f"expected one unchanged Microsoft exact route, found {len(microsoft_routes)}")
microsoft_index, _ = microsoft_routes[0]
canonical_media_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule.get("outbound") == "media-proxy"
    and required_media_sets <= set(values(rule.get("rule_set")))
]
if len(canonical_media_routes) != 1:
    raise AssertionError(f"expected one canonical media rule-set route, found {len(canonical_media_routes)}")
canonical_game_routes = [
    (index, rule) for index, rule in enumerate(rules)
    if rule.get("outbound") == "game-proxy" and "lyc-geosite-games" in values(rule.get("rule_set"))
]
if len(canonical_game_routes) != 1:
    raise AssertionError(f"expected one canonical game rule-set route, found {len(canonical_game_routes)}")
media_index = canonical_media_routes[0][0]
game_index = canonical_game_routes[0][0]
generic_index = generic_foreign_routes[0][0]
if not download_index < microsoft_index:
    raise AssertionError(
        f"download route index={download_index} must precede Microsoft exact route index={microsoft_index}"
    )
if not download_index < canonical_cn_index:
    raise AssertionError(
        f"download route index={download_index} must precede canonical CN route index={canonical_cn_index}"
    )
for (flow_name, domain), (first_index, actual_outbound, _) in download_results.items():
    if first_index != download_index or actual_outbound != "download-direct":
        raise AssertionError(
            f"{flow_name} {domain} must first-match unique download route index={download_index}: "
            f"actual index={first_index} outbound={actual_outbound}"
        )

specialized_fallback_indexes = []
specialized_rule_set_indexes_by_outbound = {}
for suffix_list, outbound in specialized_fallback_specs:
    expected_rule = {"domain_suffix": suffix_list, "outbound": outbound}
    matches = [index for index, rule in enumerate(rules) if rule == expected_rule]
    if len(matches) != 1:
        raise AssertionError(f"expected one unchanged explicit {outbound} fallback, found {len(matches)}")
    fallback_index = matches[0]
    specialized_fallback_indexes.append(fallback_index)
    specialized_matches = [
        index for index, rule in enumerate(rules)
        if rule.get("outbound") == outbound and "rule_set" in rule
    ]
    if len(specialized_matches) != 1:
        raise AssertionError(
            f"expected one specialized rule-set route for {outbound}, found {len(specialized_matches)}"
        )
    specialized_index = specialized_matches[0]
    specialized_rule_set_indexes_by_outbound[outbound] = specialized_index
    if fallback_index != specialized_index + 1:
        raise AssertionError(
            f"explicit {outbound} fallback index={fallback_index} must immediately follow "
            f"its specialized rule-set route index={specialized_index}"
        )

if specialized_fallback_indexes != sorted(specialized_fallback_indexes):
    raise AssertionError(f"explicit specialized fallback relative order changed: {specialized_fallback_indexes}")
if not all(index < generic_index for index in specialized_fallback_indexes):
    raise AssertionError("all explicit specialized fallback routes must precede the canonical generic route")
if generic_index != specialized_fallback_indexes[-1] + 1:
    raise AssertionError(
        f"canonical generic route index={generic_index} must immediately follow explicit specialized "
        f"fallback block ending at index={specialized_fallback_indexes[-1]}"
    )
telegram_ip_routes = [
    index for index, rule in enumerate(rules)
    if rule == {"ip_cidr": telegram_ip_cidrs, "outbound": "telegram-proxy"}
]
final_keyword_routes = [
    index for index, rule in enumerate(rules)
    if rule == {"domain_keyword": final_foreign_keywords, "outbound": "proxy-rule"}
]
if len(telegram_ip_routes) != 1 or telegram_ip_routes[0] != generic_index + 1:
    raise AssertionError(
        f"unchanged Telegram IP route must immediately follow generic route index={generic_index}: "
        f"actual={telegram_ip_routes}"
    )
if len(final_keyword_routes) != 1 or final_keyword_routes[0] != telegram_ip_routes[0] + 1:
    raise AssertionError(
        "unchanged final foreign keyword route must immediately follow the Telegram IP route: "
        f"actual={final_keyword_routes}"
    )
if final_keyword_routes[0] != len(rules) - 1:
    raise AssertionError(
        "final foreign keyword route must remain the last explicit route before route.final: "
        f"keyword={final_keyword_routes} rule_count={len(rules)}"
    )
PY

selector_fixture_dir=$(mktemp -d)
selector_jq_zero="$selector_fixture_dir/jq-zero.json"
selector_no_jq_zero="$selector_fixture_dir/no-jq-zero.json"
selector_jq_populated="$selector_fixture_dir/jq-populated.json"
selector_no_jq_populated="$selector_fixture_dir/no-jq-populated.json"
selector_direct_mutant="$selector_fixture_dir/direct-mutant.json"
selector_missing_block_mutant="$selector_fixture_dir/missing-block-mutant.json"
selector_jq_repaired="$selector_fixture_dir/jq-repaired.json"
selector_legacy_upgrade="$selector_fixture_dir/legacy-upgrade.json"
selector_no_jq_bin="$selector_fixture_dir/no-jq-bin"
mkdir -p "$selector_no_jq_bin"
ln -s "$(command -v awk)" "$selector_no_jq_bin/awk"
ln -s "$(command -v chmod)" "$selector_no_jq_bin/chmod"
ln -s "$CONFIG_DIR/rules" "$selector_fixture_dir/rules"
trap 'rm -rf "$selector_fixture_dir"' EXIT
export MODDIR="$selector_fixture_dir"

# config.sh materializes the optional proxy chain during subscription updates;
# load the shared helper explicitly so this standalone policy test matches the
# module entrypoint and package smoke environment.
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/chain.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"

write_fragment_config() {
    local fragment_file="$1" output_file="$2"
    {
        printf '{\n'
        cat "$fragment_file"
        printf '\n  "route": {"rules": []}\n}\n'
    } >"$output_file"
}

write_no_jq_config() {
    local tags_file="$1" node_json="$2" output_file="$3"
    {
        printf '{\n  "outbounds": [\n'
        magicnet_singbox_emit_selector_block "$tags_file"
        if [[ -n "$node_json" ]]; then
            printf ',\n    %s' "$node_json"
        fi
        printf ',\n    {"type":"direct","tag":"direct"},\n'
        printf '    {"type":"block","tag":"block"}\n'
        printf '  ],\n  "route": {"rules": []}\n}\n'
    } >"$output_file"
}

: >"$selector_fixture_dir/zero.tags"
printf '[]\n' >"$selector_fixture_dir/zero.nodes.json"
magicnet_singbox_build_outbounds_file_with_jq \
    "$selector_fixture_dir/zero.nodes.json" \
    "$selector_fixture_dir/zero.tags" \
    "$selector_fixture_dir/jq-zero.fragment"
write_fragment_config "$selector_fixture_dir/jq-zero.fragment" "$selector_jq_zero"
write_no_jq_config "$selector_fixture_dir/zero.tags" "" "$selector_no_jq_zero"

fixture_node='{"type":"vless","tag":"fixture-node","server":"example.com","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"}'
printf '[%s]\n' "$fixture_node" >"$selector_fixture_dir/populated.nodes.json"
printf 'fixture-node\n' >"$selector_fixture_dir/populated.tags"
magicnet_singbox_build_outbounds_file_with_jq \
    "$selector_fixture_dir/populated.nodes.json" \
    "$selector_fixture_dir/populated.tags" \
    "$selector_fixture_dir/jq-populated.fragment"
write_fragment_config "$selector_fixture_dir/jq-populated.fragment" "$selector_jq_populated"
write_no_jq_config "$selector_fixture_dir/populated.tags" "$fixture_node" "$selector_no_jq_populated"

for selector_config in \
    "$selector_jq_zero" "$selector_no_jq_zero" \
    "$selector_jq_populated" "$selector_no_jq_populated"; do
    jq -e 'all(.outbounds[]; .tag != "google-cn")' "$selector_config" >/dev/null ||
        fail "generated config retained google-cn before sanitization: $selector_config"
done

cmp <(jq -S -c '[.outbounds[] | select(.tag == "proxy" or .tag == "proxy-auto")]' \
        "$selector_jq_zero") \
    <(jq -S -c '[.outbounds[] | select(.tag == "proxy" or .tag == "proxy-auto")]' \
        "$selector_no_jq_zero") ||
    fail "zero-node jq and no-jq generators diverged"
cmp <(jq -S -c '[.outbounds[] | select(.tag == "proxy" or .tag == "proxy-auto")]' \
        "$selector_jq_populated") \
    <(jq -S -c '[.outbounds[] | select(.tag == "proxy" or .tag == "proxy-auto")]' \
        "$selector_no_jq_populated") ||
    fail "populated jq and no-jq generators diverged"

for selector_config in "$selector_jq_zero" "$selector_no_jq_zero"; do
    jq -e '
      [.outbounds[] | select(.tag == "proxy-auto")] == []
      and [.outbounds[] | select(.tag == "proxy")] == [
        {type: "selector", tag: "proxy", outbounds: ["block"], default: "block"}
      ]
      and [.outbounds[] | select(.tag == "network-test")] == [
        {type: "selector", tag: "network-test", outbounds: ["block"], default: "block"}
      ]
    ' "$selector_config" >/dev/null || fail "zero-node generator emitted a fail-open proxy selector"
done
for selector_config in "$selector_jq_populated" "$selector_no_jq_populated"; do
    jq -e '
      [.outbounds[] | select(.tag == "proxy-auto")] == [{
        type: "urltest", tag: "proxy-auto", outbounds: ["fixture-node"],
        url: "https://www.gstatic.com/generate_204", interval: "3m", tolerance: 30,
        idle_timeout: "10m", interrupt_exist_connections: false
      }]
      and [.outbounds[] | select(.tag == "proxy")] == [{
        type: "selector", tag: "proxy",
        outbounds: ["fixture-node", "proxy-auto", "direct", "block"],
        default: "fixture-node"
      }]
      and [.outbounds[] | select(.tag == "network-test")] == [{
        type: "selector", tag: "network-test",
        outbounds: ["proxy-auto", "proxy", "direct", "block"],
        default: "proxy-auto"
      }]
    ' "$selector_config" >/dev/null ||
        fail "populated generator changed canonical proxy or network-test behavior"
done

for selector_config in "$selector_jq_zero" "$selector_jq_populated"; do
    magicnet_singbox_sanitize_generated_config "$selector_config" ||
        fail "jq sanitizer rejected a canonical generated selector config"
done
for selector_config in "$selector_no_jq_zero" "$selector_no_jq_populated"; do
    (PATH="$selector_no_jq_bin"; magicnet_singbox_sanitize_generated_config "$selector_config") ||
        fail "no-jq sanitizer rejected a canonical generated selector config"
done
for selector_config in \
    "$selector_jq_zero" "$selector_no_jq_zero" \
    "$selector_jq_populated" "$selector_no_jq_populated"; do
    jq -e 'all(.outbounds[]; .tag != "google-cn")' "$selector_config" >/dev/null ||
        fail "sanitized generated config retained google-cn: $selector_config"
done

jq '.outbounds += [{
  type: "selector", tag: "google-cn",
  outbounds: ["proxy", "direct", "block"], default: "proxy"
}]' "$CONFIG_FILE" >"$selector_legacy_upgrade"
MAGICNET_SUB_CONFIG_FILE="$selector_legacy_upgrade" \
    magicnet_singbox_update_config_with_nodes "$selector_fixture_dir/jq-zero.fragment" ||
    fail "legacy google-cn config upgrade failed"
jq -e 'all(.outbounds[]; .tag != "google-cn")' "$selector_legacy_upgrade" >/dev/null ||
    fail "legacy config upgrade retained google-cn"
cmp <(jq -S -c '.outbounds' "$selector_jq_zero") \
    <(jq -S -c '.outbounds' "$selector_legacy_upgrade") ||
    fail "legacy config upgrade did not install canonical generated outbounds"
cmp <(jq -S -c '{dns, route}' "$CONFIG_FILE") \
    <(jq -S -c '{dns, route}' "$selector_legacy_upgrade") ||
    fail "legacy config upgrade changed base DNS or route policy"

jq '(.outbounds[] | select(.tag == "proxy")) |=
    (.outbounds = ["direct", "block"] | .default = "direct")' \
    "$selector_jq_zero" >"$selector_direct_mutant"
jq '(.outbounds[] | select(.tag == "proxy")) |=
    (.outbounds = ["direct"] | .default = "direct")' \
    "$selector_jq_zero" >"$selector_missing_block_mutant"
for selector_mutant in "$selector_direct_mutant" "$selector_missing_block_mutant"; do
    if magicnet_singbox_ai_selectors_canonical "$selector_mutant"; then
        fail "jq canonical validator accepted an unsafe zero-node proxy mutant"
    fi
    if (PATH="$selector_no_jq_bin"; magicnet_singbox_ai_selectors_canonical "$selector_mutant"); then
        fail "no-jq canonical validator accepted an unsafe zero-node proxy mutant"
    fi
done
cp "$selector_direct_mutant" "$selector_jq_repaired"
magicnet_singbox_sanitize_generated_config "$selector_jq_repaired" ||
    fail "jq sanitizer did not repair an unsafe zero-node proxy selector"
jq -e '[.outbounds[] | select(.tag == "proxy")] == [
    {type: "selector", tag: "proxy", outbounds: ["block"], default: "block"}
  ]' "$selector_jq_repaired" >/dev/null ||
    fail "jq sanitizer repair did not produce the canonical fail-closed proxy"
if (PATH="$selector_no_jq_bin"; magicnet_singbox_sanitize_generated_config "$selector_direct_mutant"); then
    fail "no-jq sanitizer accepted an unsafe zero-node proxy selector"
fi

rm -rf "$selector_fixture_dir"
selector_fixture_dir=
trap - EXIT

for route_expectation in \
    "connect.rom.miui.com cn-direct" \
    "connectivitycheck.platform.hicloud.com cn-direct" \
    "speedtest.net network-test" \
    "connectivitycheck.gstatic.com network-test"; do
    read -r route_domain expected_outbound <<<"$route_expectation"
    actual_outbound=$(first_matching_value route outbound "$route_domain") ||
        fail "no matching route for $route_domain"
    [[ "$actual_outbound" == "$expected_outbound" ]] ||
        fail "$route_domain first matched $actual_outbound instead of $expected_outbound"
done

hicloud_direct_index=$(jq -er '
  def values($value):
    if $value == null then []
    elif ($value | type) == "array" then $value
    else [$value]
    end;
  [.route.rules | to_entries[]
    | select(.value.outbound? == "cn-direct")
    | select((values(.value.domain_suffix?) | index("connectivitycheck.platform.hicloud.com")) != null)
    | .key]
  | if length == 1 then .[0] else empty end
' "$CONFIG_FILE") || fail "missing unique direct rule for connectivitycheck.platform.hicloud.com"
network_connectivity_keyword_index=$(jq -er '
  def values($value):
    if $value == null then []
    elif ($value | type) == "array" then $value
    else [$value]
    end;
  first(.route.rules | to_entries[]
    | select(.value.outbound? == "network-test")
    | select((values(.value.domain_keyword?) | index("connectivitycheck")) != null)
    | .key)
' "$CONFIG_FILE") || fail "missing network-test connectivitycheck keyword rule"
((hicloud_direct_index < network_connectivity_keyword_index)) ||
    fail "hicloud connectivity direct rule must precede broad network-test keyword rule"

assert_connectivity_dns_safety() {
    local config_file="$1"
    local default_mode direct_mode_index global_mode_index wechat_rule_index domestic_rule_index foreign_rule_index
    local apple_rule_index cn_bing_rule_index global_bing_rule_index local_service_index
    local private_dns_index mmstat_dns_index ad_suffix_dns_index ad_keyword_dns_index ad_rule_set_dns_index
    local game_dns_index foreign_priority_dns_index x_social_dns_index cn_dns_index
    local policy domain expected_server canonical_rule_index rule_index rule_result rule_server
    local first_match_found=false
    local -a connectivity_policies=()

    default_mode=$(jq -er '
      (.experimental.clash_api.default_mode // "Rule")
      | if type == "string" then . else empty end
    ' "$config_file") || {
        printf 'DNS safety guard: invalid Clash API default mode\n' >&2
        return 1
    }
    [[ "$default_mode" == "Rule" ]] || {
        printf 'DNS safety guard: default Clash mode must remain Rule\n' >&2
        return 1
    }
    read -r direct_mode_index global_mode_index wechat_rule_index domestic_rule_index foreign_rule_index \
        apple_rule_index cn_bing_rule_index global_bing_rule_index local_service_index \
        private_dns_index mmstat_dns_index ad_suffix_dns_index ad_keyword_dns_index ad_rule_set_dns_index \
        game_dns_index foreign_priority_dns_index x_social_dns_index cn_dns_index < <(jq -er '
      def unique_index($rule):
        [.dns.rules | to_entries[] | select(.value == $rule) | .key]
        | if length == 1 then .[0] else error("expected one exact DNS rule") end;
      [
        unique_index({clash_mode: "Direct", server: "bootstrap-local-dns"}),
        unique_index({clash_mode: "Global", server: "doh-cloudflare"}),
        unique_index({
          domain_suffix: [
            "qq.com", "weixin.qq.com", "wechat.com", "wechatapp.com", "wechatpay.cn",
            "tenpay.com", "tencent.com", "tencent-cloud.com", "myqcloud.com", "qcloud.com",
            "gtimg.com", "idqqimg.com", "qpic.cn", "qlogo.cn", "qmail.com", "smtcdns.com",
            "servicewechat.com", "weixinbridge.com", "weixinsxy.com", "wx.gtimg.com", "wx.qq.com"
          ],
          server: "bootstrap-local-dns"
        }),
        unique_index({
          domain_suffix: ["connect.rom.miui.com", "connectivitycheck.platform.hicloud.com"],
          server: "bootstrap-local-dns"
        }),
        unique_index({
          domain_suffix: [
            "msftconnecttest.com", "msftncsi.com", "connectivitycheck.gstatic.com",
            "connectivitycheck.android.com", "clients3.google.com", "www.gstatic.com",
            "gstatic.com", "gvt1.com", "gvt2.com", "captive.apple.com",
            "cp.cloudflare.com", "speed.cloudflare.com", "speedtest.net",
            "ooklaserver.net", "speedtestcdn.com", "fast.com", "nperf.com", "nperf.net",
            "testmy.net", "browserscan.net", "measurementlab.net",
            "speed.measurementlab.net", "speedof.me", "speedcheck.org"
          ],
          server: "doh-google"
        }),
        unique_index({
          domain_suffix: ["apple.com", "icloud.com", "icloud-content.com", "me.com"],
          server: "bootstrap-local-dns"
        }),
        unique_index({
          domain_suffix: ["cn.bing.com"],
          server: "bootstrap-local-dns"
        }),
        unique_index({
          domain_suffix: [
            "bing.com", "bingapis.com", "bing.net", "msn.com", "login.live.com",
            "account.live.com", "edgeservices.bing.com", "assets.msn.com",
            "c.bing.com", "r.bing.com", "www.bing.com"
          ],
          server: "doh-google"
        }),
        unique_index({
          domain_suffix: [
            "microsoft.com", "windows.com", "windowsupdate.com", "msftauth.net", "msauth.net",
            "office.com", "office365.com", "live.com", "steamserver.net", "steamcontent.com",
            "steamusercontent.com", "akamaihd.net", "hwcdn.net"
          ],
          server: "bootstrap-local-dns"
        }),
        unique_index({
          rule_set: ["lyc-geosite-private", "lyc-geoip-private"],
          server: "bootstrap-local-dns"
        }),
        unique_index({
          domain_suffix: ["mmstat.com"],
          server: "bootstrap-local-dns"
        }),
        unique_index({
          domain_suffix: [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com",
            "adservice.google.com", "adsystem.com", "adnxs.com", "scorecardresearch.com",
            "umeng.com", "umengcloud.com"
          ],
          server: "doh-cloudflare"
        }),
        unique_index({
          domain_keyword: ["adservice", "analytics", "tracking", "tracker"],
          server: "doh-cloudflare"
        }),
        unique_index({
          rule_set: [
            "lyc-geosite-ads", "hagezi-light", "hagezi-normal",
            "hagezi-anti-piracy", "karing-acl4ssr-banad"
          ],
          server: "doh-cloudflare"
        }),
        unique_index({
          domain_suffix: [
            "steamcommunity.com", "steampowered.com", "steamstatic.com", "epicgames.com",
            "epicgames.dev", "unrealengine.com", "paragon.com", "playstation.com",
            "playstation.net", "playstationnetwork.com", "sonyentertainmentnetwork.com",
            "xboxlive.com", "nintendo.net"
          ],
          server: "doh-cloudflare"
        }),
        unique_index({
          domain_suffix: [
            "acm.org", "acs.org", "aiaa.org", "amd.com", "annualreviews.org", "asm.org",
            "asme.org", "astm.org", "bmj.com", "cambridge.org", "cdn.jetbrains.com",
            "ieee.org", "nature.com", "sciencedirect.com", "springer.com", "wiley.com",
            "ams.org", "aps.org", "ascelibrary.org", "cas.org", "clarivate.com",
            "ebscohost.com", "emerald.com", "engineeringvillage.com",
            "icevirtuallibrary.com", "iop.org", "jamanetwork.com", "jstor.org", "karger.com",
            "oecd-ilibrary.org", "osapublishing.org", "oup.com", "ovid.com",
            "oxfordartonline.com", "oxfordbibliographies.com", "oxfordmusiconline.com",
            "pnas.org", "proquest.com", "rsc.org", "sagepub.com", "scopus.com", "siam.org",
            "spiedigitallibrary.org", "springerlink.com", "tandfonline.com", "udacity.com",
            "un.org", "webofknowledge.com", "westlaw.com", "worldscientific.com", "oracle.com",
            "sony.com", "teamviewer.com", "abercrombie.com", "hollisterco.com", "weather.com"
          ],
          server: "doh-google"
        }),
        unique_index({
          domain_suffix: ["twitter.com", "x.com", "twimg.com"],
          server: "doh-google"
        }),
        unique_index({
          rule_set: [
            "lyc-geosite-cn", "lyc-geosite-geolocation-cn", "lyc-geoip-cn",
            "metacubex-geoip-cn", "ddch-direct",
            "karing-acl4ssr-china-domain", "karing-acl4ssr-china-ip", "yuu-geosite-pcdn-cn"
          ],
          server: "bootstrap-local-dns"
        })
      ] | @tsv
    ' "$config_file") || {
        printf '%s\n' \
            'DNS safety guard: missing unique explicit DNS policy rule' >&2
        return 1
    }
    ((global_mode_index == direct_mode_index + 1 \
        && wechat_rule_index == global_mode_index + 1 \
        && domestic_rule_index == wechat_rule_index + 1 \
        && foreign_rule_index == domestic_rule_index + 1 \
        && apple_rule_index == foreign_rule_index + 1 \
        && cn_bing_rule_index == apple_rule_index + 1 \
        && global_bing_rule_index == cn_bing_rule_index + 1 \
        && local_service_index == global_bing_rule_index + 1 \
        && private_dns_index == local_service_index + 1 \
        && mmstat_dns_index == private_dns_index + 1 \
        && ad_suffix_dns_index == mmstat_dns_index + 1 \
        && ad_keyword_dns_index == ad_suffix_dns_index + 1 \
        && ad_rule_set_dns_index == ad_keyword_dns_index + 1 \
        && game_dns_index == ad_rule_set_dns_index + 1 \
        && foreign_priority_dns_index == game_dns_index + 1 \
        && x_social_dns_index == foreign_priority_dns_index + 1 \
        && cn_dns_index == x_social_dns_index + 1)) || {
        printf '%s\n' \
            'DNS safety guard: explicit DNS policy rules are not in canonical adjacent order' >&2
        return 1
    }
    connectivity_policies=(
        "connect.rom.miui.com bootstrap-local-dns $domestic_rule_index"
        "connectivitycheck.platform.hicloud.com bootstrap-local-dns $domestic_rule_index"
        "connectivitycheck.gstatic.com doh-google $foreign_rule_index"
        "connectivitycheck.android.com doh-google $foreign_rule_index"
        "clients3.google.com doh-google $foreign_rule_index"
        "msftconnecttest.com doh-google $foreign_rule_index"
        "msftncsi.com doh-google $foreign_rule_index"
        "captive.apple.com doh-google $foreign_rule_index"
        "apple.com bootstrap-local-dns $apple_rule_index"
        "www.apple.com bootstrap-local-dns $apple_rule_index"
        "www.icloud.com bootstrap-local-dns $apple_rule_index"
        "cdn.icloud-content.com bootstrap-local-dns $apple_rule_index"
        "www.me.com bootstrap-local-dns $apple_rule_index"
        "cn.bing.com bootstrap-local-dns $cn_bing_rule_index"
        "www.bing.com doh-google $global_bing_rule_index"
        "r.bing.com doh-google $global_bing_rule_index"
        "login.live.com doh-google $global_bing_rule_index"
        "account.live.com doh-google $global_bing_rule_index"
        "www.msn.com doh-google $global_bing_rule_index"
        "www.microsoft.com bootstrap-local-dns $local_service_index"
        "windowsupdate.com bootstrap-local-dns $local_service_index"
        "msftauth.net bootstrap-local-dns $local_service_index"
        "www.office.com bootstrap-local-dns $local_service_index"
        "www.live.com bootstrap-local-dns $local_service_index"
        "steamserver.net bootstrap-local-dns $local_service_index"
        "steamcontent.com bootstrap-local-dns $local_service_index"
        "akamaihd.net bootstrap-local-dns $local_service_index"
        "hwcdn.net bootstrap-local-dns $local_service_index"
        "mmstat.com bootstrap-local-dns $mmstat_dns_index"
        "doubleclick.net doh-cloudflare $ad_suffix_dns_index"
        "www.google-analytics.com doh-cloudflare $ad_keyword_dns_index"
        "outbrain.com doh-cloudflare $ad_rule_set_dns_index"
        "steamcommunity.com doh-cloudflare $game_dns_index"
        "steampowered.com doh-cloudflare $game_dns_index"
        "steamstatic.com doh-cloudflare $game_dns_index"
        "epicgames.com doh-cloudflare $game_dns_index"
        "epicgames.dev doh-cloudflare $game_dns_index"
        "unrealengine.com doh-cloudflare $game_dns_index"
        "paragon.com doh-cloudflare $game_dns_index"
        "playstation.com doh-cloudflare $game_dns_index"
        "playstation.net doh-cloudflare $game_dns_index"
        "playstationnetwork.com doh-cloudflare $game_dns_index"
        "sonyentertainmentnetwork.com doh-cloudflare $game_dns_index"
        "xboxlive.com doh-cloudflare $game_dns_index"
        "nintendo.net doh-cloudflare $game_dns_index"
    )

    for policy in "${connectivity_policies[@]}"; do
        read -r domain expected_server canonical_rule_index <<<"$policy"
        first_match_found=false
        for ((rule_index = 0; rule_index <= canonical_rule_index; rule_index++)); do
            rule_result=$(dns_rule_match_result \
                "$config_file" "$rule_index" "$domain" "$default_mode") || return 1
            if [[ "$rule_result" == "match" ]]; then
                rule_server=$(jq -er --argjson index "$rule_index" '
                  .dns.rules[$index].server
                  | if type == "string" and length > 0 then . else empty end
                ' "$config_file") || {
                    printf 'DNS safety guard: matching rule index=%s has no valid server\n' \
                        "$rule_index" >&2
                    return 1
                }
                printf 'DNS Rule %s first-match index=%s server=%s\n' \
                    "$domain" "$rule_index" "$rule_server"
                [[ "$rule_server" == "$expected_server" ]] || {
                    printf '%s\n' \
                        "DNS safety guard: $domain matches earlier wrong DNS rule index=$rule_index expected=$expected_server actual=$rule_server" >&2
                    return 1
                }
                first_match_found=true
                break
            fi
        done
        [[ "$first_match_found" == "true" ]] || {
            printf '%s\n' \
                "DNS safety guard: no DNS rule matched $domain through its explicit connectivity policy rule" >&2
            return 1
        }
    done
}

dns_rule_match_result() {
    local config_file="$1"
    local rule_index="$2"
    local domain="$3"
    local default_mode="$4"
    local has_domain_group has_clash_mode has_package_name has_rule_set invert
    local domain_matches=true clash_mode_matches=true package_name_matches=true rule_set_matches=true
    local rule_set_tag rule_set_path rule_set_file rule_set_output
    local config_base
    local -a rule_set_tags=()

    jq -e --argjson index "$rule_index" '
      def string_values($value):
        ($value | type) == "string"
        or (($value | type) == "array" and all($value[]; type == "string"));
      .dns.rules[$index] as $rule
      | ($rule | type) == "object"
        and (((($rule | has("type")) | not) or $rule.type == "default"))
        and (((($rule | has("invert")) | not) or ($rule.invert | type) == "boolean"))
        and (((($rule | has("domain")) | not) or string_values($rule.domain)))
        and (((($rule | has("domain_suffix")) | not) or string_values($rule.domain_suffix)))
        and (((($rule | has("domain_keyword")) | not) or string_values($rule.domain_keyword)))
        and (((($rule | has("clash_mode")) | not) or string_values($rule.clash_mode)))
        and (((($rule | has("package_name")) | not) or string_values($rule.package_name)))
        and (((($rule | has("rule_set")) | not) or string_values($rule.rule_set)))
        and ((($rule | keys) - [
          "clash_mode",
          "domain",
          "domain_keyword",
          "domain_suffix",
          "invert",
          "package_name",
          "rule_set",
          "server",
          "type"
        ]) | length == 0)
    ' "$config_file" >/dev/null || {
        printf '%s\n' \
            "DNS safety guard: rule index=$rule_index has a logical, invalid, or unmodeled matcher" >&2
        return 1
    }

    has_domain_group=$(jq -r --argjson index "$rule_index" '
      .dns.rules[$index]
      | has("domain") or has("domain_suffix") or has("domain_keyword")
    ' "$config_file")
    if [[ "$has_domain_group" == "true" ]]; then
        domain_matches=$(jq -r --argjson index "$rule_index" --arg domain "$domain" '
          def values($value):
            if $value == null then []
            elif ($value | type) == "array" then $value
            else [$value]
            end;
          .dns.rules[$index] as $rule
          | ((values($rule.domain?) | index($domain)) != null)
            or any(values($rule.domain_suffix?)[]; . as $suffix
              | $domain == $suffix or ($domain | endswith("." + $suffix)))
            or any(values($rule.domain_keyword?)[]; . as $keyword
              | $domain | contains($keyword))
        ' "$config_file")
    fi

    has_clash_mode=$(jq -r --argjson index "$rule_index" '
      .dns.rules[$index] | has("clash_mode")
    ' "$config_file")
    if [[ "$has_clash_mode" == "true" ]]; then
        clash_mode_matches=$(jq -r \
            --argjson index "$rule_index" \
            --arg default_mode "$default_mode" '
          def values($value):
            if ($value | type) == "array" then $value else [$value] end;
          values(.dns.rules[$index].clash_mode) | index($default_mode) != null
        ' "$config_file")
    fi

    has_package_name=$(jq -r --argjson index "$rule_index" '
      .dns.rules[$index] | has("package_name")
    ' "$config_file")
    if [[ "$has_package_name" == "true" ]]; then
        package_name_matches=false
    fi

    has_rule_set=$(jq -r --argjson index "$rule_index" '
      .dns.rules[$index] | has("rule_set")
    ' "$config_file")
    if [[ "$has_rule_set" == "true" ]]; then
        rule_set_matches=false
        mapfile -t rule_set_tags < <(jq -r --argjson index "$rule_index" '
          def values($value):
            if ($value | type) == "array" then $value else [$value] end;
          values(.dns.rules[$index].rule_set)[]
        ' "$config_file")
        config_base=$(cd "$(dirname "$config_file")" && pwd)
        for rule_set_tag in "${rule_set_tags[@]}"; do
            rule_set_path=$(jq -er --arg tag "$rule_set_tag" '
              [.route.rule_set[]? | select(.tag == $tag)] as $definitions
              | if ($definitions | length) == 1
                  and $definitions[0].type == "local"
                  and $definitions[0].format == "binary"
                  and ($definitions[0].path | type) == "string"
                  and ($definitions[0].path | length) > 0
                then $definitions[0].path
                else empty
                end
            ' "$config_file") || {
                printf '%s\n' \
                    "DNS safety guard: rule-set $rule_set_tag is missing, non-unique, non-local, or non-binary" >&2
                return 1
            }
            if [[ "$rule_set_path" == /* ]]; then
                rule_set_file="$rule_set_path"
            else
                rule_set_file="$config_base/$rule_set_path"
            fi
            [[ -f "$rule_set_file" ]] || {
                printf '%s\n' \
                    "DNS safety guard: rule-set binary does not exist: $rule_set_file" >&2
                return 1
            }
            rule_set_output=$(sing-box rule-set match -f binary \
                "$rule_set_file" "$domain" 2>&1) || {
                printf '%s\n' \
                    "DNS safety guard: sing-box failed to match rule-set $rule_set_tag" >&2
                return 1
            }
            if [[ -n "$rule_set_output" ]]; then
                rule_set_matches=true
            fi
        done
    fi

    invert=$(jq -r --argjson index "$rule_index" '
      .dns.rules[$index].invert // false
    ' "$config_file")
    if [[ "$domain_matches" == "true" \
        && "$clash_mode_matches" == "true" \
        && "$package_name_matches" == "true" \
        && "$rule_set_matches" == "true" ]]; then
        if [[ "$invert" == "true" ]]; then
            printf 'no-match\n'
        else
            printf 'match\n'
        fi
    elif [[ "$invert" == "true" ]]; then
        printf 'match\n'
    else
        printf 'no-match\n'
    fi
}

jq -e '
  ([.dns.rules | to_entries[]
    | select(.value == {
        domain_suffix: [
          "msftconnecttest.com", "msftncsi.com", "connectivitycheck.gstatic.com",
          "connectivitycheck.android.com", "clients3.google.com", "www.gstatic.com",
          "gstatic.com", "gvt1.com", "gvt2.com", "captive.apple.com",
          "cp.cloudflare.com", "speed.cloudflare.com", "speedtest.net",
          "ooklaserver.net", "speedtestcdn.com", "fast.com", "nperf.com", "nperf.net",
          "testmy.net", "browserscan.net", "measurementlab.net",
          "speed.measurementlab.net", "speedof.me", "speedcheck.org"
        ],
        server: "doh-google"
      }) | .key] | if length == 1 then .[0] else error("missing foreign rule") end) as $foreign
  | ([.dns.rules | to_entries[]
    | select(.value == {
        domain_suffix: ["apple.com", "icloud.com", "icloud-content.com", "me.com"],
        server: "bootstrap-local-dns"
      }) | .key] | if length == 1 then .[0] else error("missing Apple/iCloud rule") end) as $apple
  | ([.dns.rules | to_entries[]
    | select(.value == {
        domain_suffix: ["cn.bing.com"],
        server: "bootstrap-local-dns"
      }) | .key] | if length == 1 then .[0] else error("missing cn.bing.com local rule") end) as $cn_bing
  | ([.dns.rules | to_entries[]
    | select(.value == {
        domain_suffix: [
          "bing.com", "bingapis.com", "bing.net", "msn.com", "login.live.com",
          "account.live.com", "edgeservices.bing.com", "assets.msn.com",
          "c.bing.com", "r.bing.com", "www.bing.com"
        ],
        server: "doh-google"
      }) | .key] | if length == 1 then .[0] else error("missing global Bing rule") end) as $global_bing
  | ([.dns.rules | to_entries[]
    | select(.value == {
        domain_suffix: [
          "microsoft.com", "windows.com", "windowsupdate.com", "msftauth.net", "msauth.net",
          "office.com", "office365.com", "live.com", "steamserver.net", "steamcontent.com",
          "steamusercontent.com", "akamaihd.net", "hwcdn.net"
        ],
        server: "bootstrap-local-dns"
      }) | .key] | if length == 1 then .[0] else error("missing local service rule") end) as $local
  | [.dns.rules | to_entries[] | select(.value | has("rule_set")) | .key] as $rule_sets
  | $apple == $foreign + 1
    and $cn_bing == $apple + 1
    and $global_bing == $cn_bing + 1
    and $local == $global_bing + 1
    and ($rule_sets | length) > 0
    and all($rule_sets[]; . > $local)
' "$CONFIG_FILE" >/dev/null ||
    fail "explicit DNS policy rules are not unique, canonical, adjacent, and before all rule-set classifiers"

assert_connectivity_dns_safety "$CONFIG_FILE" ||
    fail "could not prove ordered DNS safety for connectivity checks"
for dns_overlap_domain in \
    epicgames.dev unrealengine.com paragon.com playstation.com \
    playstationnetwork.com sonyentertainmentnetwork.com; do
    dns_overlap_output=$(sing-box rule-set match -f binary \
        "$CONFIG_DIR/rules/karing-acl4ssr-china-domain.srs" \
        "$dns_overlap_domain" 2>&1) ||
        fail "could not query overlapping China DNS rule-set for $dns_overlap_domain"
    [[ -n "$dns_overlap_output" ]] ||
        fail "$dns_overlap_domain must overlap karing China DNS rule-set"
done

make_dns_safety_fixture() {
    local inserted_rules="$1"
    local output_file="$2"
    jq --argjson inserted_rules "$inserted_rules" --arg config_dir "$CONFIG_DIR" '
      ($inserted_rules | if type == "array" then . else [.] end) as $rules
      | .dns.rules = ($rules + .dns.rules)
      | .route.rule_set |= map(
          if .type == "local"
            and (.path | type) == "string"
            and (.path | startswith("/") | not)
          then .path = ($config_dir + "/" + .path)
          else .
          end
        )
    ' "$CONFIG_FILE" >"$output_file"
}

dns_fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-dns-policy.XXXXXX")
dns_unconditional_fixture="$dns_fixture_dir/unconditional.json"
dns_local_unconditional_fixture="$dns_fixture_dir/local-unconditional.json"
dns_invert_fixture="$dns_fixture_dir/invert.json"
dns_current_mode_fixture="$dns_fixture_dir/current-mode.json"
dns_other_mode_fixture="$dns_fixture_dir/other-mode.json"
dns_first_match_fixture="$dns_fixture_dir/first-match.json"
dns_remote_rule_set_fixture="$dns_fixture_dir/remote-rule-set.json"
touch "$dns_unconditional_fixture" "$dns_local_unconditional_fixture" "$dns_invert_fixture" \
    "$dns_current_mode_fixture" "$dns_other_mode_fixture" "$dns_first_match_fixture" \
    "$dns_remote_rule_set_fixture"
trap 'rm -rf "$dns_fixture_dir"' EXIT

make_dns_safety_fixture '{"server":"doh-google"}' "$dns_unconditional_fixture"
make_dns_safety_fixture '{"server":"bootstrap-local-dns"}' "$dns_local_unconditional_fixture"
make_dns_safety_fixture \
    '{"rule_set":"lyc-geosite-ai","invert":true,"server":"doh-google"}' \
    "$dns_invert_fixture"
make_dns_safety_fixture \
    '{"clash_mode":"Rule","domain":"connect.rom.miui.com","server":"doh-google"}' \
    "$dns_current_mode_fixture"
make_dns_safety_fixture \
    '[
      {"clash_mode":"Global","domain":"connect.rom.miui.com","server":"doh-google"},
      {"clash_mode":"Global","domain":"connectivitycheck.gstatic.com","server":"bootstrap-local-dns"}
    ]' \
    "$dns_other_mode_fixture"
make_dns_safety_fixture \
    '{"domain":"connect.rom.miui.com","rule_set":"lyc-geosite-cn","server":"doh-google"}' \
    "$dns_remote_rule_set_fixture"
make_dns_safety_fixture '[
  {
    "domain": [
      "connect.rom.miui.com",
      "connectivitycheck.platform.hicloud.com"
    ],
    "server": "bootstrap-local-dns"
  },
  {
    "domain": [
      "connectivitycheck.gstatic.com",
      "clients3.google.com"
    ],
    "server": "doh-google"
  },
  {
    "domain": [
      "connect.rom.miui.com",
      "connectivitycheck.platform.hicloud.com"
    ],
    "server": "doh-google"
  },
  {
    "domain": [
      "connectivitycheck.gstatic.com",
      "clients3.google.com"
    ],
    "server": "bootstrap-local-dns"
  }
]' "$dns_first_match_fixture"

for dns_fixture in \
    "$dns_unconditional_fixture" \
    "$dns_local_unconditional_fixture" \
    "$dns_invert_fixture" \
    "$dns_current_mode_fixture" \
    "$dns_other_mode_fixture" \
    "$dns_first_match_fixture" \
    "$dns_remote_rule_set_fixture"; do
    (cd "$CONFIG_DIR" && sing-box check -c "$dns_fixture" >/dev/null) ||
        fail "synthetic DNS safety fixture is not sing-box-valid: $dns_fixture"
done
if dns_guard_output=$(assert_connectivity_dns_safety "$dns_unconditional_fixture" 2>&1); then
    fail "DNS safety guard accepted an earlier unconditional remote rule"
fi
[[ "$dns_guard_output" == *"connect.rom.miui.com matches earlier wrong DNS rule index=0 expected=bootstrap-local-dns actual=doh-google"* ]] ||
    fail "DNS safety guard rejected the unconditional fixture for the wrong reason"
if dns_guard_output=$(assert_connectivity_dns_safety "$dns_local_unconditional_fixture" 2>&1); then
    fail "DNS safety guard accepted an earlier unconditional local rule for foreign connectivity"
fi
[[ "$dns_guard_output" == *"connectivitycheck.gstatic.com matches earlier wrong DNS rule index=0 expected=doh-google actual=bootstrap-local-dns"* ]] ||
    fail "DNS safety guard rejected the local unconditional fixture for the wrong reason"
if dns_guard_output=$(assert_connectivity_dns_safety "$dns_invert_fixture" 2>&1); then
    fail "DNS safety guard accepted an earlier inverted remote rule-set"
fi
[[ "$dns_guard_output" == *"connect.rom.miui.com matches earlier wrong DNS rule"* ]] ||
    fail "DNS safety guard rejected the inverted fixture for the wrong reason"
if dns_guard_output=$(assert_connectivity_dns_safety "$dns_current_mode_fixture" 2>&1); then
    fail "DNS safety guard accepted an earlier current-mode remote rule"
fi
[[ "$dns_guard_output" == *"connect.rom.miui.com matches earlier wrong DNS rule"* ]] ||
    fail "DNS safety guard rejected the current-mode fixture for the wrong reason"
if dns_guard_output=$(assert_connectivity_dns_safety "$dns_remote_rule_set_fixture" 2>&1); then
    fail "DNS safety guard accepted an earlier matching remote rule-set"
fi
[[ "$dns_guard_output" == *"matches earlier wrong DNS rule index=0 expected=bootstrap-local-dns actual=doh-google"* ]] ||
    fail "DNS safety guard rejected the remote rule-set fixture for the wrong reason"
assert_connectivity_dns_safety "$dns_other_mode_fixture" ||
    fail "DNS safety guard rejected a non-current Clash mode rule"
assert_connectivity_dns_safety "$dns_first_match_fixture" ||
    fail "DNS safety guard continued after a matching policy rule"

rm -f "$dns_unconditional_fixture" "$dns_local_unconditional_fixture" "$dns_invert_fixture" \
    "$dns_current_mode_fixture" "$dns_other_mode_fixture" "$dns_first_match_fixture" \
    "$dns_remote_rule_set_fixture"
rmdir "$dns_fixture_dir" 2>/dev/null || true
dns_fixture_dir=
dns_unconditional_fixture=
dns_local_unconditional_fixture=
dns_invert_fixture=
dns_current_mode_fixture=
dns_other_mode_fixture=
dns_first_match_fixture=
dns_remote_rule_set_fixture=
trap - EXIT
unset route_expectation route_domain expected_outbound actual_outbound
unset hicloud_direct_index network_connectivity_keyword_index dns_fixture dns_guard_output

jq -e '
  def has_rule_set($tag):
    (.rule_set? // []) as $rule_sets
    | if ($rule_sets | type) == "array"
      then ($rule_sets | index($tag)) != null
      else $rule_sets == $tag
      end;
  ["lyc-geoip-cn", "metacubex-geoip-cn", "karing-acl4ssr-china-ip"] as $cn_ip_sets
  | (.route.rules | to_entries) as $indexed_rules
  | ([$indexed_rules[]
      | select(.value == {protocol: "dns", action: "hijack-dns"})]) as $dns_hijack_rules
  | ([$indexed_rules[]
      | select(.value == {protocol: "icmp", outbound: "block"})]) as $icmp_block_rules
  | ([$indexed_rules[] | select(.value.ip_version? == 6)]) as $ipv6_rules
  | ([$indexed_rules[] | select(.value.outbound? == "cn-direct")]) as $cn_direct_rules
  | .route.final == "final"
    and (($dns_hijack_rules | length) > 0)
    and (($icmp_block_rules | length) > 0)
    and (($ipv6_rules | length) == 0)
    and (($cn_direct_rules | length) > 0)
    and ([.outbounds[] | select(.tag == "cn-direct")] == [
      {type: "selector", tag: "cn-direct", outbounds: ["direct", "proxy", "block"], default: "direct"}
    ])
    and ([.outbounds[] | select(.tag == "final")] == [
      {type: "selector", tag: "final", outbounds: ["proxy", "direct", "block"], default: "proxy"}
    ])
    and all(.route.rules[]; ((.outbound == "cn-direct" and has("ip_cidr")) | not))
    and any(.route.rules[]; . as $rule
      | $rule.outbound == "cn-direct"
        and ($cn_ip_sets | all(. as $tag | $rule | has_rule_set($tag))))
    and any(.route.rules[]; .outbound == "proxy-rule"
      and has_rule_set("metacubex-geosite-geolocation-not-cn"))
' "$CONFIG_FILE" >/dev/null || fail "base config routing assertions failed"

for rule_tag in lyc-geoip-cn metacubex-geoip-cn karing-acl4ssr-china-ip; do
    rule_path=$(jq -er --arg tag "$rule_tag" '
      [.route.rule_set[]
        | select(.tag == $tag and .type == "local" and (.path | type) == "string")
        | .path]
      | if length == 1 then .[0] else empty end
    ' "$CONFIG_FILE") || fail "missing unique local rule-set definition: $rule_tag"
    [[ "$rule_path" == *.srs ]] || fail "rule-set path is not an .srs file: $rule_tag"
    rule_file="$CONFIG_DIR/$rule_path"
    [[ -f "$rule_file" ]] || fail "missing binary rule-set file: $rule_path"

    match_output=$(sing-box rule-set match -f binary "$rule_file" 114.114.114.114 2>&1) ||
        fail "sing-box match command failed for $rule_tag"
    [[ -n "$match_output" ]] || fail "114.114.114.114 did not match $rule_tag"

    foreign_output=$(sing-box rule-set match -f binary "$rule_file" 103.21.244.1 2>&1) ||
        fail "sing-box non-match command failed for $rule_tag"
    [[ -z "$foreign_output" ]] || fail "103.21.244.1 unexpectedly matched $rule_tag"
done

printf 'default routing policy test passed\n'
