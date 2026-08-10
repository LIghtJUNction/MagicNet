#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

export MODDIR="$tmp/module"
mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box"
cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "domain_suffix": [
          "__magicnet_route__",
          "old.example"
        ],
        "outbound": "proxy-rule"
      }
    ]
  }
}
EOF
printf '%s\n' old.example >"$MODDIR/.config/magicnet/route-proxy-domain-suffix.list"

magicnet_warn() { :; }
magicnet_json_escape() { printf '%s' "$1"; }
. "$ROOT/src/MagicNet/lib/magicnet/routes.sh"

before=$(<"$MODDIR/.config/sing-box/config.json")
magicnet_route_singbox_rules() { return 1; }
if magicnet_route_apply_singbox; then
  printf '%s\n' 'route apply must fail when rule generation fails' >&2
  exit 1
fi
after=$(<"$MODDIR/.config/sing-box/config.json")
if [[ "$after" != "$before" ]]; then
  printf '%s\n' 'route apply failure must not publish a config without the old rules' >&2
  diff -u <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  exit 1
fi

unset -f magicnet_route_singbox_rules
. "$ROOT/src/MagicNet/lib/magicnet/routes.sh"
if ! magicnet_route_apply_singbox; then
  printf '%s\n' 'route apply must still publish a valid generated rule set' >&2
  exit 1
fi
grep -q '"__magicnet_route__"' "$MODDIR/.config/sing-box/config.json"

printf '%s\n' 'route apply safety test passed'
