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

for tool in file grep python3 readelf sed unzip zipinfo; do
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

require_entry module.prop
require_entry customize.sh
require_entry cli
require_entry bin/magicnet-cli
require_entry bin/magicnet-mcp-server
require_entry bin/sing-box
require_entry bin/ecapture
require_entry lib/kamfw/watchdog.sh
require_entry lib/kamfw/fswatch.sh

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

check_no_subscription_secret() {
    local entry="$1"
    grep -Fx "$entry" "$entries_file" >/dev/null || return 0
    if unzip -p "$ZIP_PATH" "$entry" | grep -Eiq '^[[:space:]]*[^#[:space:]].*(https?://|ss://|trojan://|vmess://|vless://|hysteria2://|tuic://|socks5://|sub=|token=|uuid=|password=|passwd=)'; then
        fail "$entry contains subscription-like secrets"
    fi
}

check_no_subscription_secret '.config/sing-box/subscription.url'

python3 - "$ZIP_PATH" <<'PY'
import json
import subprocess
import sys

zip_path = sys.argv[1]
config = json.loads(
    subprocess.check_output(
        ["unzip", "-p", zip_path, ".config/sing-box/config.json"],
        text=True,
    )
)

dns_rules = config.get("dns", {}).get("rules", [])
route_rules = config.get("route", {}).get("rules", [])
outbound_tags = {outbound.get("tag") for outbound in config.get("outbounds", [])}

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

def suffixes(rule):
    value = rule.get("domain_suffix", [])
    if isinstance(value, str):
        return {value}
    return set(value)

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

if "dns-guard" not in outbound_tags:
    raise SystemExit("missing dns-guard outbound selector")

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

dot_route = first_route_index(lambda rule: rule.get("port") == 853 and rule.get("outbound") == "dns-guard")
if dot_route < 0:
    raise SystemExit("missing dns-guard route for DoT port 853")

udp443_route = first_route_index(
    lambda rule: rule.get("network") == "udp"
    and rule.get("port") == 443
    and rule.get("outbound") == "proxy-rule"
    and "lyc-geosite-proxy" in (
        rule.get("rule_set") if isinstance(rule.get("rule_set"), list) else [rule.get("rule_set")]
    )
)
if udp443_route < 0:
    raise SystemExit("missing UDP/443 proxy rule for foreign rule sets")
PY

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
