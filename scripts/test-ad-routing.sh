#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' 'jq is required for ad routing regression tests' >&2
  exit 1
fi

MODDIR="$WORK/module"
export MODDIR
mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box"

. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
. "$ROOT/src/MagicNet/lib/magicnet/blocklist.sh"

assert_subscription_ad_allow() {
  _fragment="$1"
  _config="$2"
  {
    printf '{\n'
    cat "$_fragment"
    printf '\n  "route": {}\n}\n'
  } >"$_config"
  jq -e '
    [.outbounds[] | select(.tag == "ad-allow")] == [{
      "type": "selector",
      "tag": "ad-allow",
      "outbounds": ["final", "direct", "proxy"],
      "default": "final"
    }]
  ' "$_config" >/dev/null
  unset _fragment _config
}

mkdir -p "$WORK/subscription-jq" "$WORK/subscription-no-jq/nodes"
printf '[]' >"$WORK/subscription-jq/nodes.json"
: >"$WORK/subscription-jq/tags"
magicnet_singbox_build_outbounds_file_with_jq \
  "$WORK/subscription-jq/nodes.json" \
  "$WORK/subscription-jq/tags" \
  "$WORK/subscription-jq/outbounds"
assert_subscription_ad_allow \
  "$WORK/subscription-jq/outbounds" \
  "$WORK/subscription-jq/config.json"

magicnet_singbox_build_outbounds_file_with_jq() {
  return 1
}
magicnet_singbox_build_outbounds_file \
  "$WORK/subscription-no-jq/nodes" \
  "$WORK/subscription-no-jq/outbounds" \
  "$WORK/subscription-no-jq/tags" >/dev/null
assert_subscription_ad_allow \
  "$WORK/subscription-no-jq/outbounds" \
  "$WORK/subscription-no-jq/config.json"

cat >"$MODDIR/.config/magicnet/block-allow-rules.list" <<'EOF'
DOMAIN,ads.example.com
DOMAIN-SUFFIX,example.org
DOMAIN-SUFFIX,https://Forum.Mobilism.org.:443/path?from=legacy#post
DOMAIN-SUFFIX,forum.mobilism.org
DOMAIN-SUFFIX,https://forum.mobilism.org/duplicate
DOMAIN-KEYWORD,sponsor
PROCESS-NAME,KeepThis
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
        "domain_suffix": ["local", "home.arpa", "lan"],
        "outbound": "lan"
      },
      {
        "domain_keyword": ["adservice", "analytics", "tracking", "tracker"],
        "outbound": "ad-block"
      },
      {
        "rule_set": "hagezi-anti-piracy",
        "outbound": "ad-block"
      }
    ]
  }
}
EOF

magicnet_block_apply_singbox
ALLOW_RULES_AFTER_FIRST_APPLY=$(cat "$MODDIR/.config/magicnet/block-allow-rules.list")
magicnet_block_apply_singbox
[ "$ALLOW_RULES_AFTER_FIRST_APPLY" = "$(cat "$MODDIR/.config/magicnet/block-allow-rules.list")" ]

CONFIG="$MODDIR/.config/sing-box/config.json"
[ "$(grep -c '__magicnet_ad_allow__' "$CONFIG")" -eq 1 ]
[ "$(grep -c '__magicnet_block__' "$CONFIG")" -eq 1 ]
[ "$(grep -c '"tag": "ad-block"' "$CONFIG")" -eq 1 ]
[ "$(grep -c '"tag": "ad-allow"' "$CONFIG")" -eq 1 ]
grep -q '"outbound": "ad-allow"' "$CONFIG"
grep -q '"outbound": "ad-block"' "$CONFIG"
grep -q '"ads.example.com"' "$CONFIG"
grep -q '"example.org"' "$CONFIG"
grep -q '"forum.mobilism.org"' "$CONFIG"
grep -q '"sponsor"' "$CONFIG"
grep -qx 'DOMAIN-SUFFIX,forum.mobilism.org' "$MODDIR/.config/magicnet/block-allow-rules.list"
grep -qx 'PROCESS-NAME,KeepThis' "$MODDIR/.config/magicnet/block-allow-rules.list"
[ "$(grep -c '^DOMAIN-SUFFIX,forum\.mobilism\.org$' "$MODDIR/.config/magicnet/block-allow-rules.list")" -eq 1 ]
if grep -Eiq 'DOMAIN(-SUFFIX)?,https?://' "$MODDIR/.config/magicnet/block-allow-rules.list"; then
  exit 1
fi
if grep -A8 '__magicnet_block__' "$CONFIG" | grep -q 'ads.example.com'; then
  exit 1
fi

ALLOW_LINE=$(grep -n '__magicnet_ad_allow__' "$CONFIG" | cut -d: -f1)
BLOCK_LINE=$(grep -n '__magicnet_block__' "$CONFIG" | cut -d: -f1)
STATIC_LINE=$(grep -n '"rule_set": "hagezi-anti-piracy"' "$CONFIG" | cut -d: -f1)
[ "$ALLOW_LINE" -lt "$BLOCK_LINE" ]
[ "$BLOCK_LINE" -lt "$STATIC_LINE" ]
jq -e '
  any(.route.rules[];
    .outbound == "ad-allow" and ((.domain_suffix // []) | index("forum.mobilism.org")))
  and (([.route.rules | to_entries[]
          | select(.value == {"domain_suffix": ["local", "home.arpa", "lan"], "outbound": "lan"})
          | .key]) as $lan
       | ([.route.rules | to_entries[]
            | select(.value == {"domain_keyword": ["adservice", "analytics", "tracking", "tracker"], "outbound": "ad-block"})
            | .key]) as $ad
       | ($lan | length) == 1 and ($ad | length) == 1 and $lan[0] < $ad[0])
' "$CONFIG" >/dev/null

: >"$MODDIR/.config/magicnet/block-allow-rules.list"
magicnet_block_apply_singbox
if grep -q '__magicnet_ad_allow__' "$CONFIG"; then
  exit 1
fi

SRS="$ROOT/src/MagicNet/.config/sing-box/rules/hagezi-anti-piracy.srs"
if command -v sing-box >/dev/null 2>&1 && [ -f "$SRS" ]; then
  MATCH_OUTPUT=$(sing-box rule-set match -f binary "$SRS" forum.mobilism.org 2>&1)
  [ -n "$MATCH_OUTPUT" ]
fi

jq -e '
  (.outbounds[] | select(.tag == "ad-block") | .outbounds == ["block", "direct", "proxy"] and .default == "block") and
  (.outbounds[] | select(.tag == "ad-allow") | .outbounds == ["final", "direct", "proxy"] and .default == "final") and
  (.outbounds[] | select(.tag == "ad-block") | .outbounds == ["block", "direct", "proxy"]) and
  (.outbounds[] | select(.tag == "ad-allow") | .outbounds == ["final", "direct", "proxy"])
' "$ROOT/src/MagicNet/.config/sing-box/config.json" >/dev/null
jq empty "$CONFIG"
[ "$(jq '[.route.rules[] | select(has("domain") and (.domain | index("__magicnet_ad_allow__")))] | length' "$CONFIG")" -eq 0 ]

printf '%s\n' 'ad routing regression tests passed'
