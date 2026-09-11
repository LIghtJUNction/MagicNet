#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/pre-build/5460.update_chatgpt_voice_rules.sh"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'ChatGPT Voice rule update test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/module/.config/sing-box"
cat >"$TEST_ROOT/module/.config/sing-box/config.json" <<'JSON'
{
  "route": {
    "rules": [
      {
        "network": "udp",
        "port": 3478,
        "ip_cidr": ["192.0.2.1/32"],
        "outbound": "ai-chatgpt"
      },
      {"rule_set": ["lyc-geoip-cn"], "outbound": "cn-direct"}
    ]
  }
}
JSON

cat >"$TEST_ROOT/bin/curl" <<'SH'
#!/bin/bash
set -euo pipefail
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$output" ] || exit 64
case "${FAKE_VOICE_RESPONSE:-valid}" in
    valid)
        cat >"$output" <<'JSON'
{"creationTime":"2026-08-10T00:00:00Z","prefixes":[{"ipv4Prefix":"203.0.113.8/32"},{"ipv6Prefix":"2001:db8::8/128"}]}
JSON
        ;;
    invalid) printf '%s\n' '{"creationTime":"2026-08-10T00:00:00Z","prefixes":[]}' >"$output" ;;
    invalid-prefix) printf '%s\n' '{"creationTime":"2026-08-10T00:00:00Z","prefixes":[{"ipv4Prefix":"999.999.999.999/32"}]}' >"$output" ;;
    failure) exit 22 ;;
    *) exit 64 ;;
esac
SH
chmod +x "$TEST_ROOT/bin/curl"

run_hook() {
    env \
        PATH="$TEST_ROOT/bin:$PATH" \
        KAM_HOOKS_ROOT="$ROOT/hooks" \
        KAM_MODULE_ROOT="$TEST_ROOT/module" \
        FAKE_VOICE_RESPONSE="$1" \
        bash "$HOOK"
}

run_hook valid >/dev/null || fail "valid official response was rejected"
jq -e '
  .route.rules[0] == {
    "network": "udp",
    "port": 3478,
    "ip_cidr": ["203.0.113.8/32", "2001:db8::8/128"],
    "outbound": "ai-chatgpt"
  }
  and .route.rules[1] == (.route.rules[0] | .network = "tcp" | .port = 443)
  and .route.rules[2] == {"rule_set": ["lyc-geoip-cn"], "outbound": "cn-direct"}
  and (.route.rules | length) == 3
' "$TEST_ROOT/module/.config/sing-box/config.json" >/dev/null ||
    fail "valid response was not applied atomically to the canonical rule"

CONFIG="$TEST_ROOT/module/.config/sing-box/config.json"
cp "$CONFIG" "$TEST_ROOT/expected.json"
run_hook valid >/dev/null || fail "second update failed"
cmp -s "$CONFIG" "$TEST_ROOT/expected.json" || fail "update is not idempotent"

# Both transports must refresh together; stale TCP addresses must not survive.
jq '.route.rules[1].ip_cidr = ["192.0.2.9/32"]' "$CONFIG" >"$TEST_ROOT/stale.json"
cp "$TEST_ROOT/stale.json" "$CONFIG"
run_hook valid >/dev/null || fail "stale TCP fallback update failed"
cmp -s "$CONFIG" "$TEST_ROOT/expected.json" || fail "TCP prefixes were not refreshed"

# Verify the exact protocol/port/IP cross product, including negative cases.
python3 - "$CONFIG" <<'PYTEST'
import ipaddress
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    rules = json.load(handle)["route"]["rules"][:2]
for address in ("203.0.113.8", "2001:db8::8", "192.0.2.2"):
    for network in ("tcp", "udp"):
        for port in (443, 3478, 8443):
            matched = any(
                rule["network"] == network and rule["port"] == port
                and any(ipaddress.ip_address(address) in ipaddress.ip_network(prefix)
                        for prefix in rule["ip_cidr"])
                for rule in rules
            )
            expected = address != "192.0.2.2" and (network, port) in {
                ("udp", 3478), ("tcp", 443)
            }
            assert matched == expected, (address, network, port)
PYTEST

# Explicit app policy and unrelated routes retain their position and contents.
jq '.route.rules |= ([{"package_name":["com.openai.chatgpt"],"outbound":"direct"}]
  + . + [{"network":"tcp","port":443,"outbound":"proxy"}])' \
  "$CONFIG" >"$TEST_ROOT/custom.json"
cp "$TEST_ROOT/custom.json" "$CONFIG"
run_hook valid >/dev/null || fail "custom policy update failed"
cmp -s "$CONFIG" "$TEST_ROOT/custom.json" || fail "unrelated policy changed"

# Missing/ambiguous canonical rules fail without replacing the input file.
for filter in '.route.rules |= .[1:]' \
              '.route.rules += [.route.rules[0]]' \
              '.route.rules += [.route.rules[1]]'; do
    jq "$filter" "$TEST_ROOT/expected.json" >"$TEST_ROOT/ambiguous.json"
    cp "$TEST_ROOT/ambiguous.json" "$CONFIG"
    if run_hook valid >/dev/null 2>&1; then
        fail "missing or ambiguous canonical routes were accepted"
    fi
    cmp -s "$CONFIG" "$TEST_ROOT/ambiguous.json" || fail "rejected config was changed"
done
cp "$TEST_ROOT/expected.json" "$CONFIG"

cp "$TEST_ROOT/module/.config/sing-box/config.json" "$TEST_ROOT/before-invalid.json"
if run_hook invalid >/dev/null 2>&1; then
    fail "empty official prefix list was accepted"
fi
cmp -s "$TEST_ROOT/before-invalid.json" "$TEST_ROOT/module/.config/sing-box/config.json" ||
    fail "invalid response changed the active config"

if run_hook invalid-prefix >/dev/null 2>&1; then
    fail "invalid official IP prefix was accepted"
fi
cmp -s "$TEST_ROOT/before-invalid.json" "$TEST_ROOT/module/.config/sing-box/config.json" ||
    fail "invalid IP prefix changed the active config"

if run_hook failure >/dev/null 2>&1; then
    fail "download failure was accepted"
fi
cmp -s "$TEST_ROOT/before-invalid.json" "$TEST_ROOT/module/.config/sing-box/config.json" ||
    fail "download failure changed the active config"

printf 'ChatGPT Voice rule update test passed\n'
