#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

MODDIR="$WORK/module"
export MODDIR
mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box"

. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/blocklist.sh"

cat >"$MODDIR/.config/magicnet/block-allow-rules.list" <<'EOF'
DOMAIN,ads.example.com
DOMAIN-SUFFIX,example.org
DOMAIN-KEYWORD,sponsor
EOF
cat >"$MODDIR/.config/magicnet/community-ban-rules.list" <<'EOF'
DOMAIN,ads.example.com
DOMAIN-SUFFIX,blocked.example
EOF
cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "ad-block",
      "outbounds": ["block", "direct"],
      "default": "direct"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["tun-in"],
        "action": "sniff"
      },
      {
        "rule_set": "ads",
        "outbound": "ad-block"
      }
    ]
  }
}
EOF

magicnet_block_apply_singbox
magicnet_block_apply_singbox

CONFIG="$MODDIR/.config/sing-box/config.json"
[ "$(grep -c '__magicnet_ad_allow__' "$CONFIG")" -eq 1 ]
[ "$(grep -c '__magicnet_block__' "$CONFIG")" -eq 1 ]
[ "$(grep -c '"tag": "ad-block"' "$CONFIG")" -eq 1 ]
[ "$(grep -c '"tag": "ad-allow"' "$CONFIG")" -eq 1 ]
grep -q '"outbound": "ad-allow"' "$CONFIG"
grep -q '"outbound": "ad-block"' "$CONFIG"
grep -q '"ads.example.com"' "$CONFIG"
grep -q '"example.org"' "$CONFIG"
grep -q '"sponsor"' "$CONFIG"
if grep -A8 '__magicnet_block__' "$CONFIG" | grep -q 'ads.example.com'; then
  exit 1
fi

ALLOW_LINE=$(grep -n '__magicnet_ad_allow__' "$CONFIG" | cut -d: -f1)
BLOCK_LINE=$(grep -n '__magicnet_block__' "$CONFIG" | cut -d: -f1)
STATIC_LINE=$(grep -n '"rule_set": "ads"' "$CONFIG" | cut -d: -f1)
[ "$ALLOW_LINE" -lt "$BLOCK_LINE" ]
[ "$BLOCK_LINE" -lt "$STATIC_LINE" ]

: >"$MODDIR/.config/magicnet/block-allow-rules.list"
magicnet_block_apply_singbox
if grep -q '__magicnet_ad_allow__' "$CONFIG"; then
  exit 1
fi

grep -Fq 'selector("ad-block"; ["block", "direct", "proxy"]; "block")' \
  "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
grep -Fq 'selector("ad-allow"; ["direct", "proxy"]; "direct")' \
  "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"

if command -v jq >/dev/null 2>&1; then
  jq -e '
    (.outbounds[] | select(.tag == "ad-block") | .outbounds == ["block", "direct", "proxy"] and .default == "block") and
    (.outbounds[] | select(.tag == "ad-allow") | .outbounds == ["direct", "proxy"] and .default == "direct") and
    (.outbounds[] | select(.tag == "ad-block") | .outbounds == ["block", "direct", "proxy"]) and
    (.outbounds[] | select(.tag == "ad-allow") | .outbounds == ["direct", "proxy"])
  ' "$ROOT/src/MagicNet/.config/sing-box/config.json" >/dev/null
  jq empty "$CONFIG"
  [ "$(jq '[.route.rules[] | select(has("domain") and (.domain | index("__magicnet_ad_allow__")))] | length' "$CONFIG")" -eq 0 ]
fi

printf '%s\n' 'ad routing regression tests passed'
