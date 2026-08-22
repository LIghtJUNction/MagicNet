#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-singbox-ready.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export MODDIR="$fixture/module"
config_file="$MODDIR/.config/sing-box/config.json"
mkdir -p "${config_file%/*}"

cat >"$fixture/curl" <<'SH'
#!/bin/sh
printf 'probe\n' >>"$CURL_LOG"
[ "${CURL_RC:-1}" -eq 0 ] && printf '%s\n' '{"version":"test"}'
exit "${CURL_RC:-1}"
SH
chmod +x "$fixture/curl"

. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
magicnet_singbox_owned_pids() { printf '%s\n' 123; }
magicnet_singbox_listener_owned() { return 0; }

curl_log="$fixture/curl.log"
: >"$curl_log"
cat >"$config_file" <<'JSON'
{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}}
JSON
if PATH="$fixture:$PATH" CURL_LOG="$curl_log" CURL_RC=1 \
    magicnet_singbox_owned_ready "$config_file"; then
    printf '%s\n' 'Clash API config became ready without a successful API probe' >&2
    exit 1
fi
[ "$(wc -l <"$curl_log" | tr -d ' ')" -eq 1 ]

: >"$curl_log"
PATH="$fixture:$PATH" CURL_LOG="$curl_log" CURL_RC=0 \
    magicnet_singbox_owned_ready "$config_file"
[ "$(wc -l <"$curl_log" | tr -d ' ')" -eq 1 ]

: >"$curl_log"
printf '%s\n' '{"inbounds":[],"outbounds":[],"experimental":{}}' >"$config_file"
PATH="$fixture:$PATH" CURL_LOG="$curl_log" CURL_RC=1 \
    magicnet_singbox_owned_ready "$config_file"
[ ! -s "$curl_log" ]

printf '%s\n' 'sing-box readiness test passed'
