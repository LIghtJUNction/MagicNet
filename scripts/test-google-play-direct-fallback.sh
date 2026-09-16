#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export MODDIR="$ROOT/src/MagicNet"
. "$MODDIR/lib/magicnet/singbox_subscribe/common.sh"
. "$MODDIR/lib/magicnet/singbox_subscribe/config.sh"
magicnet_singbox_subscription_filter_file() { printf '%s\n' "$fixture/filters"; }
cat >"$fixture/config.json" <<'JSON'
{
  "inbounds": [{"type":"mixed","listen":"127.0.0.1","listen_port":7892}],
  "outbounds": [
    {"type":"socks","tag":"US-node","server":"127.0.0.1","server_port":1080,"version":"5"},
    {"type":"selector","tag":"google-proxy","outbounds":["proxy","direct","block"],"default":"block"},
    {"type":"direct","tag":"direct"}, {"type":"block","tag":"block"}
  ],
  "route":{"rules":[
    {"package_name":["com.example.other","com.google.android.gsf"],"network":"tcp","outbound":"google-proxy"},
    {"package_name":"com.android.vending","outbound":"proxy"},
    {"package_name":["com.google.android.gms"],"outbound":"block"},
    {"package_name":["com.android.vending"],"invert":true,"outbound":"proxy"},
    {"domain_suffix":["google.com"],"outbound":"google-proxy"},
    {"package_name":["com.google.android.apps.bard"],"outbound":"ai-gemini"}
  ]}
}
JSON
# Use the production sanitizer, not an overriding wrapper or a mocked policy.
magicnet_singbox_sanitize_generated_config "$fixture/config.json"
jq -e '
  .route.rules as $r
  | $r[0] == {package_name:["com.google.android.gsf"],network:"tcp",outbound:"direct"}
  and $r[1] == {package_name:["com.example.other"],network:"tcp",outbound:"google-proxy"}
  and $r[2] == {package_name:["com.android.vending"],outbound:"direct"}
  and $r[3] == {package_name:["com.google.android.gms"],outbound:"block"}
  and $r[4] == {package_name:["com.android.vending"],invert:true,outbound:"proxy"}
  and $r[5] == {domain_suffix:["google.com"],outbound:"google-proxy"}
  and $r[6] == {package_name:["com.google.android.apps.bard"],outbound:"ai-gemini"}
  and (.outbounds[] | select(.tag=="google-proxy") | .default=="block")
  and ([.outbounds[] | select(.tag=="magicnet-gemini-auto")] | length==0)
' "$fixture/config.json" >/dev/null
cp "$fixture/config.json" "$fixture/once.json"
magicnet_singbox_sanitize_generated_config "$fixture/config.json"
cmp "$fixture/config.json" "$fixture/once.json"
# Absence of a direct outbound must not introduce dangling references.
printf '%s\n' '{"outbounds":[],"route":{"rules":[{"package_name":"com.android.vending","outbound":"proxy"}]}}' >"$fixture/no-direct.json"
jq -L "$MODDIR/lib/magicnet/jq" 'include "google-play-policy"; google_play_direct_fallback' "$fixture/no-direct.json" >"$fixture/no-direct-after.json"
jq -e '.route.rules[0].outbound=="proxy"' "$fixture/no-direct-after.json" >/dev/null
printf 'Google Play native policy, mixed-package isolation, operator choices and idempotence passed\n'
