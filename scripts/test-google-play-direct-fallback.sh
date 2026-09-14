#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-google-services.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

export MODDIR="$fixture/module"
mkdir -p "$MODDIR/bin" "$MODDIR/.config/sing-box"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"

magicnet_jq() { printf '%s\n' "$MODDIR/bin/jq"; }
magicnet_singbox_recovery_config_valid() { jq -e 'type == "object" and (.outbounds|type)=="array" and (.route.rules|type)=="array"' "$1" >/dev/null; }
warn() { :; }
error() { printf '%s\n' "$1" >&2; }

. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/hardening.sh"

test "$GOMEMLIMIT" = 96MiB

config="$MODDIR/.config/sing-box/config.json"
cat >"$config" <<'JSON'
{
  "outbounds": [
    {"type":"urltest","tag":"proxy-auto","outbounds":["node"],"url":"https://www.gstatic.com/generate_204","interval":"3m"},
    {"type":"selector","tag":"proxy","outbounds":["node","proxy-auto","direct"],"default":"node"},
    {"type":"selector","tag":"google-proxy","outbounds":["proxy","direct","node"],"default":"proxy"},
    {"type":"urltest","tag":"ai-gemini-auto","outbounds":["node"],"url":"https://gemini.google.com/","interval":"10m"},
    {"type":"selector","tag":"ai-gemini","outbounds":["node","block","ai-gemini-auto"],"default":"node"},
    {"type":"socks","tag":"node","server":"127.0.0.1","server_port":1080,"version":"5"},
    {"type":"direct","tag":"direct"},
    {"type":"block","tag":"block"}
  ],
  "route": {"rules": [
    {"package_name":["com.android.vending"],"outbound":"google-proxy"},
    {"package_name":"com.google.android.gms","outbound":"proxy"},
    {"package_name":["com.example.other","com.google.android.gsf"],"outbound":"google-proxy"},
    {"package_name":["com.google.android.apps.bard"],"outbound":"ai-gemini"},
    {"rule_set":["meta-google-gemini"],"outbound":"ai-gemini"},
    {"domain_suffix":["google.com"],"outbound":"google-proxy"},
    {"package_name":["com.example.other"],"outbound":"proxy"}
  ]}
}
JSON

result="$(magicnet_singbox_google_reliability_patch "$config")"
test "$result" = changed
jq -e '
  def packages:
    if ((.package_name? // null)|type)=="array" then .package_name
    elif ((.package_name? // null)|type)=="string" then [.package_name]
    else [] end;
  def has($p): (packages | index($p)) != null;
  ([.outbounds[] | select(.tag=="magicnet-google-auto")] | length) == 1
  and (.outbounds[] | select(.tag=="magicnet-google-auto")
       | .type=="urltest"
         and .url=="https://www.google.com/generate_204"
         and (.outbounds | index("node")) != null
         and (.outbounds | index("direct")) != null)
  and (.outbounds[] | select(.tag=="google-proxy")
       | .default=="magicnet-google-auto"
         and (.outbounds | index("magicnet-google-auto")) != null)
  and (.outbounds[] | select(.tag=="ai-gemini-auto")
       | (.outbounds | index("direct")) != null)
  and ([.route.rules[] | select(has("com.android.vending"))][0].outbound == "direct")
  and ([.route.rules[] | select(has("com.google.android.gms"))][0].outbound == "direct")
  and ([.route.rules[] | select(has("com.google.android.gsf"))][0].outbound == "direct")
  and ([.route.rules[] | select(has("com.google.android.apps.bard"))][0].outbound == "ai-gemini-auto")
  and ([.route.rules[] | select((.rule_set? // []) | index("meta-google-gemini"))][0].outbound == "ai-gemini-auto")
  and ([.route.rules[] | select(.domain_suffix? == ["google.com"])][0].outbound == "google-proxy")
  and ([.route.rules[] | select(.package_name? == ["com.example.other"])][0].outbound == "proxy")
' "$config" >/dev/null

test "$(magicnet_singbox_google_reliability_patch "$config")" = unchanged

# An explicit operator pin must survive the reliability patch. Only the generated
# default `proxy` is migrated to the Google-specific automatic health group.
jq '(.outbounds[] | select(.tag=="google-proxy")).default="direct"' "$config" >"$fixture/explicit.json"
test "$(magicnet_singbox_google_reliability_patch "$fixture/explicit.json")" = changed
jq -e '.outbounds[] | select(.tag=="google-proxy") | .default=="direct"' "$fixture/explicit.json" >/dev/null

printf '%s\n' 'Google Play, Gmail/Google selector, Gemini auto routing and memory limit regression passed'
