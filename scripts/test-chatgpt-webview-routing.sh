#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/pre-build/5470.ensure_chatgpt_webview_route.sh"
TEST_ROOT="$(mktemp -d)"
CONFIG="$TEST_ROOT/module/.config/sing-box/config.json"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'ChatGPT WebView routing test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$TEST_ROOT/module/.config"
cp -a "$ROOT/src/MagicNet/.config/sing-box" "$TEST_ROOT/module/.config/"

run_hook() {
    env \
        KAM_HOOKS_ROOT="$ROOT/hooks" \
        KAM_MODULE_ROOT="$TEST_ROOT/module" \
        bash "$HOOK"
}

run_hook >/dev/null || fail "canonical config was rejected"
cp "$CONFIG" "$TEST_ROOT/first.json"
run_hook >/dev/null || fail "second application was rejected"
cmp -s "$TEST_ROOT/first.json" "$CONFIG" || fail "hook is not idempotent"

python3 - "$CONFIG" <<'PY'
import ipaddress
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

fake_range = "198.18.0.0/24"
fake_server = {
    "type": "fakeip",
    "tag": "chatgpt-fakeip",
    "inet4_range": fake_range,
}
route_rules = config["route"]["rules"]
dns_rules = config["dns"]["rules"]
chatgpt_domains = next(
    rule["domain_suffix"]
    for rule in route_rules
    if rule.get("outbound") == "ai-chatgpt"
    and "chatgpt.com" in rule.get("domain_suffix", [])
)
fake_dns = {"domain_suffix": chatgpt_domains, "server": "chatgpt-fakeip"}
fake_route = {"ip_cidr": [fake_range], "outbound": "ai-chatgpt"}
cn_ip = {
    "rule_set": ["lyc-geoip-cn", "metacubex-geoip-cn", "karing-acl4ssr-china-ip"],
    "outbound": "cn-direct",
}

if config["dns"]["servers"].count(fake_server) != 1:
    raise AssertionError("expected one canonical ChatGPT FakeIP server")
if dns_rules.count(fake_dns) != 1:
    raise AssertionError("expected one canonical ChatGPT FakeIP DNS rule")
if route_rules.count(fake_route) != 1:
    raise AssertionError("expected one canonical ChatGPT FakeIP route")
if config.get("experimental", {}).get("cache_file", {}).get("store_fakeip") is not True:
    raise AssertionError("ChatGPT FakeIP mappings must survive core restarts")

dns_fake_index = dns_rules.index(fake_dns)
route_fake_index = route_rules.index(fake_route)
dns_global_index = next(i for i, rule in enumerate(dns_rules) if rule.get("clash_mode") == "Global")
route_global_index = next(i for i, rule in enumerate(route_rules) if rule.get("clash_mode") == "Global")
cn_ip_index = route_rules.index(cn_ip)
cn_dns_index = next(
    i for i, rule in enumerate(dns_rules)
    if rule.get("server") == "bootstrap-local-dns"
    and "lyc-geosite-cn" in rule.get("rule_set", [])
    and "lyc-geoip-cn" in rule.get("rule_set", [])
)
if not dns_global_index < dns_fake_index < cn_dns_index:
    raise AssertionError("ChatGPT FakeIP DNS must follow mode rules and precede CN classification")
if not route_global_index < route_fake_index < cn_ip_index:
    raise AssertionError("ChatGPT FakeIP routing must follow mode rules and precede CN classification")
if route_fake_index + 1 != cn_ip_index:
    raise AssertionError("ChatGPT FakeIP ownership must precede CN destination-IP routing")

probe = ipaddress.ip_address("198.18.0.42")
for index, rule in enumerate(route_rules):
    cidrs = rule.get("ip_cidr", [])
    if isinstance(cidrs, str):
        cidrs = [cidrs]
    if cidrs and any(probe in ipaddress.ip_network(cidr) for cidr in cidrs):
        if (index, rule.get("outbound")) != (route_fake_index, "ai-chatgpt"):
            raise AssertionError(
                f"metadata-free ChatGPT WebView flow matched {index}/{rule.get('outbound')}"
            )
        break
else:
    raise AssertionError("metadata-free ChatGPT WebView flow had no route")

if not any(
    rule == fake_dns
    and any(
        domain == suffix or domain.endswith("." + suffix)
        for suffix in rule["domain_suffix"]
    )
    for domain in ("chatgpt.com", "cdn.oaistatic.com", "files.oaiusercontent.com")
    for rule in dns_rules
):
    raise AssertionError("ChatGPT first-party domains do not use the managed FakeIP server")
PY

all_rule_sets_present=true
while IFS= read -r rule_path; do
    if [[ ! -f "$(dirname "$CONFIG")/$rule_path" ]]; then
        all_rule_sets_present=false
        break
    fi
done < <(jq -r '.route.rule_set[]? | select(.type == "local") | .path' "$CONFIG")
if command -v sing-box >/dev/null 2>&1 && [[ "$all_rule_sets_present" == "true" ]]; then
    sing-box check -c "$CONFIG" -D "$(dirname "$CONFIG")" >/dev/null ||
        fail "sing-box rejected the generated config"
fi

printf 'ChatGPT WebView routing test passed\n'
