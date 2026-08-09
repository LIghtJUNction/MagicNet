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
  and .route.rules[1] == {"rule_set": ["lyc-geoip-cn"], "outbound": "cn-direct"}
' "$TEST_ROOT/module/.config/sing-box/config.json" >/dev/null ||
    fail "valid response was not applied atomically to the canonical rule"

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
