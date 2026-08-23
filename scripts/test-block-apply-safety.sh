#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

export MODDIR="$tmp/module"
mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box" "$MODDIR/bin"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"
cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "ad-block",
      "outbounds": ["block", "direct", "proxy"],
      "default": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "domain": ["__magicnet_block__"],
        "outbound": "ad-block"
      }
    ]
  }
}
EOF

magicnet_warn() { :; }
magicnet_json_escape() { printf '%s' "$1"; }
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
. "$ROOT/src/MagicNet/lib/magicnet/subscribe_bootstrap.sh"
. "$ROOT/src/MagicNet/lib/magicnet/blocklist.sh"

# Valid compact JSON must be normalized structurally; line-oriented insertion
# used to return success while adding neither selector. A deterministic legacy
# temp symlink must not redirect generated config bytes outside the module.
printf '%s\n' 'outside-canary' >"$tmp/outside"
selector_hint="$MODDIR/.config/sing-box/config.json.magicnet-selectors.new"
ln -s "$tmp/outside" "$selector_hint"
printf '%s\n' 'allowed.example' >"$(magicnet_block_allow_file)"
printf '%s\n' '{"outbounds":[{"type":"direct","tag":"direct"},{"type":"selector","tag":"final","outbounds":["direct"],"default":"direct"}],"route":{"rules":[]}}' >"$MODDIR/.config/sing-box/config.json"
magicnet_block_ensure_ad_selectors "$MODDIR/.config/sing-box/config.json"
jq -e '
  ([.outbounds[] | select(.tag == "ad-block")] | length == 1)
  and ([.outbounds[] | select(.tag == "ad-allow")] | length == 1)
' "$MODDIR/.config/sing-box/config.json" >/dev/null
[[ "$(<"$tmp/outside")" == outside-canary ]]
[[ ! -e "$selector_hint" && ! -L "$selector_hint" ]]

# The shared route-rule renderer must also replace, rather than follow, a
# deterministic legacy stage symlink.
# shellcheck source=/dev/null
. "$ROOT/src/MagicNet/lib/magicnet/singbox_route_rules.sh"
route_hint="$MODDIR/.config/sing-box/config.json.magicnet-block.new"
route_rules="$tmp/route-rules"
: >"$route_rules"
ln -s "$tmp/outside" "$route_hint"
magicnet_singbox_insert_route_rules \
  "$MODDIR/.config/sing-box/config.json" "$route_hint" "$route_rules" block
[[ "$(<"$tmp/outside")" == outside-canary ]]
[[ -f "$route_hint" && ! -L "$route_hint" ]]
jq -e . "$route_hint" >/dev/null
rm -f "$route_hint"

magicnet_block_apply_singbox
jq -e '
  ([.outbounds[] | select(.tag == "ad-block")] | length == 1)
  and ([.outbounds[] | select(.tag == "ad-allow")] | length == 1)
  and ([.route.rules[] | select(.outbound == "ad-allow")] | length == 1)
' "$MODDIR/.config/sing-box/config.json" >/dev/null

# A failed selector publish must be reported instead of being masked by the
# cleanup/unset commands that follow it.
selector_before=$(<"$MODDIR/.config/sing-box/config.json")
mv() { return 1; }
if magicnet_block_ensure_ad_selectors "$MODDIR/.config/sing-box/config.json"; then
  printf '%s\n' 'selector publish failure must be returned to the caller' >&2
  exit 1
fi
unset -f mv
selector_after=$(<"$MODDIR/.config/sing-box/config.json")
if [[ "$selector_after" != "$selector_before" ]]; then
  printf '%s\n' 'selector publish failure must not alter the live config' >&2
  diff -u <(printf '%s\n' "$selector_before") <(printf '%s\n' "$selector_after") >&2 || true
  exit 1
fi

magicnet_block_normalize_allow_rules() { :; }
magicnet_block_ensure_ad_selectors() { :; }
magicnet_block_singbox_rules() { return 1; }

before=$(<"$MODDIR/.config/sing-box/config.json")
if magicnet_block_apply_singbox; then
  printf '%s\n' 'block apply must fail when rule generation fails' >&2
  exit 1
fi
after=$(<"$MODDIR/.config/sing-box/config.json")
if [[ "$after" != "$before" ]]; then
  printf '%s\n' 'block apply failure must not publish a partial config' >&2
  diff -u <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  exit 1
fi

# A successful rule renderer is not enough when the source config no longer
# has the expected route.rules shape; publishing that candidate would silently
# drop the managed block rule.
cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "route": {
    "other": []
  }
}
EOF
magicnet_block_has_domains() { return 0; }
magicnet_block_singbox_rules() {
  printf '%s\n' '      {"domain": ["__magicnet_block__"], "outbound": "ad-block"},'
}
before=$(<"$MODDIR/.config/sing-box/config.json")
if magicnet_block_apply_singbox; then
  printf '%s\n' 'block apply must fail when managed rules cannot be inserted' >&2
  exit 1
fi
after=$(<"$MODDIR/.config/sing-box/config.json")
if [[ "$after" != "$before" ]]; then
  printf '%s\n' 'block insertion failure must not publish the candidate config' >&2
  diff -u <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  exit 1
fi

printf '%s\n' 'block apply safety test passed'
