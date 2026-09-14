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
# A colliding subscription node must not replace the maintained selector.
jq -e '[.[] | select(.tag == "google-proxy")] | length == 1 and .[0].type == "selector"' "$fixture/outbounds" >/dev/null
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
# Every maintained selector must retain a usable proxy default after regeneration.
for service in google youtube github discord netflix spotify twitter whatsapp telegram; do
    jq -e --arg tag "$service-proxy" '
      .[] | select(.tag == $tag) | .outbounds | index("US-test") != null
    ' "$fixture/outbounds" >/dev/null
done
printf 'Service selectors: node choices, reserved collisions, defaults and preservation passed\n'

# Exercise the real sanitizer, not just the builder: it used to silently
# replace each maintained service default with the first subscription node.
jq -n --slurpfile out "$fixture/outbounds" '{inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:7892}],outbounds:$out[0],route:{rules:[]}}' >"$fixture/config.json"
magicnet_singbox_sanitize_generated_config "$fixture/config.json"
for service in google youtube github discord netflix spotify twitter whatsapp telegram; do
    jq -e --arg tag "$service-proxy" '.outbounds[] | select(.tag==$tag) | .default=="proxy" and (.outbounds | index("proxy")) != null' "$fixture/config.json" >/dev/null
done
# Legacy generated first-node pins migrate to proxy; explicit direct and block
# never appear as automatic fallbacks, and explicit operator choices survive.
jq '(.outbounds[] | select(.tag=="google-proxy")) |= (.outbounds=["US-test","direct","block"] | .default="US-test")' "$fixture/config.json" >"$fixture/legacy.json"
magicnet_singbox_sanitize_generated_config "$fixture/legacy.json"
jq -e '.outbounds[] | select(.tag=="google-proxy") | .default=="proxy"' "$fixture/legacy.json" >/dev/null
for choice in US-test direct block; do
    jq --arg choice "$choice" '(.outbounds[] | select(.tag=="google-proxy")).default=$choice' "$fixture/config.json" >"$fixture/pinned.json"
    magicnet_singbox_sanitize_generated_config "$fixture/pinned.json"
    jq -e --arg choice "$choice" '.outbounds[] | select(.tag=="google-proxy") | .default==$choice' "$fixture/pinned.json" >/dev/null
    # Regeneration must carry a valid explicit choice across .outbounds rebuild.
    (
        magicnet_singbox_chain_apply() { return 0; }
        # The optional host-core check is separate from this fixture's static
        # template shape; real-core routing is tested below when available.
        sing-box() { return 0; }
        MAGICNET_SUB_CONFIG_FILE="$fixture/pinned.json" magicnet_singbox_update_config_with_nodes "$fixture/outbounds"
    )
    jq -e --arg choice "$choice" '.outbounds[] | select(.tag=="google-proxy") | .default==$choice' "$fixture/pinned.json" >/dev/null
done
cp "$fixture/config.json" "$fixture/once.json"
magicnet_singbox_sanitize_generated_config "$fixture/config.json"
cmp "$fixture/once.json" "$fixture/config.json"
# A removed node choice falls back to proxy, not direct or a dangling tag.
jq '(.outbounds[] | select(.tag=="google-proxy")).default="removed-node"' "$fixture/config.json" >"$fixture/stale.json"
magicnet_singbox_sanitize_generated_config "$fixture/stale.json"
jq -e '.outbounds[] | select(.tag=="google-proxy") | .default=="proxy"' "$fixture/stale.json" >/dev/null
printf 'Service sanitizer migration, explicit selection, refresh and idempotence passed\n'
if command -v sing-box >/dev/null 2>&1; then
    python3 "$ROOT/scripts/test-service-selector-routing.py" "$fixture/config.json"
else
    printf 'Real-core service routing probe skipped: sing-box not installed on this host\n'
fi
