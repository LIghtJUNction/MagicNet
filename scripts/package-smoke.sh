#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="${1:-}"

if [[ -z "$ZIP_PATH" ]]; then
    module_id="$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$ROOT/kam.toml" | head -n1)"
    ZIP_PATH="$ROOT/dist/${module_id}.zip"
elif [[ "$ZIP_PATH" != /* ]]; then
    ZIP_PATH="$ROOT/$ZIP_PATH"
fi

fail() {
    printf 'package smoke failed: %s\n' "$*" >&2
    exit 1
}

require_entry() {
    local entry="$1"
    grep -Fx "$entry" "$entries_file" >/dev/null || fail "missing zip entry: $entry"
}

for tool in file grep jq python3 readelf sed unzip zipinfo; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

[[ -f "$ZIP_PATH" ]] || fail "zip not found: $ZIP_PATH"
unzip -tq "$ZIP_PATH"

entries_file="$(mktemp)"
elf_tmp="$(mktemp -d)"
cleanup() {
    rm -f "$entries_file"
    rm -rf "$elf_tmp"
}
trap cleanup EXIT
unzip -Z1 "$ZIP_PATH" >"$entries_file"

if grep -Eq '(^/)|((^|/)\.\.(/|$))' "$entries_file"; then
    fail "zip contains an unsafe absolute or parent-traversal entry"
fi

require_entry module.prop
require_entry customize.sh
require_entry cli
require_entry bin/magicnet-cli
require_entry bin/magicnet-mcp-server
require_entry bin/sing-box
require_entry bin/ecapture
require_entry lib/kamfw/watchdog.sh
require_entry lib/kamfw/fswatch.sh
require_entry lib/kamfw/__singbox__.sh
require_entry lib/magicnet_singbox_subscribe.sh
require_entry lib/magicnet/transparent.sh
require_entry .config/sing-box/config.json
for entry in common fetch parse config proxylink update; do
    require_entry "lib/magicnet/singbox_subscribe/$entry.sh"
done

require_executable_entry() {
    local entry="$1"
    zipinfo -l "$ZIP_PATH" "$entry" 2>/dev/null | grep -E '^-rwx' >/dev/null \
        || fail "$entry is not executable in zip"
}

require_android_arm64_elf() {
    local entry="$1"
    local output
    unzip -oq "$ZIP_PATH" "$entry" -d "$elf_tmp"
    output="$(file -L "$elf_tmp/$entry")"
    grep -F 'ELF 64-bit' <<<"$output" >/dev/null \
        || fail "$entry is not an ELF64 binary: $output"
    grep -F 'ARM aarch64' <<<"$output" >/dev/null \
        || fail "$entry is not AArch64: $output"
    if ! grep -F 'interpreter /system/bin/linker64' <<<"$output" >/dev/null \
        && ! grep -F 'statically linked' <<<"$output" >/dev/null; then
        fail "$entry is neither linked for Android linker64 nor static: $output"
    fi
    readelf -h "$elf_tmp/$entry" | grep -F 'Machine:                           AArch64' >/dev/null \
        || fail "$entry ELF machine is not AArch64"
}

for entry in cli bin/magicnet-cli bin/magicnet-mcp-server bin/sing-box bin/ecapture; do
    require_executable_entry "$entry"
done

for entry in cli bin/magicnet-cli bin/magicnet-mcp-server bin/sing-box bin/ecapture; do
    require_android_arm64_elf "$entry"
done

if grep -E '(^|/)\.git($|/)' "$entries_file" >/dev/null; then
    fail "zip contains .git metadata"
fi

legacy_bin_pattern='^\.local/'"bin"
if grep -E "$legacy_bin_pattern" "$entries_file" >/dev/null; then
    fail "zip contains legacy runtime bin entries"
fi

if grep -Fx '.local/subscriptions.env' "$entries_file" >/dev/null; then
    fail "zip contains local subscription memory"
fi

if grep -E '(^|/)(mihomo|__mihomo__)(\.sh)?($|/)' "$entries_file" >/dev/null; then
    fail "zip contains legacy mihomo entries"
fi

if grep -E '(^|/)\.local/bin($|/)' "$entries_file" >/dev/null; then
    fail "zip contains legacy .local/bin runtime entries"
fi

if unzip -p "$ZIP_PATH" .config/kamfw/.envrc 2>/dev/null | grep -Eq 'MAGIC_(MIHOMO|HOTSPOT_FORWARD|VPN_COEXIST)'; then
    fail "kamfw env exports legacy runtime flags"
fi

if grep -E '(^|/)(capture_(common|mihomo|singbox)\.sh|capture\.conf|post-fs-data\.sh|sepolice\.rule|system/etc/security/cacerts)(/|$)' "$entries_file" >/dev/null; then
    fail "zip contains legacy proxy-capture entries"
fi

if grep -Fx 'bin/magicnet-ebpf' "$entries_file" >/dev/null; then
    fail "zip contains the removed eBPF runtime binary"
fi

if grep -E '^\.config/sing-box/\.dns-.*\.json$' "$entries_file" >/dev/null; then
    fail "zip contains routing test fixtures"
fi

check_no_subscription_secret() {
    local entry="$1"
    grep -Fx "$entry" "$entries_file" >/dev/null || return 0
    if unzip -p "$ZIP_PATH" "$entry" | grep -Eiq '^[[:space:]]*[^#[:space:]].*(https?://|ss://|trojan://|vmess://|vless://|hysteria2://|tuic://|socks://|socks5://|sub=|token=|uuid=|password=|passwd=)'; then
        fail "$entry contains subscription-like secrets"
    fi
}

check_no_subscription_secret '.config/sing-box/subscription.url'
check_no_subscription_secret '.config/sing-box/subscription.local'

subscription_module_root="$elf_tmp/subscription-module"
mkdir -p "$subscription_module_root"
unzip -oq "$ZIP_PATH" \
    'lib/magicnet_singbox_subscribe.sh' \
    'lib/magicnet/singbox_subscribe/*.sh' \
    -d "$subscription_module_root"
bash "$ROOT/scripts/singbox-subscription-protocol-smoke.sh" "$subscription_module_root"

transparent_module_root="$elf_tmp/transparent-module"
mkdir -p "$transparent_module_root/lib/magicnet"
unzip -p "$ZIP_PATH" lib/magicnet/transparent.sh \
    >"$transparent_module_root/lib/magicnet/transparent.sh"
if command -v sing-box >/dev/null 2>&1; then
    bash "$ROOT/scripts/orchestrator-mode-smoke.sh" \
        "$transparent_module_root/lib/magicnet/transparent.sh"
else
    printf '%s\n' 'package smoke: host sing-box unavailable; orchestrator runtime smoke skipped'
fi

route_fixture_dir="$elf_tmp/route-config"
mkdir -p "$route_fixture_dir"
unzip -p "$ZIP_PATH" lib/kamfw/__singbox__.sh >"$route_fixture_dir/__singbox__.sh"
cat >"$route_fixture_dir/config.json" <<'JSON'
{
  "route": {
    "auto_detect_interface": false,
    "default_interface": "rmnet_data3",
    "rules": []
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "bind_interface": "rmnet_data3"
    },
    {
      "type": "urltest",
      "tag": "proxy-auto",
      "interrupt_exist_connections": false,
      "outbounds": ["proxy", "direct"]
    },
    {
      "type": "selector",
      "tag": "proxy-rule",
      "outbounds": ["proxy", "direct"]
    },
    {
      "type": "selector",
      "tag": "network-test",
      "interrupt_exist_connections": false,
      "outbounds": ["proxy", "direct"]
    }
  ]
}
JSON

(
    import() { :; }
    set_i18n() { :; }
    # shellcheck disable=SC2034
    MODDIR="$route_fixture_dir"
    # shellcheck disable=SC1091
    . "$route_fixture_dir/__singbox__.sh"
    singbox_prepare_route_config "$route_fixture_dir/config.json"
)

jq -e '
    .route.auto_detect_interface == false
    and (.route | has("default_interface") | not)
    and ([.outbounds[] | select(.type == "direct") | has("bind_interface")] | all(. == false))
    and ([.outbounds[] | select(.type == "selector") | .interrupt_exist_connections] | all(. == true))
    and ([.outbounds[] | select(.type == "urltest") | .interrupt_exist_connections] == [false])
' "$route_fixture_dir/config.json" >/dev/null \
    || fail "sing-box route preparation did not delegate interface changes to Android"

route_no_jq_dir="$elf_tmp/route-config-no-jq"
route_no_jq_bin="$route_no_jq_dir/bin"
mkdir -p "$route_no_jq_bin"
for tool in awk mv rm; do
    ln -s "$(command -v "$tool")" "$route_no_jq_bin/$tool"
done
cp "$route_fixture_dir/__singbox__.sh" "$route_no_jq_dir/__singbox__.sh"
cat >"$route_no_jq_dir/config.json" <<'JSON'
{
  "route": {
    "auto_detect_interface": false,
    "default_interface": "rmnet_data3",
    "rules": []
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "bind_interface": "rmnet_data3"
    },
    {
      "type": "urltest",
      "tag": "proxy-auto",
      "interrupt_exist_connections": false,
      "outbounds": ["proxy", "direct"]
    },
    {
      "type": "selector",
      "tag": "proxy-} { } path\\segment \"quoted\"",
      "interrupt_exist_connections": false,
      "outbounds": ["proxy", "direct"]
    }
  ]
}
JSON

(
    import() { :; }
    set_i18n() { :; }
    # shellcheck disable=SC2034
    MODDIR="$route_no_jq_dir"
    PATH="$route_no_jq_bin"
    export PATH
    # shellcheck disable=SC1091
    . "$route_no_jq_dir/__singbox__.sh"
    singbox_prepare_route_config "$route_no_jq_dir/config.json"
)

jq -e '
    .route.auto_detect_interface == false
    and (.route | has("default_interface") | not)
    and ([.outbounds[] | select(.type == "direct") | has("bind_interface")] | all(. == false))
    and ([.outbounds[] | select(.type == "selector") | .interrupt_exist_connections] == [true])
    and ([.outbounds[] | select(.type == "urltest") | .interrupt_exist_connections] == [false])
' "$route_no_jq_dir/config.json" >/dev/null \
    || fail "sing-box no-jq route preparation changed URLTest interruption semantics"

python3 - "$ZIP_PATH" <<'PY'
import functools
import ipaddress
import json
import os
import posixpath
import subprocess
import sys
import tempfile
import zipfile

zip_path = sys.argv[1]
package_zip = zipfile.ZipFile(zip_path)
config = json.loads(package_zip.read(".config/sing-box/config.json"))
rule_set_definitions = config.get("route", {}).get("rule_set", [])
rule_set_temp_dir = tempfile.TemporaryDirectory(prefix="magicnet-package-rules-")

canonical_tun_exclusions = [
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
    "fd7a:115c:a1e0::/48",
]
packaged_tuns = [
    inbound
    for inbound in config.get("inbounds", [])
    if inbound.get("type") == "tun" and inbound.get("tag") == "tun-in"
]
if len(packaged_tuns) != 1 or packaged_tuns[0].get("route_exclude_address") != canonical_tun_exclusions:
    raise SystemExit(
        "packaged base TUN exclusions are not canonical or exactly ordered: "
        f"{[inbound.get('route_exclude_address') for inbound in packaged_tuns]}"
    )
packaged_tun = packaged_tuns[0]
if (
    config.get("dns", {}).get("strategy") != "prefer_ipv4"
    or packaged_tun.get("stack") != "mixed"
    or packaged_tun.get("mtu") != 1400
    or packaged_tun.get("udp_timeout") != "5m"
    or 0 not in packaged_tun.get("exclude_uid", [])
    or not any(":" in address for address in packaged_tun.get("address", []))
):
    raise SystemExit("packaged base UDP/IPv6 policy is not canonical dual stack")

dns_rules = config.get("dns", {}).get("rules", [])
dns_servers = config.get("dns", {}).get("servers", [])
route_rules = config.get("route", {}).get("rules", [])
if config.get("dns", {}).get("final") != "bootstrap-local-dns":
    raise SystemExit(
        "packaged unclassified DNS must use local encrypted resolution for destination-based CN routing"
    )
if any("package_name" in rule for rule in dns_rules):
    raise SystemExit("packaged DNS policy must not contain application package selectors")
managed_ipv6_guards = [
    {"ip_version": 6, "outbound": "block"},
    {"ip_version": 6, "action": "reject", "no_drop": True},
    {"ip_version": 6, "action": "reject", "method": "default", "no_drop": True},
]
if any(rule in managed_ipv6_guards for rule in route_rules):
    raise SystemExit("packaged dual-stack config contains a managed IPv6 reject guard")
outbound_tags = {outbound.get("tag") for outbound in config.get("outbounds", [])}
outbounds = {outbound.get("tag"): outbound for outbound in config.get("outbounds", [])}

canonical_cloudflare_dns = {
    "type": "https",
    "tag": "doh-cloudflare",
    "detour": "proxy",
    "server": "1.1.1.1",
    "server_port": 443,
    "path": "/dns-query",
    "tls": {"enabled": True, "server_name": "cloudflare-dns.com"},
}
if any(
    isinstance(server, dict) and server.get("tag") == "default-remote-dns"
    for server in dns_servers
):
    raise SystemExit("legacy default-remote-dns server must be absent")
if [server for server in dns_servers if server == canonical_cloudflare_dns] != [
    canonical_cloudflare_dns
]:
    raise SystemExit("expected exactly one fully canonical doh-cloudflare HTTPS server")
cloudflare_endpoints = [
    server
    for server in dns_servers
    if isinstance(server, dict)
    and server.get("type") == "https"
    and server.get("server") == "1.1.1.1"
    and server.get("server_port") == 443
    and server.get("path") == "/dns-query"
    and server.get("detour") == "proxy"
    and isinstance(server.get("tls"), dict)
    and server["tls"].get("server_name") == "cloudflare-dns.com"
]
if len(cloudflare_endpoints) != 1:
    raise SystemExit(
        f"expected one Cloudflare HTTPS endpoint/transport, found {len(cloudflare_endpoints)}"
    )

required_leak_domains = {
    "dnsleaktest.com",
    "browserleaks.com",
    "ipleak.net",
    "whoer.net",
    "dnscheck.tools",
    "dnschecker.org",
    "dnslytics.com",
}
required_doh_domains = {
    "cloudflare-dns.com",
    "mozilla.cloudflare-dns.com",
    "dns.google",
    "dns.quad9.net",
    "dns.nextdns.io",
    "doh.opendns.com",
    "dns.adguard-dns.com",
}
dedicated_leak_test_suffixes = [
    "bash.ws", "browserscan.net", "browserleaks.com", "browserleaks.org", "dns.sb",
    "dnscheck.tools", "dnschecker.org", "doileak.com", "dns-oarc.net", "dnsleak.com",
    "dnsleaktest.com", "dnsleaktest.org", "dnslytics.com", "ipleak.net", "ipleak.org",
    "ip-api.com", "perfect-privacy.com", "test.nextdns.io", "surfsharkdns.com",
    "whatsmydnsserver.com", "whoer.net",
]
game_domain_suffixes = [
    "steamcommunity.com", "steampowered.com", "steamstatic.com", "epicgames.com",
    "epicgames.dev", "unrealengine.com", "paragon.com", "playstation.com",
    "playstation.net", "playstationnetwork.com", "sonyentertainmentnetwork.com",
    "xboxlive.com", "nintendo.net",
]
domestic_connectivity_rule = {
    "domain_suffix": [
        "connect.rom.miui.com",
        "connectivitycheck.platform.hicloud.com",
    ],
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
foreign_connectivity_rule = {
    "domain_suffix": msft_network_test_suffixes + foreign_network_test_suffixes,
    "server": "doh-google",
}
dedicated_leak_test_dns_rule = {
    "domain_suffix": dedicated_leak_test_suffixes,
    "server": "doh-cloudflare",
}
network_test_leak_overlap = set(dedicated_leak_test_suffixes) & set(
    foreign_connectivity_rule["domain_suffix"]
)
if network_test_leak_overlap != {"browserscan.net"}:
    raise SystemExit(
        "dedicated leak-test and merged network-test DNS suffixes must overlap only at "
        f"browserscan.net: {sorted(network_test_leak_overlap)}"
    )
legacy_early_local_msft_dns_rule = {
    "domain_suffix": msft_network_test_suffixes,
    "server": "bootstrap-local-dns",
}
if legacy_early_local_msft_dns_rule in dns_rules:
    raise SystemExit("legacy early local Microsoft connectivity DNS rule must be absent")
msft_network_test_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == {"domain_suffix": msft_network_test_suffixes, "outbound": "network-test"}
]
foreign_network_test_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == {"domain_suffix": foreign_network_test_suffixes, "outbound": "network-test"}
]
if len(msft_network_test_routes) != 1 or len(foreign_network_test_routes) != 1:
    raise SystemExit("network-test suffix routes must remain unique")
if foreign_connectivity_rule["domain_suffix"] != (
    msft_network_test_routes[0][1]["domain_suffix"] + foreign_network_test_routes[0][1]["domain_suffix"]
):
    raise SystemExit("foreign network-test DNS suffixes must equal the two network-test route blocks")
apple_icloud_rule = {
    "domain_suffix": [
        "apple.com",
        "icloud.com",
        "icloud-content.com",
        "me.com",
    ],
    "server": "bootstrap-local-dns",
}
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
    raise SystemExit("legacy three-domain Microsoft/Bing DNS rule must be absent")
local_direct_service_rule = {
    "domain_suffix": [
        "microsoft.com",
        "windows.com",
        "windowsupdate.com",
        "msftauth.net",
        "msauth.net",
        "office.com",
        "office365.com",
        "live.com",
        "steamserver.net",
        "steamcontent.com",
        "steamusercontent.com",
        "akamaihd.net",
        "hwcdn.net",
    ],
    "server": "bootstrap-local-dns",
}
private_dns_rule = {
    "rule_set": ["lyc-geosite-private", "lyc-geoip-private"],
    "server": "bootstrap-local-dns",
}
mmstat_local_dns_rule = {
    "domain_suffix": ["mmstat.com"],
    "server": "bootstrap-local-dns",
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
game_dns_rule = {
    "domain_suffix": game_domain_suffixes,
    "server": "doh-cloudflare",
}
foreign_priority_domains = [
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
]
legacy_foreign_priority_domains = tuple(foreign_priority_domains)
karing_false_positive_domains = (
    "sony.com",
    "teamviewer.com",
    "abercrombie.com",
    "hollisterco.com",
    "weather.com",
)
foreign_priority_domains += karing_false_positive_domains
foreign_priority_dns_rule = {
    "domain_suffix": foreign_priority_domains,
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
cn_overlap_evidence_rule_sets = canonical_cn_dns_rule["rule_set"] + ["metacubex-geosite-cn"]
generic_foreign_dns_rule = {
    "rule_set": [
        "lyc-geosite-ai", "yuu-geosite-ai", "karing-acl4ssr-ai", "lyc-geosite-gfw",
        "ddch-gfw", "lyc-geosite-proxy", "metacubex-geosite-geolocation-not-cn",
        "ddch-proxy", "karing-acl4ssr-proxy-lite", "karing-acl4ssr-proxy-gfwlist",
    ],
    "server": "doh-google",
}
if (
    len(foreign_priority_domains) != 56
    or len(set(foreign_priority_domains)) != 56
    or tuple(foreign_priority_domains[:len(legacy_foreign_priority_domains)])
    != legacy_foreign_priority_domains
    or tuple(foreign_priority_domains[-len(karing_false_positive_domains):])
    != karing_false_positive_domains
):
    raise SystemExit("packaged foreign-priority sequence must preserve 51 entries and append 5")
foreign_priority_dns_indexes = [
    index for index, rule in enumerate(dns_rules) if rule == foreign_priority_dns_rule
]
if len(foreign_priority_dns_indexes) != 1:
    raise SystemExit(
        "packaged exact 56-domain foreign-priority DNS rule must remain unique: "
        f"indexes={foreign_priority_dns_indexes}"
    )
foreign_priority_dns_index = foreign_priority_dns_indexes[0]
supported_dns_safety_keys = {
    "clash_mode",
    "domain",
    "domain_keyword",
    "domain_suffix",
    "invert",
    "package_name",
    "rule_set",
    "server",
    "type",
}
dns_string_matcher_keys = {
    "clash_mode",
    "domain",
    "domain_keyword",
    "domain_suffix",
    "package_name",
    "rule_set",
}

def suffixes(rule):
    value = rule.get("domain_suffix", [])
    if isinstance(value, str):
        return {value}
    return set(value)

def keywords(rule):
    value = rule.get("domain_keyword", [])
    if isinstance(value, str):
        return {value}
    return set(value)

def explicit_domain_matches(rule, domain):
    exact = rule.get("domain", [])
    if isinstance(exact, str):
        exact = [exact]
    keywords = rule.get("domain_keyword", [])
    if isinstance(keywords, str):
        keywords = [keywords]
    return (
        domain in exact
        or any(domain == suffix or domain.endswith("." + suffix) for suffix in suffixes(rule))
        or any(keyword in domain for keyword in keywords)
    )

def find_rule(rules, required, **expected):
    for index, rule in enumerate(rules):
        if required <= suffixes(rule) and all(rule.get(key) == value for key, value in expected.items()):
            return index
    return -1

def first_route_index(predicate):
    for index, rule in enumerate(route_rules):
        if predicate(rule):
            return index
    return -1

def dns_string_values(rule, index, key):
    value = rule[key]
    if isinstance(value, str) and value:
        return [value]
    if (
        isinstance(value, list)
        and value
        and all(isinstance(item, str) and item for item in value)
    ):
        return value
    raise SystemExit(
        f"connectivity DNS safety: rule index {index} field {key} must be a non-empty "
        "string or non-empty list of non-empty strings"
    )

def extract_binary_rule_set_member(tag, member):
    try:
        payload = package_zip.read(member)
    except KeyError as error:
        raise SystemExit(f"packaged rule-set {tag} is missing archive member {member}") from error
    target = os.path.join(rule_set_temp_dir.name, f"{len(os.listdir(rule_set_temp_dir.name))}.srs")
    with open(target, "wb") as handle:
        handle.write(payload)
    return target

@functools.lru_cache(maxsize=None)
def packaged_binary_rule_set_path(tag):
    definitions = [definition for definition in rule_set_definitions if definition.get("tag") == tag]
    if len(definitions) != 1:
        raise SystemExit(f"packaged rule-set {tag} has {len(definitions)} definitions")
    definition = definitions[0]
    if definition.get("type") != "local" or definition.get("format") != "binary":
        raise SystemExit(f"packaged rule-set {tag} is not local binary")
    rule_set_path = definition.get("path")
    if not isinstance(rule_set_path, str) or not rule_set_path or rule_set_path.startswith("/"):
        raise SystemExit(f"packaged rule-set {tag} has an invalid archive-relative path")
    member = posixpath.normpath(posixpath.join(".config/sing-box", rule_set_path))
    if not member.startswith(".config/sing-box/rules/"):
        raise SystemExit(f"packaged rule-set {tag} escapes the packaged rules directory")
    return extract_binary_rule_set_member(tag, member)

def match_binary_rule_set_file(rule_file, domain, label):
    result = subprocess.run(
        ["sing-box", "rule-set", "match", "-f", "binary", rule_file, domain],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise SystemExit(f"packaged rule-set {label} could not be matched: {detail}")
    return bool(result.stdout.strip() or result.stderr.strip())

@functools.lru_cache(maxsize=None)
def binary_rule_set_matches(tag, domain):
    return match_binary_rule_set_file(packaged_binary_rule_set_path(tag), domain, tag)

try:
    extract_binary_rule_set_member(
        "missing-fixture", ".config/sing-box/rules/__missing-package-smoke__.srs"
    )
except SystemExit as error:
    if "missing archive member" not in str(error):
        raise SystemExit(f"missing packaged SRS fixture failed for the wrong reason: {error}")
else:
    raise SystemExit("missing packaged SRS fixture was silently accepted")

with tempfile.NamedTemporaryFile(dir=rule_set_temp_dir.name, suffix=".srs", delete=False) as handle:
    handle.write(b"not-a-valid-sing-box-rule-set")
    corrupt_rule_set_path = handle.name
try:
    match_binary_rule_set_file(corrupt_rule_set_path, "example.com", "corrupt-fixture")
except SystemExit as error:
    if "could not be matched" not in str(error):
        raise SystemExit(f"corrupt packaged SRS fixture failed for the wrong reason: {error}")
else:
    raise SystemExit("corrupt packaged SRS fixture was silently accepted")

def validate_dns_safety_rule(rule, index):
    if not isinstance(rule, dict):
        raise SystemExit(f"connectivity DNS safety: rule index {index} must be an object")
    rule_type = rule.get("type", "default")
    if rule_type != "default":
        raise SystemExit(
            f"connectivity DNS safety: rule index {index} uses unsupported logical/non-default "
            f"type {rule_type!r}"
        )
    unknown_keys = sorted(set(rule) - supported_dns_safety_keys)
    if unknown_keys:
        raise SystemExit(
            f"connectivity DNS safety: rule index {index} has unknown/unmodeled matcher keys: "
            f"{unknown_keys}"
        )
    if "invert" in rule and not isinstance(rule["invert"], bool):
        raise SystemExit(f"connectivity DNS safety: rule index {index} field invert must be boolean")
    for key in dns_string_matcher_keys & set(rule):
        dns_string_values(rule, index, key)
    if not isinstance(rule.get("server"), str) or not rule["server"]:
        raise SystemExit(
            f"connectivity DNS safety: rule index {index} must have a non-empty server"
        )

def dns_rule_can_match(rule, index, domain, clash_mode):
    validate_dns_safety_rule(rule, index)
    known_condition_mismatch = False
    domain_keys = {"domain", "domain_suffix", "domain_keyword"} & set(rule)
    if domain_keys:
        exact_domains = dns_string_values(rule, index, "domain") if "domain" in rule else []
        domain_suffixes = (
            dns_string_values(rule, index, "domain_suffix") if "domain_suffix" in rule else []
        )
        domain_keywords = (
            dns_string_values(rule, index, "domain_keyword") if "domain_keyword" in rule else []
        )
        domain_matches = (
            domain in exact_domains
            or any(domain == suffix or domain.endswith("." + suffix) for suffix in domain_suffixes)
            or any(keyword in domain for keyword in domain_keywords)
        )
        known_condition_mismatch = not domain_matches
    if "clash_mode" in rule:
        clash_modes = dns_string_values(rule, index, "clash_mode")
        known_condition_mismatch = known_condition_mismatch or clash_mode not in clash_modes

    # Domain-only safety probes do not carry an Android package context.
    if "package_name" in rule:
        dns_string_values(rule, index, "package_name")
        known_condition_mismatch = True

    if "rule_set" in rule:
        rule_set_matches = any(
            binary_rule_set_matches(tag, domain)
            for tag in dns_string_values(rule, index, "rule_set")
        )
        known_condition_mismatch = known_condition_mismatch or not rule_set_matches
    if rule.get("invert", False):
        return known_condition_mismatch
    return not known_condition_mismatch

def assert_packaged_connectivity_dns_safety(domestic_index, foreign_index, leak_index):
    default_mode = config.get("experimental", {}).get("clash_api", {}).get("default_mode", "Rule")
    if not isinstance(default_mode, str) or not default_mode:
        raise SystemExit("connectivity DNS safety: invalid Clash API default mode")
    if default_mode != "Rule":
        raise SystemExit(
            f"connectivity DNS safety: packaged default Clash mode must remain Rule, got {default_mode!r}"
        )
    policies = [
        *((domain, "bootstrap-local-dns", domestic_index)
          for domain in domestic_connectivity_rule["domain_suffix"]),
        *((
            domain,
            "doh-cloudflare" if domain in network_test_leak_overlap else "doh-google",
            leak_index if domain in network_test_leak_overlap else foreign_index,
        ) for domain in foreign_connectivity_rule["domain_suffix"]),
    ]
    for domain, expected_server, canonical_index in policies:
        for index, rule in enumerate(dns_rules[:canonical_index + 1]):
            if not dns_rule_can_match(rule, index, domain, default_mode):
                continue
            server = rule["server"]
            if server != expected_server:
                raise SystemExit(
                    f"connectivity DNS safety: {domain} can first-match wrong DNS rule "
                    f"index {index} expected={expected_server} actual={server}"
                )
            break
        else:
            raise SystemExit(
                f"connectivity DNS safety: no safe DNS rule can match {domain} through canonical "
                f"rule index {canonical_index}"
            )

proxy_node_types = {"shadowsocks", "vmess", "vless", "trojan", "hysteria2", "anytls", "tuic", "socks"}
base_proxy_nodes = [
    outbound for outbound in config.get("outbounds", []) if outbound.get("type") in proxy_node_types
]
if base_proxy_nodes:
    raise SystemExit("packaged base config must represent the zero-node state")
expected_zero_node_proxy = {
    "type": "selector",
    "tag": "proxy",
    "outbounds": ["block"],
    "default": "block",
}
proxy_selectors = [
    outbound for outbound in config.get("outbounds", []) if outbound.get("tag") == "proxy"
]
if proxy_selectors != [expected_zero_node_proxy]:
    raise SystemExit(f"packaged zero-node proxy selector is not canonical fail-closed: {proxy_selectors}")

def recursively_effective_outbound(tag, outbound_list=None):
    if outbound_list is None:
        outbound_list = config.get("outbounds", [])
    visited = []
    current = tag
    while True:
        if current in visited:
            raise SystemExit(f"selector cycle while resolving {tag}: {visited + [current]}")
        visited.append(current)
        matches = [
            outbound for outbound in outbound_list if outbound.get("tag") == current
        ]
        if len(matches) != 1:
            raise SystemExit(
                f"expected exactly one outbound {current} while resolving {tag}, found {len(matches)}"
            )
        outbound = matches[0]
        if outbound.get("type") != "selector":
            return current
        default = outbound.get("default")
        if not isinstance(default, str) or default not in outbound.get("outbounds", []):
            raise SystemExit(f"selector {current} has an invalid default while resolving {tag}")
        current = default

resolution_fixture = [
    {"type": "selector", "tag": "bing", "outbounds": ["proxy"], "default": "proxy"},
    {"type": "selector", "tag": "proxy", "outbounds": ["block"], "default": "block"},
    {"type": "block", "tag": "block"},
]
if recursively_effective_outbound("bing", resolution_fixture) != "block":
    raise SystemExit("recursive selector resolver did not follow the two-level bing fixture")

resolver_mutants = [
    (
        "cycle",
        [
            {"type": "selector", "tag": "a", "outbounds": ["b"], "default": "b"},
            {"type": "selector", "tag": "b", "outbounds": ["a"], "default": "a"},
        ],
        "selector cycle",
    ),
    (
        "missing",
        [{"type": "selector", "tag": "a", "outbounds": ["missing"], "default": "missing"}],
        "expected exactly one outbound missing",
    ),
    (
        "invalid-default",
        [{"type": "selector", "tag": "a", "outbounds": ["block"], "default": "missing"}],
        "invalid default",
    ),
]
for label, mutant, expected_message in resolver_mutants:
    try:
        recursively_effective_outbound("a", mutant)
    except SystemExit as error:
        if expected_message not in str(error):
            raise SystemExit(f"recursive selector {label} mutant failed for the wrong reason: {error}")
    else:
        raise SystemExit(f"recursive selector resolver accepted the {label} mutant")

for tag in (
    "proxy", "select", "final", "proxy-rule", "dev-proxy", "media-proxy", "game-proxy",
    "social-proxy", "telegram-proxy", "network-test", "dns-guard",
):
    effective = recursively_effective_outbound(tag)
    if effective != "block":
        raise SystemExit(f"packaged zero-node selector {tag} resolves to {effective}, expected block")
for tag in ("lan", "hotspot", "cn-direct", "apple-cn", "microsoft-cn", "icloud", "download-direct"):
    effective = recursively_effective_outbound(tag)
    if effective != "direct":
        raise SystemExit(f"packaged domestic selector {tag} resolves to {effective}, expected direct")
for tag in ("ai-proxy", "ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude"):
    effective = recursively_effective_outbound(tag)
    if effective != "block":
        raise SystemExit(f"packaged AI selector {tag} resolves to {effective}, expected block")

if "dns-guard" not in outbound_tags:
    raise SystemExit("missing dns-guard outbound selector")

hotspot_selectors = [
    outbound for outbound in config.get("outbounds", []) if outbound.get("tag") == "hotspot"
]
expected_hotspot_selector = {
    "type": "selector",
    "tag": "hotspot",
    "outbounds": ["direct", "proxy"],
    "default": "direct",
}
if hotspot_selectors != [expected_hotspot_selector]:
    raise SystemExit(f"hotspot selector is not canonical direct/proxy: {hotspot_selectors}")

google_cn_outbounds = [
    outbound for outbound in config.get("outbounds", []) if outbound.get("tag") == "google-cn"
]
if google_cn_outbounds:
    raise SystemExit(f"google-cn outbound selector must be absent: {google_cn_outbounds}")

google_cn_direct_rule = {
    "domain_suffix": ["google.cn", "g.cn", "googleapis.cn"],
    "outbound": "cn-direct",
}
legacy_mixed_google_rule = {
    "domain_suffix": ["google.cn", "g.cn", "googleapis.cn", "google-analytics.com"],
    "outbound": "google-cn",
}
google_cn_direct_rules = [
    index for index, rule in enumerate(route_rules) if rule == google_cn_direct_rule
]
if len(google_cn_direct_rules) != 1:
    raise SystemExit(f"expected one exact domestic Google route, found {google_cn_direct_rules}")
if legacy_mixed_google_rule in route_rules:
    raise SystemExit("legacy mixed Google route rule must be absent")
google_cn_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule.get("outbound") == "google-cn"
]
if google_cn_routes:
    raise SystemExit(f"google-cn route outbound must be absent: {google_cn_routes}")

bing_cn_direct_rule = {
    "domain_suffix": ["cn.bing.com"],
    "outbound": "cn-direct",
}
bing_cn_direct_rules = [
    index for index, rule in enumerate(route_rules) if rule == bing_cn_direct_rule
]
if len(bing_cn_direct_rules) != 1:
    raise SystemExit(f"expected one exact cn.bing.com direct route, found {bing_cn_direct_rules}")
if any(
    rule.get("outbound") == "bing" and "cn.bing.com" in suffixes(rule)
    for rule in route_rules
):
    raise SystemExit("bing routes must not explicitly contain cn.bing.com")
global_bing_route_rule = {
    "domain_suffix": [
        "bing.com", "bingapis.com", "bing.net", "msn.com", "login.live.com",
        "account.live.com", "edgeservices.bing.com", "assets.msn.com",
        "c.bing.com", "r.bing.com", "www.bing.com",
    ],
    "outbound": "bing",
}
global_bing_route_rules = [
    index for index, rule in enumerate(route_rules) if rule == global_bing_route_rule
]
if len(global_bing_route_rules) != 1:
    raise SystemExit(f"expected one exact global Bing route, found {global_bing_route_rules}")
global_bing_route_index = global_bing_route_rules[0]

direct_mode_rules = [
    index for index, rule in enumerate(dns_rules)
    if rule == {"clash_mode": "Direct", "server": "bootstrap-local-dns"}
]
global_mode_rules = [
    index for index, rule in enumerate(dns_rules)
    if rule == {"clash_mode": "Global", "server": "doh-cloudflare"}
]
domestic_connectivity_rules = [
    index for index, rule in enumerate(dns_rules) if rule == domestic_connectivity_rule
]
foreign_connectivity_rules = [
    index for index, rule in enumerate(dns_rules) if rule == foreign_connectivity_rule
]
apple_icloud_rules = [
    index for index, rule in enumerate(dns_rules) if rule == apple_icloud_rule
]
cn_bing_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == cn_bing_dns_rule
]
global_bing_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == global_bing_dns_rule
]
local_direct_service_rules = [
    index for index, rule in enumerate(dns_rules) if rule == local_direct_service_rule
]
private_dns_rules = [index for index, rule in enumerate(dns_rules) if rule == private_dns_rule]
mmstat_local_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == mmstat_local_dns_rule
]
dedicated_leak_test_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == dedicated_leak_test_dns_rule
]
ad_suffix_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == ad_suffix_dns_rule
]
ad_keyword_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == ad_keyword_dns_rule
]
ad_rule_set_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == ad_rule_set_dns_rule
]
game_dns_rules = [index for index, rule in enumerate(dns_rules) if rule == game_dns_rule]
foreign_priority_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == foreign_priority_dns_rule
]
canonical_cn_dns_rules = [
    index for index, rule in enumerate(dns_rules) if rule == canonical_cn_dns_rule
]
if len(direct_mode_rules) != 1 or len(global_mode_rules) != 1:
    raise SystemExit(
        f"expected unique unchanged Direct/Global DNS overrides: "
        f"Direct={direct_mode_rules} Global={global_mode_rules}"
    )
if (
    len(domestic_connectivity_rules) != 1
    or len(foreign_connectivity_rules) != 1
    or len(apple_icloud_rules) != 1
    or len(cn_bing_dns_rules) != 1
    or len(global_bing_dns_rules) != 1
    or len(local_direct_service_rules) != 1
    or len(dedicated_leak_test_dns_rules) != 1
    or len(private_dns_rules) != 1
    or len(mmstat_local_dns_rules) != 1
    or len(ad_suffix_dns_rules) != 1
    or len(ad_keyword_dns_rules) != 1
    or len(ad_rule_set_dns_rules) != 1
    or len(game_dns_rules) != 1
    or len(foreign_priority_dns_rules) != 1
    or len(canonical_cn_dns_rules) != 1
):
    raise SystemExit(
        "expected unique exact explicit DNS policy rules, "
        f"domestic={domestic_connectivity_rules} "
        f"foreign={foreign_connectivity_rules} "
        f"apple={apple_icloud_rules} cn_bing={cn_bing_dns_rules} "
        f"global_bing={global_bing_dns_rules} "
        f"local={local_direct_service_rules} leak={dedicated_leak_test_dns_rules} "
        f"private={private_dns_rules} mmstat={mmstat_local_dns_rules} "
        f"ad_suffix={ad_suffix_dns_rules} ad_keyword={ad_keyword_dns_rules} "
        f"ad_rule_set={ad_rule_set_dns_rules} "
        f"game={game_dns_rules} foreign_priority={foreign_priority_dns_rules} "
        f"cn={canonical_cn_dns_rules}"
    )
direct_mode_index = direct_mode_rules[0]
global_mode_index = global_mode_rules[0]
domestic_connectivity_index = domestic_connectivity_rules[0]
foreign_connectivity_index = foreign_connectivity_rules[0]
apple_icloud_index = apple_icloud_rules[0]
cn_bing_dns_index = cn_bing_dns_rules[0]
global_bing_dns_index = global_bing_dns_rules[0]
local_direct_service_index = local_direct_service_rules[0]
private_dns_index = private_dns_rules[0]
mmstat_local_dns_index = mmstat_local_dns_rules[0]
dedicated_leak_test_dns_index = dedicated_leak_test_dns_rules[0]
ad_suffix_dns_index = ad_suffix_dns_rules[0]
ad_keyword_dns_index = ad_keyword_dns_rules[0]
ad_rule_set_dns_index = ad_rule_set_dns_rules[0]
game_dns_index = game_dns_rules[0]
foreign_priority_dns_index = foreign_priority_dns_rules[0]
canonical_cn_dns_index = canonical_cn_dns_rules[0]
if global_mode_index != direct_mode_index + 1:
    raise SystemExit("Global DNS override must remain immediately after the Direct override")
if domestic_connectivity_index != global_mode_index + 1:
    raise SystemExit(
        f"domestic connectivity DNS rule index {domestic_connectivity_index} must immediately "
        f"follow Direct/Global overrides ending at {global_mode_index}"
    )
if foreign_connectivity_index != domestic_connectivity_index + 1:
    raise SystemExit(
        f"foreign connectivity DNS rule index {foreign_connectivity_index} must immediately "
        f"follow domestic connectivity rule index {domestic_connectivity_index}"
    )
if apple_icloud_index != foreign_connectivity_index + 1:
    raise SystemExit(
        f"Apple/iCloud DNS rule index {apple_icloud_index} must immediately follow foreign "
        f"connectivity rule index {foreign_connectivity_index}"
    )
if cn_bing_dns_index != apple_icloud_index + 1:
    raise SystemExit(
        f"cn.bing.com local DNS rule index {cn_bing_dns_index} must "
        f"immediately follow Apple/iCloud rule index {apple_icloud_index}"
    )
if global_bing_dns_index != cn_bing_dns_index + 1:
    raise SystemExit(
        f"global Bing DNS rule index {global_bing_dns_index} must immediately follow "
        f"cn.bing.com local DNS rule index {cn_bing_dns_index}"
    )
if local_direct_service_index != global_bing_dns_index + 1:
    raise SystemExit(
        f"local direct-service DNS rule index {local_direct_service_index} must immediately "
        f"follow global Bing rule index {global_bing_dns_index}"
    )
if private_dns_index != local_direct_service_index + 1:
    raise SystemExit("private DNS rule must immediately follow explicit local service policy")
if not (
    private_dns_index + 1 == mmstat_local_dns_index
    and mmstat_local_dns_index + 1 == ad_suffix_dns_index
    and ad_suffix_dns_index + 1 == ad_keyword_dns_index
    and ad_keyword_dns_index + 1 == ad_rule_set_dns_index
    and ad_rule_set_dns_index + 1 == game_dns_index
    and game_dns_index + 1 == foreign_priority_dns_index
    and foreign_priority_dns_index + 1 == canonical_cn_dns_index
):
    raise SystemExit(
        "required DNS order is private < mmstat local < ad suffix < ad keyword < ad rule-set < game < "
        "foreign priority < canonical CN: "
        f"private={private_dns_index} mmstat={mmstat_local_dns_index} "
        f"ad_suffix={ad_suffix_dns_index} "
        f"ad_keyword={ad_keyword_dns_index} ad_rule_set={ad_rule_set_dns_index} "
        f"game={game_dns_index} foreign_priority={foreign_priority_dns_index} "
        f"cn={canonical_cn_dns_index}"
    )
if not dedicated_leak_test_dns_index < foreign_connectivity_index:
    raise SystemExit("dedicated leak-test DNS rule must precede merged network-test DNS")
assert_packaged_connectivity_dns_safety(
    domestic_connectivity_index,
    foreign_connectivity_index,
    dedicated_leak_test_dns_index,
)

def first_packaged_dns_match(domain, clash_mode):
    for index, rule in enumerate(dns_rules):
        if dns_rule_can_match(rule, index, domain, clash_mode):
            return index, rule["server"]
    return None

# Actual mmstat first-match is verified below by the extracted package default policy test with packaged config and SRS.
if any(binary_rule_set_matches(tag, "mmstat.com") for tag in private_dns_rule["rule_set"]):
    raise SystemExit("packaged mmstat.com unexpectedly matches a private rule-set")
if not binary_rule_set_matches("lyc-geosite-ads", "mmstat.com"):
    raise SystemExit("packaged mmstat.com must match lyc-geosite-ads")
if not any(
    binary_rule_set_matches(tag, "mmstat.com") for tag in canonical_cn_dns_rule["rule_set"]
):
    raise SystemExit("packaged mmstat.com must match a canonical CN rule-set")
if first_packaged_dns_match("outbrain.com", "Rule") != (
    ad_rule_set_dns_index,
    "doh-cloudflare",
):
    raise SystemExit("packaged outbrain.com must first-match the ad rule-set DNS rule")
for domain in legacy_foreign_priority_domains:
    cn_rule_sets = [
        tag
        for tag in cn_overlap_evidence_rule_sets
        if binary_rule_set_matches(tag, domain)
    ]
    foreign_rule_sets = [
        tag
        for tag in generic_foreign_dns_rule["rule_set"]
        if binary_rule_set_matches(tag, domain)
    ]
    if not cn_rule_sets or not foreign_rule_sets:
        raise SystemExit(
            f"packaged foreign-priority overlap evidence missing for {domain}: "
            f"cn={cn_rule_sets} foreign={foreign_rule_sets}"
        )
    if first_packaged_dns_match(domain, "Rule") != (
        foreign_priority_dns_index,
        "doh-google",
    ):
        raise SystemExit(
            f"packaged foreign-priority {domain} must first-match proxy-detoured doh-google DNS"
        )
karing_false_positive_foreign_rule_sets = set(generic_foreign_dns_rule["rule_set"]) | {
    "lyc-geosite-dev",
    "lyc-geosite-media",
    "yuu-geosite-stream-global",
    "karing-acl4ssr-proxy-media",
    "lyc-geosite-games",
    "lyc-geosite-social",
    "lyc-geosite-telegram",
    "lyc-geoip-telegram",
}
for domain in karing_false_positive_domains:
    if not binary_rule_set_matches("karing-acl4ssr-china-domain", domain):
        raise SystemExit(f"packaged {domain} must retain Karing China-domain overlap evidence")
    foreign_rule_sets = {
        tag
        for tag in karing_false_positive_foreign_rule_sets
        if binary_rule_set_matches(tag, domain)
    }
    if domain in {"sony.com", "teamviewer.com"} and not foreign_rule_sets:
        raise SystemExit(f"packaged {domain} must retain foreign rule-set overlap evidence")
    if first_packaged_dns_match(domain, "Rule") != (
        foreign_priority_dns_index,
        "doh-google",
    ):
        raise SystemExit(f"packaged {domain} must first-match foreign-priority doh-google DNS")
for domain in ("sony.com.cn", "teamviewer.cn"):
    dns_match = first_packaged_dns_match(domain, "Rule")
    if dns_match is None or dns_match[1] != "bootstrap-local-dns":
        raise SystemExit(
            f"packaged domestic control {domain} must remain on local DNS: actual={dns_match}"
        )
metacubex_false_positive_foreign_rule_sets = set(generic_foreign_dns_rule["rule_set"]) | {
    "lyc-geosite-dev",
    "lyc-geosite-games",
}
metacubex_false_positive_required_rule_sets = {
    "gandi.net": {"lyc-geosite-proxy", "ddch-proxy", "metacubex-geosite-geolocation-not-cn"},
    "java.com": {"lyc-geosite-dev"},
    "kaspersky-labs.com": {
        "lyc-geosite-proxy",
        "ddch-proxy",
        "metacubex-geosite-geolocation-not-cn",
    },
    "supercell.com": {"lyc-geosite-games"},
}
for domain, required_foreign_rule_sets in metacubex_false_positive_required_rule_sets.items():
    if not binary_rule_set_matches("metacubex-geosite-cn", domain):
        raise SystemExit(f"packaged {domain} must retain metacubex-geosite-cn overlap evidence")
    retained_cn_rule_sets = [
        tag
        for tag in canonical_cn_dns_rule["rule_set"]
        if binary_rule_set_matches(tag, domain)
    ]
    foreign_rule_sets = {
        tag
        for tag in metacubex_false_positive_foreign_rule_sets
        if binary_rule_set_matches(tag, domain)
    }
    generic_foreign_rule_sets = set(generic_foreign_dns_rule["rule_set"]) & foreign_rule_sets
    if (
        retained_cn_rule_sets
        or not generic_foreign_rule_sets
        or not required_foreign_rule_sets <= foreign_rule_sets
    ):
        raise SystemExit(
            f"packaged metacubex correction evidence changed for {domain}: "
            f"retained_cn={retained_cn_rule_sets} foreign={sorted(foreign_rule_sets)}"
        )
    dns_match = first_packaged_dns_match(domain, "Rule")
    if dns_match is None or dns_match[1] != "doh-google":
        raise SystemExit(
            f"packaged {domain} must first-match proxy-detoured doh-google DNS: {dns_match}"
        )
r_bing_cn_rule_sets = [
    tag
    for tag in canonical_cn_dns_rule["rule_set"]
    if binary_rule_set_matches(tag, "r.bing.com")
]
if not r_bing_cn_rule_sets:
    raise SystemExit(
        "packaged r.bing.com must overlap at least one canonical China SRS: "
        f"matching_tags={r_bing_cn_rule_sets}"
    )

for clash_mode, expected_index, expected_server in (
    ("Rule", foreign_connectivity_index, "doh-google"),
    ("Direct", direct_mode_index, "bootstrap-local-dns"),
    ("Global", global_mode_index, "doh-cloudflare"),
):
    for domain in (
        "msftconnecttest.com",
        "msftncsi.com",
        "captive.apple.com",
        "connectivitycheck.android.com",
    ):
        result = first_packaged_dns_match(domain, clash_mode)
        if result != (expected_index, expected_server):
            raise SystemExit(
                f"{clash_mode}-mode {domain} packaged DNS first-match changed: "
                f"actual={result} expected={(expected_index, expected_server)}"
            )

dns_rule_set_indexes = [index for index, rule in enumerate(dns_rules) if "rule_set" in rule]
if not dns_rule_set_indexes or not all(
    local_direct_service_index < index for index in dns_rule_set_indexes
):
    raise SystemExit("local direct-service DNS rule must precede all rule-set DNS classifiers")

if find_rule(dns_rules, required_leak_domains, server="doh-cloudflare") < 0:
    raise SystemExit("DNS leak-test suffixes are not forced to proxy-detoured DoH")
if find_rule(dns_rules, required_doh_domains, server="doh-cloudflare") < 0:
    raise SystemExit("DoH endpoint suffixes are not forced to proxy-detoured DoH")

leak_route = find_rule(route_rules, required_leak_domains, outbound="dns-guard")
doh_route = find_rule(route_rules, required_doh_domains, outbound="dns-guard")
if leak_route < 0:
    raise SystemExit("missing dns-guard route for DNS leak-test domains")
if doh_route < 0:
    raise SystemExit("missing dns-guard route for DoH endpoints")

network_test_route = first_route_index(
    lambda rule: rule.get("outbound") == "network-test"
    and bool({"browserscan.net", "speedtest.net"} & suffixes(rule))
)
if network_test_route >= 0 and not (leak_route < network_test_route and doh_route < network_test_route):
    raise SystemExit("dns-guard routes must precede broad network-test routes")
browserscan_leak_route = first_route_index(
    lambda rule: rule.get("outbound") == "dns-guard"
    and "browserscan.net" in suffixes(rule)
)
browserscan_network_route = first_route_index(
    lambda rule: rule.get("outbound") == "network-test"
    and "browserscan.net" in suffixes(rule)
)
if not (
    browserscan_leak_route >= 0
    and browserscan_network_route >= 0
    and browserscan_leak_route < browserscan_network_route
):
    raise SystemExit(
        "browserscan.net dns-guard route must precede its network-test route: "
        f"leak={browserscan_leak_route} network={browserscan_network_route}"
    )

dot_route = first_route_index(lambda rule: rule.get("port") == 853 and rule.get("outbound") == "dns-guard")
if dot_route < 0:
    raise SystemExit("missing dns-guard route for DoT port 853")

broad_udp443_routes = [
    rule for rule in route_rules
    if rule.get("network") == "udp"
    and rule.get("port") == 443
    and rule.get("outbound") == "proxy-rule"
]
if broad_udp443_routes:
    raise SystemExit("broad UDP/443 proxy rule must not exist")

def rule_sets(rule):
    value = rule.get("rule_set", [])
    return set(value if isinstance(value, list) else [value])

ai_domain_routes = {
    "ai-chatgpt": {"openai.com", "chatgpt.com", "chat.openai.com", "auth.openai.com", "oaistatic.com", "oaiusercontent.com", "oaistatsig.com", "openaiapi-site.azureedge.net"},
    "ai-gemini": {"gemini.google.com", "bard.google.com", "generativelanguage.googleapis.com", "ai.google.dev"},
    "ai-grok": {"grok.com", "x.ai", "api.x.ai"},
    "ai-claude": {"anthropic.com", "claude.ai"},
}
for outbound, required_domains in ai_domain_routes.items():
    if find_rule(route_rules, required_domains, outbound=outbound) < 0:
        raise SystemExit(f"missing dedicated domain route for {outbound}")

if config.get("dns", {}).get("reverse_mapping") is not True:
    raise SystemExit("packaged DNS must preserve reverse mappings for IP-only app flows")

chatgpt_voice_routes = [
    (index, rule)
    for index, rule in enumerate(route_rules)
    if rule.get("network") == "udp"
    and rule.get("port") == 3478
    and rule.get("outbound") == "ai-chatgpt"
    and set(rule) == {"network", "port", "ip_cidr", "outbound"}
]
if len(chatgpt_voice_routes) != 1:
    raise SystemExit(f"packaged ChatGPT Voice route is non-canonical: {chatgpt_voice_routes}")
voice_index, voice_rule = chatgpt_voice_routes[0]
if not voice_rule["ip_cidr"]:
    raise SystemExit("packaged ChatGPT Voice route has no official IP prefixes")
for prefix in voice_rule["ip_cidr"]:
    ipaddress.ip_network(prefix)
cn_ip_indexes = [
    index
    for index, rule in enumerate(route_rules)
    if rule.get("outbound") == "cn-direct" and (rule.get("ip_cidr") or rule.get("rule_set"))
]
if not cn_ip_indexes or voice_index >= min(cn_ip_indexes):
    raise SystemExit(
        f"packaged ChatGPT Voice route must precede CN IP ownership: "
        f"voice={voice_index} cn={cn_ip_indexes}"
    )

x_package_routes = [
    index
    for index, rule in enumerate(route_rules)
    if rule == {"package_name": ["com.twitter.android"], "outbound": "social-proxy"}
]
if len(x_package_routes) != 1:
    raise SystemExit(f"packaged X action route is non-canonical: x={x_package_routes}")
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
x_domain_routes = [index for index, rule in enumerate(route_rules) if rule == x_domain_rule]
cn_ip_routes = [index for index, rule in enumerate(route_rules) if rule == cn_ip_rule]
invalid_destination_routes = [
    index for index, rule in enumerate(route_rules) if rule == invalid_destination_rule
]
if len(x_domain_routes) != 1 or len(cn_ip_routes) != 1 or len(invalid_destination_routes) != 1:
    raise SystemExit(
        "packaged invalid-destination/X/CN routing owners are non-canonical: "
        f"invalid={invalid_destination_routes} x={x_domain_routes} cn={cn_ip_routes}"
    )
if x_domain_routes[0] >= cn_ip_routes[0]:
    raise SystemExit(
        "packaged X domains must precede the canonical CN IP route so API/CDN IPs stay proxied"
    )

chatgpt_voice_routes = [
    (index, rule)
    for index, rule in enumerate(route_rules)
    if rule.get("network") == "udp"
    and rule.get("port") == 3478
    and rule.get("outbound") == "ai-chatgpt"
    and set(rule) == {"network", "port", "ip_cidr", "outbound"}
]
if len(chatgpt_voice_routes) != 1:
    raise SystemExit(f"packaged ChatGPT Voice route is non-canonical: {chatgpt_voice_routes}")
voice_index, voice_rule = chatgpt_voice_routes[0]
voice_prefixes = voice_rule.get("ip_cidr", [])
if not voice_prefixes:
    raise SystemExit("packaged ChatGPT Voice route has no official IP prefixes")
for prefix in voice_prefixes:
    ipaddress.ip_network(prefix, strict=True)
if voice_index >= cn_ip_routes[0]:
    raise SystemExit(
        f"packaged ChatGPT Voice route must precede CN IP ownership: "
        f"voice={voice_index} cn={cn_ip_routes}"
    )

if invalid_destination_routes[0] > cn_ip_routes[0]:
    raise SystemExit("packaged reserved 0.0.0.0/8 destinations must fail closed before CN routing")
if any(server.get("type") == "fakeip" or server.get("tag") == "fakeip" for server in config["dns"]["servers"]):
    raise SystemExit("packaged default DNS must not enable FakeIP")
if config.get("experimental", {}).get("cache_file", {}).get("store_fakeip") is True:
    raise SystemExit("packaged default DNS must not persist FakeIP mappings")
if any(
    rule.get("outbound") == "block"
    and ({"198.18.0.0/16", "28.0.0.0/8"} & set(rule.get("ip_cidr", [])))
    for rule in route_rules
):
    raise SystemExit("packaged routing must not blackhole benchmark or public address space")

for tag in ("ai-chatgpt", "ai-gemini", "ai-grok", "ai-claude", "ai-proxy"):
    expected_selector = {"type": "selector", "tag": tag, "outbounds": ["block"], "default": "block"}
    selectors = [outbound for outbound in config.get("outbounds", []) if outbound.get("tag") == tag]
    if selectors != [expected_selector]:
        raise SystemExit(f"{tag} selector is not canonical fail-closed: {selectors}")

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
telegram_ip_cidrs = [
    "91.108.0.0/16", "91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22",
    "91.108.16.0/22", "91.108.56.0/22", "149.154.160.0/20", "2001:67c:4e8::/48",
    "2001:b28:f23c::/47", "2001:b28:f23f::/48",
]
final_foreign_keywords = [
    "google", "youtube", "facebook", "instagram", "twitter", "x.com", "github",
    "telegram", "wikipedia", "reddit", "discord",
]
if not dns_rule_set_indexes:
    raise SystemExit("rule-set DNS policies must remain present")

expected_rule_set_outbounds = {
    "lyc-geosite-ai": "ai-proxy",
    "yuu-geosite-ai": "ai-proxy",
    "karing-acl4ssr-ai": "ai-proxy",
    "lyc-geosite-gfw": "proxy-rule",
    "ddch-gfw": "proxy-rule",
    "lyc-geosite-proxy": "proxy-rule",
    "metacubex-geosite-geolocation-not-cn": "proxy-rule",
    "ddch-proxy": "proxy-rule",
    "karing-acl4ssr-proxy-lite": "proxy-rule",
    "karing-acl4ssr-proxy-gfwlist": "proxy-rule",
    "lyc-geosite-dev": "dev-proxy",
    "lyc-geosite-media": "media-proxy",
    "yuu-geosite-stream-global": "media-proxy",
    "karing-acl4ssr-proxy-media": "media-proxy",
    "lyc-geosite-games": "game-proxy",
    "lyc-geosite-social": "social-proxy",
    "lyc-geosite-telegram": "telegram-proxy",
    "lyc-geoip-telegram": "telegram-proxy",
}
generic_rule_sets = {
    "lyc-geosite-gfw",
    "ddch-gfw",
    "lyc-geosite-proxy",
    "metacubex-geosite-geolocation-not-cn",
    "ddch-proxy",
    "karing-acl4ssr-proxy-lite",
    "karing-acl4ssr-proxy-gfwlist",
}
generic_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule.get("outbound") == "proxy-rule" and generic_rule_sets <= rule_sets(rule)
]
if len(generic_routes) != 1:
    raise SystemExit(f"expected exactly one canonical generic proxy route, found {len(generic_routes)}")
generic_route_index, generic_route = generic_routes[0]
if "network" in generic_route or "port" in generic_route:
    raise SystemExit("canonical generic proxy route must not restrict network or port")

expected_route_indexes = {}
for rule_set, outbound in expected_rule_set_outbounds.items():
    matching_routes = [
        (index, rule) for index, rule in enumerate(route_rules)
        if rule.get("outbound") == outbound and rule_set in rule_sets(rule)
    ]
    if len(matching_routes) != 1:
        raise SystemExit(f"expected exactly one {rule_set} route to {outbound}, found {len(matching_routes)}")
    route_index, route = matching_routes[0]
    if "network" in route or "port" in route:
        raise SystemExit(f"{rule_set} route to {outbound} must not restrict network or port")
    expected_route_indexes[rule_set] = route_index
    if rule_set in generic_rule_sets:
        if route_index != generic_route_index:
            raise SystemExit(f"{rule_set} must resolve to the canonical generic proxy route")
    elif not route_index < generic_route_index:
        raise SystemExit(f"{rule_set} specialized route must precede canonical generic proxy route")

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
canonical_cn_rule_sets = [
    "lyc-geosite-cn",
    "lyc-geosite-geolocation-cn",
    "lyc-geoip-cn",
    "metacubex-geoip-cn",
    "ddch-direct",
    "karing-acl4ssr-china-domain",
    "karing-acl4ssr-china-ip",
]
canonical_cn_ip_rule = {
    "rule_set": ["lyc-geoip-cn", "metacubex-geoip-cn", "karing-acl4ssr-china-ip"],
    "outbound": "cn-direct",
}
canonical_cn_ip_routes = [
    (index, rule) for index, rule in enumerate(route_rules) if rule == canonical_cn_ip_rule
]
if len(canonical_cn_ip_routes) != 1:
    raise SystemExit(
        f"expected one early CN IP-only route before ad rule-sets, found {canonical_cn_ip_routes}"
    )
canonical_cn_ip_index = canonical_cn_ip_routes[0][0]
ad_rule_set_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule.get("outbound") == "ad-block" and "rule_set" in rule
]
if len(ad_rule_set_routes) != 2 or not canonical_cn_ip_index < ad_rule_set_routes[0][0]:
    raise SystemExit(
        "CN IP-only routing must precede both ad IP rule-set routes: "
        f"cn_ip={canonical_cn_ip_routes} ad={ad_rule_set_routes}"
    )
if set(canonical_cn_ip_rule["rule_set"]) & {
    "lyc-geosite-cn", "lyc-geosite-geolocation-cn", "ddch-direct"
}:
    raise SystemExit("CN IP-only route must not include domain or mixed direct rule-sets")
foreign_priority_route_rule = {
    "domain_suffix": foreign_priority_domains,
    "outbound": "proxy-rule",
}
foreign_priority_route_indexes = [
    index for index, rule in enumerate(route_rules) if rule == foreign_priority_route_rule
]
if len(foreign_priority_route_indexes) != 1:
    raise SystemExit(
        "packaged exact 56-domain foreign-priority route must remain unique: "
        f"{foreign_priority_route_indexes}"
    )
foreign_priority_route_index = foreign_priority_route_indexes[0]
if route_rules[foreign_priority_route_index]["domain_suffix"] != dns_rules[foreign_priority_dns_index]["domain_suffix"]:
    raise SystemExit("packaged foreign-priority route/DNS lists must remain identical")
canonical_keyword_rule = {"domain_keyword": network_test_keywords, "outbound": "network-test"}
keyword_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == canonical_keyword_rule
]
if len(keyword_routes) != 1:
    raise SystemExit(f"expected one unchanged network-test keyword route, found {len(keyword_routes)}")
keyword_route_index, _ = keyword_routes[0]
network_test_keyword_set = set(network_test_keywords)
keyword_owners = [
    (index, rule, sorted(network_test_keyword_set & keywords(rule)))
    for index, rule in enumerate(route_rules)
    if network_test_keyword_set & keywords(rule)
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
    raise SystemExit(f"broad network-test keywords must have one exclusive owner: {owner_evidence}")
if keyword_owners[0][0] != keyword_route_index or keyword_owners[0][1] != canonical_keyword_rule:
    raise SystemExit("broad network-test keyword owner is not the canonical unchanged route")
exact_network_test_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == {"domain_suffix": network_test_suffixes, "outbound": "network-test"}
]
if len(exact_network_test_routes) != 1:
    raise SystemExit(f"expected one unchanged foreign network-test suffix route, found {len(exact_network_test_routes)}")
exact_network_test_index, _ = exact_network_test_routes[0]
canonical_cn_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == {"rule_set": canonical_cn_rule_sets, "outbound": "cn-direct"}
]
if len(canonical_cn_routes) != 1:
    raise SystemExit(f"expected one canonical all-network CN route, found {len(canonical_cn_routes)}")
canonical_cn_index, _ = canonical_cn_routes[0]
pcdn_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == {"rule_set": "yuu-geosite-pcdn-cn", "outbound": "download-direct"}
]
explicit_game_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == {"domain_suffix": game_domain_suffixes, "outbound": "game-proxy"}
]
foreign_priority_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == foreign_priority_route_rule
]
if len(pcdn_routes) != 1 or len(explicit_game_routes) != 1 or len(foreign_priority_routes) != 1:
    raise SystemExit(
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
    raise SystemExit(
        "required route order is PCDN < explicit game < foreign priority < canonical CN: "
        f"pcdn={pcdn_index} game={explicit_game_index} foreign={foreign_priority_index} "
        f"cn={canonical_cn_index}"
    )
cn_direct_indexes = [
    index for index, rule in enumerate(route_rules)
    if rule.get("outbound") == "cn-direct"
]
if not cn_direct_indexes or not all(
    index < keyword_route_index for index in cn_direct_indexes
):
    raise SystemExit(
        "destination/rule-set cn-direct routes must precede the network-test keyword fallback"
    )
domestic_probes = {
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
}
for index, rule in enumerate(route_rules[:keyword_route_index]):
    matched_domains = sorted(domain for domain in domestic_probes if explicit_domain_matches(rule, domain))
    if matched_domains and rule.get("outbound") != "cn-direct":
        raise SystemExit(
            f"earlier non-cn route index {index} outbound={rule.get('outbound')} "
            f"shadows domestic probes: {', '.join(matched_domains)}"
        )
if not exact_network_test_index < keyword_route_index:
    raise SystemExit("exact foreign network-test suffix route must precede the keyword fallback")
if not keyword_route_index < generic_route_index:
    raise SystemExit("network-test keyword fallback must precede the canonical generic foreign route")
specialized_rule_set_indexes = {
    index for tag, index in expected_route_indexes.items() if tag not in generic_rule_sets
}
if not specialized_rule_set_indexes or not all(
    keyword_route_index < index for index in specialized_rule_set_indexes
):
    raise SystemExit("network-test keyword fallback must precede specialized foreign rule-set routes")
if keyword_route_index != canonical_cn_index + 1:
    raise SystemExit("network-test keyword fallback must immediately follow the canonical CN route")

specialized_fallback_indexes = []
for suffix_list, outbound in specialized_fallback_specs:
    expected_rule = {"domain_suffix": suffix_list, "outbound": outbound}
    matches = [index for index, rule in enumerate(route_rules) if rule == expected_rule]
    if len(matches) != 1:
        raise SystemExit(f"expected one unchanged explicit {outbound} fallback, found {len(matches)}")
    fallback_index = matches[0]
    specialized_fallback_indexes.append(fallback_index)
    specialized_indexes = {
        index for tag, index in expected_route_indexes.items()
        if expected_rule_set_outbounds[tag] == outbound and tag not in generic_rule_sets
    }
    if len(specialized_indexes) != 1:
        raise SystemExit(
            f"expected one specialized rule-set route for {outbound}, found {sorted(specialized_indexes)}"
        )
    specialized_index = next(iter(specialized_indexes))
    if fallback_index != specialized_index + 1:
        raise SystemExit(
            f"explicit {outbound} fallback index {fallback_index} must immediately follow "
            f"its specialized rule-set route index {specialized_index}"
        )

if specialized_fallback_indexes != sorted(specialized_fallback_indexes):
    raise SystemExit(f"explicit specialized fallback relative order changed: {specialized_fallback_indexes}")
if not all(index < generic_route_index for index in specialized_fallback_indexes):
    raise SystemExit("all explicit specialized fallback routes must precede the canonical generic route")
if generic_route_index != specialized_fallback_indexes[-1] + 1:
    raise SystemExit(
        f"canonical generic route index {generic_route_index} must immediately follow explicit "
        f"specialized fallback block ending at {specialized_fallback_indexes[-1]}"
    )
telegram_ip_routes = [
    index for index, rule in enumerate(route_rules)
    if rule == {"ip_cidr": telegram_ip_cidrs, "outbound": "telegram-proxy"}
]
final_keyword_routes = [
    index for index, rule in enumerate(route_rules)
    if rule == {"domain_keyword": final_foreign_keywords, "outbound": "proxy-rule"}
]
if len(telegram_ip_routes) != 1 or telegram_ip_routes[0] != generic_route_index + 1:
    raise SystemExit(
        f"unchanged Telegram IP route must immediately follow generic route index {generic_route_index}: "
        f"actual={telegram_ip_routes}"
    )
if len(final_keyword_routes) != 1 or final_keyword_routes[0] != telegram_ip_routes[0] + 1:
    raise SystemExit(
        "unchanged final foreign keyword route must immediately follow the Telegram IP route: "
        f"actual={final_keyword_routes}"
    )
if final_keyword_routes[0] != len(route_rules) - 1:
    raise SystemExit(
        "final foreign keyword route must remain the last explicit route before route.final: "
        f"keyword={final_keyword_routes} rule_count={len(route_rules)}"
    )

media_domains = {"youtube.com", "ytimg.com", "googlevideo.com"}
media_rule_indexes = {
    expected_route_indexes["yuu-geosite-stream-global"],
    expected_route_indexes["karing-acl4ssr-proxy-media"],
}
if len(media_rule_indexes) != 1:
    raise SystemExit("media rule-set tags must resolve to one canonical media-proxy route")
media_rule_index = next(iter(media_rule_indexes))
media_fallback_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule.get("outbound") == "media-proxy" and media_domains <= suffixes(rule)
]
if len(media_fallback_routes) != 1:
    raise SystemExit(f"expected exactly one explicit media fallback route, found {len(media_fallback_routes)}")
media_fallback_index, _ = media_fallback_routes[0]
if not media_rule_index < media_fallback_index:
    raise SystemExit("binary media rule-set route must precede explicit media fallback")
for index, rule in enumerate(route_rules[:media_rule_index]):
    shadowed_domains = sorted(domain for domain in media_domains if explicit_domain_matches(rule, domain))
    if shadowed_domains:
        raise SystemExit(
            f"earlier non-media route index {index} outbound={rule.get('outbound')} "
            f"shadows media domains: {', '.join(shadowed_domains)}"
        )

download_suffixes = [
    "steamserver.net",
    "steamcontent.com",
    "steamusercontent.com",
    "akamaihd.net",
    "hwcdn.net",
    "windowsupdate.com",
    "download.windowsupdate.com",
]
expected_download_selector = {
    "type": "selector",
    "tag": "download-direct",
    "outbounds": ["direct", "proxy", "block"],
    "default": "direct",
}
download_selectors = [
    outbound for outbound in config.get("outbounds", []) if outbound.get("tag") == "download-direct"
]
if download_selectors != [expected_download_selector]:
    raise SystemExit(f"download-direct selector is not canonical direct-default: {download_selectors}")
download_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == {"domain_suffix": download_suffixes, "outbound": "download-direct"}
]
if len(download_routes) != 1:
    raise SystemExit(f"expected one unchanged all-network download route, found {len(download_routes)}")
download_route_index, _ = download_routes[0]
microsoft_route = {
    "domain_suffix": [
        "microsoft.com", "windows.com", "windowsupdate.com", "msftauth.net",
        "msauth.net", "office.com", "office365.com", "live.com", "msn.com",
    ],
    "outbound": "microsoft-cn",
}
microsoft_routes = [
    (index, rule) for index, rule in enumerate(route_rules)
    if rule == microsoft_route
]
if len(microsoft_routes) != 1:
    raise SystemExit(f"expected one unchanged Microsoft exact route, found {len(microsoft_routes)}")
microsoft_route_index, _ = microsoft_routes[0]
if not download_route_index < microsoft_route_index:
    raise SystemExit(
        f"download route index {download_route_index} must precede Microsoft exact route "
        f"index {microsoft_route_index}"
    )
if not download_route_index < canonical_cn_index:
    raise SystemExit(
        f"download route index {download_route_index} must precede canonical CN route {canonical_cn_index}"
    )

if recursively_effective_outbound(global_bing_route_rule["outbound"]) != "block":
    raise SystemExit(
        f"r.bing.com route index {global_bing_route_index} must resolve through bing/block"
    )

mmstat_route_index = first_route_index(
    lambda rule: rule.get("outbound") == "ad-block"
    and "lyc-geosite-ads" in (
        rule.get("rule_set")
        if isinstance(rule.get("rule_set"), list)
        else [rule.get("rule_set")]
    )
    and binary_rule_set_matches("lyc-geosite-ads", "mmstat.com")
)
if (
    mmstat_route_index < 0
    or recursively_effective_outbound(route_rules[mmstat_route_index]["outbound"]) != "block"
    or not binary_rule_set_matches("lyc-geosite-ads", "mmstat.com")
):
    raise SystemExit(
        "packaged mmstat.com must use the generic ad rule-set route instead of a vendor direct exception: "
        f"index={mmstat_route_index}"
    )

download_probes = set(download_suffixes)
for index, rule in enumerate(route_rules[:download_route_index]):
    matched_domains = sorted(domain for domain in download_probes if explicit_domain_matches(rule, domain))
    if matched_domains and recursively_effective_outbound(rule.get("outbound")) != "direct":
        raise SystemExit(
            f"earlier non-direct route index {index} outbound={rule.get('outbound')} "
            f"shadows download probes: {', '.join(matched_domains)}"
        )

google_play_proxy_route = first_route_index(
    lambda rule: rule == {
        "package_name": [
            "com.android.vending",
            "com.google.android.gms",
            "com.google.android.gsf",
        ],
        "outbound": "proxy-rule",
    }
)
if google_play_proxy_route < 0:
    raise SystemExit("missing Google Play package proxy rule")
PY

routing_package_root="$elf_tmp/routing-package"
routing_config_dir="$routing_package_root/.config/sing-box"
case "$routing_config_dir" in
    "$elf_tmp"/*) ;;
    *) fail "extracted routing config escaped the package scratch directory" ;;
esac
mkdir -p "$routing_package_root"
unzip -oq "$ZIP_PATH" \
    '.config/sing-box/config.json' \
    '.config/sing-box/rules/*.srs' \
    -d "$routing_package_root"
[[ -f "$routing_config_dir/config.json" ]] || fail "extracted routing config is missing"
printf 'running extracted package default routing policy test\n'
MAGICNET_ROUTING_CONFIG_DIR="$routing_config_dir" \
    bash "$ROOT/scripts/test-default-routing-policy.sh"

watchdog_text="$(unzip -p "$ZIP_PATH" lib/kamfw/watchdog.sh)"
fswatch_text="$(unzip -p "$ZIP_PATH" lib/kamfw/fswatch.sh)"
# shellcheck disable=SC2016
grep -F 'nohup sh "$_wd_script_file"' <<<"$watchdog_text" >/dev/null \
    || fail "watchdog does not launch detached loop script"
grep -F 'KAM_MODULES' <<<"$watchdog_text" >/dev/null \
    || fail "watchdog loop does not reset KAM_MODULES"
# shellcheck disable=SC2016
grep -F 'nohup sh "$_fw_script_file"' <<<"$fswatch_text" >/dev/null \
    || fail "fswatch does not launch detached loop script"
# shellcheck disable=SC2016
grep -F '_fw_tmp_dir="${TMPDIR:-}"' <<<"$fswatch_text" >/dev/null \
    || fail "fswatch does not guard invalid TMPDIR"

printf 'package smoke passed: %s\n' "$ZIP_PATH"
