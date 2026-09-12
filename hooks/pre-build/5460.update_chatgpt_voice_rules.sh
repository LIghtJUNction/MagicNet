#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
set -euo pipefail
. "$KAM_HOOKS_ROOT/lib/utils.sh"
require_command curl "curl not found!"
require_command jq "jq not found!"
require_command python3 "python3 not found!"

RULE_DIR="$KAM_MODULE_ROOT/.config/sing-box/rules"
STATE_DIR="$KAM_MODULE_ROOT/.local/state/chatgpt-voice"
mkdir -p "$RULE_DIR" "$STATE_DIR"
CANDIDATE=$(mktemp "$RULE_DIR/.chatgpt-voice.XXXXXX")
trap 'rm -f "$CANDIDATE"' EXIT
# Resolve one immutable upstream revision per build; never rewrite config.json.
REF=$(curl -fsSL --connect-timeout 5 --max-time 20 --retry 3 \
    https://api.github.com/repos/SukkaLab/ruleset.skk.moe/git/ref/heads/master |
    jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))')
curl -fsSL --connect-timeout 5 --max-time 20 --retry 3 \
    "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/$REF/sing-box/ip/ai.json" \
    -o "$CANDIDATE"
python3 - "$CANDIDATE" <<'PY'
import ipaddress
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
assert data.get("version") in (1, 2, 3), "unsupported rule-set version"
rules = data.get("rules")
assert isinstance(rules, list) and rules, "empty rules"
for rule in rules:
    assert set(rule) <= {"ip_cidr", "domain", "domain_suffix"}, "unexpected matching fields"
    prefixes = rule.get("ip_cidr")
    assert isinstance(prefixes, list) and prefixes, "missing voice prefixes"
    for prefix in prefixes:
        network = ipaddress.ip_network(prefix, strict=True)
        assert network.prefixlen > 0, "catch-all prefix refused"
PY
chmod 644 "$CANDIDATE"
mv -f "$CANDIDATE" "$RULE_DIR/sukka-chatgpt-voice.json"
printf '%s\n' "$REF" >"$STATE_DIR/upstream-revision"
log_success "ChatGPT Voice rule-set refreshed from SukkaLab@$REF"
