#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

export MODDIR="$tmp/module"
mkdir -p "$MODDIR/.config/sing-box"
cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "route": {
    "auto_detect_interface": true,
    "default_interface": "rmnet_data3",
    "rules": []
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "bind_interface": "rmnet_data3"
    }
  ]
}
EOF

import() { :; }
set_i18n() { :; }
. "$ROOT/src/MagicNet/lib/kamfw/__singbox__.sh"

config="$MODDIR/.config/sing-box/config.json"
before=$(<"$config")
mv() { return 1; }
if singbox_prepare_route_config "$config"; then
  printf '%s\n' 'route preparation must fail when the config publish fails' >&2
  exit 1
fi
unset -f mv
after=$(<"$config")
if [[ "$after" != "$before" ]]; then
  printf '%s\n' 'route preparation failure must not alter the live config' >&2
  diff -u <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  exit 1
fi

singbox_prepare_route_config "$config"
grep -q '"auto_detect_interface": false' "$config"
if grep -q '"default_interface"' "$config" || grep -q '"bind_interface"' "$config"; then
  printf '%s\n' 'route preparation must remove interface pinning' >&2
  exit 1
fi

printf '%s\n' 'sing-box route apply safety test passed'
