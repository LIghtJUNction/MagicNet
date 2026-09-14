#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-google-play.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

export MODDIR="$fixture/module"
mkdir -p "$MODDIR/bin" "$MODDIR/.config/sing-box"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"

magicnet_jq() { printf '%s\n' "$MODDIR/bin/jq"; }
magicnet_singbox_recovery_config_valid() { jq -e 'type == "object" and (.outbounds|type)=="array" and (.route.rules|type)=="array"' "$1" >/dev/null; }
warn() { :; }
error() { printf '%s\n' "$1" >&2; }

# Only source the focused hardening layer; the wrapper itself is not exercised
# here because lifecycle behavior already has dedicated subscription tests.
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/hardening.sh"

config="$MODDIR/.config/sing-box/config.json"
cat >"$config" <<'JSON'
{
  "outbounds": [
    {"type":"selector","tag":"proxy","outbounds":["node","direct"],"default":"node"},
    {"type":"selector","tag":"google-proxy","outbounds":["proxy","direct"],"default":"proxy"},
    {"type":"socks","tag":"node","server":"127.0.0.1","server_port":1080,"version":"5"},
    {"type":"direct","tag":"direct"}
  ],
  "route": {"rules": [
    {"package_name":["com.android.vending"],"outbound":"google-proxy"},
    {"package_name":"com.google.android.gms","outbound":"proxy"},
    {"package_name":["com.example.other","com.google.android.gsf"],"outbound":"google-proxy"},
    {"domain_suffix":["google.com"],"outbound":"google-proxy"},
    {"package_name":["com.example.other"],"outbound":"proxy"}
  ]}
}
JSON

result="$(magicnet_singbox_google_play_direct_fallback_patch "$config")"
test "$result" = changed
jq -e '
  def packages:
    if ((.package_name? // null)|type)=="array" then .package_name
    elif ((.package_name? // null)|type)=="string" then [.package_name]
    else [] end;
  def has($p): (packages | index($p)) != null;
  ([.route.rules[] | select(has("com.android.vending"))][0].outbound == "direct")
  and ([.route.rules[] | select(has("com.google.android.gms"))][0].outbound == "direct")
  and ([.route.rules[] | select(has("com.google.android.gsf"))][0].outbound == "direct")
  and ([.route.rules[] | select(.domain_suffix? == ["google.com"])][0].outbound == "google-proxy")
  and ([.route.rules[] | select(.package_name? == ["com.example.other"])][0].outbound == "proxy")
' "$config" >/dev/null

test "$(magicnet_singbox_google_play_direct_fallback_patch "$config")" = unchanged
printf '%s\n' 'Google Play package direct fallback test passed'
