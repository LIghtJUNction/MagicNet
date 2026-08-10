#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-singbox-ready.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

cat >"$fixture/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
exit "${CURL_RC:-1}"
SH
chmod +x "$fixture/curl"

import() { :; }
set_i18n() { :; }
. "$ROOT/src/MagicNet/lib/kamfw/__singbox__.sh"

is_singbox_running() { return 0; }

curl_log="$fixture/curl.log"
: >"$curl_log"
if PATH="$fixture:$PATH" \
    CURL_LOG="$curl_log" CURL_RC=1 \
    MAGICNET_SINGBOX_READY_TRIES=2 MAGICNET_SINGBOX_READY_DELAY=0 \
    singbox_wait_ready; then
    echo "readiness accepted a live but unready Clash API" >&2
    exit 1
fi
test "$(wc -l <"$curl_log" | tr -d ' ')" = 2

: >"$curl_log"
PATH="$fixture:$PATH" \
    CURL_LOG="$curl_log" CURL_RC=0 \
    MAGICNET_SINGBOX_READY_TRIES=2 MAGICNET_SINGBOX_READY_DELAY=0 \
    singbox_wait_ready
test "$(wc -l <"$curl_log" | tr -d ' ')" = 1

# A standalone config may deliberately omit experimental.clash_api.  In that
# mode readiness must use the live process and must not require port 9090.
mkdir -p "$fixture/module/.config/sing-box"
printf '%s\n' '{"inbounds":[],"outbounds":[],"experimental":{}}' \
  >"$fixture/module/.config/sing-box/config.json"
: >"$curl_log"
MODDIR="$fixture/module" PATH="$fixture:$PATH" \
  CURL_LOG="$curl_log" CURL_RC=1 \
  MAGICNET_SINGBOX_READY_TRIES=2 MAGICNET_SINGBOX_READY_DELAY=0 \
  singbox_wait_ready
test ! -s "$curl_log"

# When jq is absent, the fallback parser must still recognize the multiline
# Clash API block and keep the strict readiness probe enabled.
cat >"$fixture/module/.config/sing-box/config.json" <<'JSON'
{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090"
    }
  }
}
JSON
command() {
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "jq" ]; then
        return 1
    fi
    builtin command "$@"
}
test -n "$(MODDIR="$fixture/module" singbox_clash_api_configured && printf configured)"
unset -f command

printf 'sing-box readiness test passed\n'
