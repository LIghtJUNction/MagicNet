#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export MODDIR="$ROOT/src/MagicNet"
. "$MODDIR/lib/magicnet/singbox_subscribe/common.sh"
. "$MODDIR/lib/magicnet/singbox_subscribe/config.sh"
magicnet_singbox_subscription_filter_file() { printf '%s\n' "$fixture/filters"; }
printf '%s\n' '[{"type":"socks","tag":"US-test","server":"127.0.0.1","server_port":1080,"version":"5"},{"type":"socks","tag":"google-proxy","server":"127.0.0.1","server_port":1081,"version":"5"}]' > "$fixture/nodes"
printf '%s\n' US-test google-proxy > "$fixture/tags"
magicnet_singbox_build_outbounds_file_with_jq "$fixture/nodes" "$fixture/tags" "$fixture/outbounds"
for service in google youtube github discord netflix spotify twitter whatsapp telegram; do
    magicnet_singbox_tag_is_reserved "$service-proxy"
    jq -e --arg tag "$service-proxy" '
      [.[] | select(.tag == $tag)] as $groups
      | ($groups | length) == 1
        and $groups[0].type == "selector"
        and $groups[0].default == "proxy"
        and ($groups[0].outbounds | index("US-test")) != null
    ' "$fixture/outbounds" >/dev/null
done
jq -e '[.[].tag] | length == (unique | length)' "$fixture/outbounds" >/dev/null
printf 'Service selectors: node choices, reserved collisions and defaults passed\n'
