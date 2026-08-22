#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-config-permissions.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export MODDIR="$WORK/module"
mkdir -p "$MODDIR/.config/sing-box" "$MODDIR/.config/magicnet" "$MODDIR/bin"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"

assert_mode_600() {
    local file="$1"
    local mode
    mode="$(stat -c '%a' "$file")"
    [ "$mode" = 600 ] || {
        printf 'expected %s to be mode 600, got %s\n' "$file" "$mode" >&2
        exit 1
    }
}

printf '%s\n' '{"dns":{"servers":[]},"outbounds":[{"type":"direct","tag":"direct"}]}' \
    >"$MODDIR/.config/sing-box/config.json"
chmod 644 "$MODDIR/.config/sing-box/config.json"

# These modules are normally loaded by magicnet.sh.  Source the subscription
# helpers first because this test deliberately exercises the modules in
# isolation, like the Android recovery paths do.
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
magicnet_warn() { :; }
. "$ROOT/src/MagicNet/lib/magicnet/dns.sh"
. "$ROOT/src/MagicNet/lib/magicnet/webui_panel.sh"

umask 022
MAGICNET_DNS_PROFILE=cloudflare-doh magicnet_dns_apply_singbox
assert_mode_600 "$MODDIR/.config/sing-box/config.json"

chmod 644 "$MODDIR/.config/sing-box/config.json"
magicnet_singbox_apply_zashboard
assert_mode_600 "$MODDIR/.config/sing-box/config.json"
jq -e '
  .experimental.clash_api.external_ui == "zashboard"
  and (.experimental.clash_api | has("external_ui_download_url") | not)
  and (.experimental.clash_api | has("external_ui_download_detour") | not)
' "$MODDIR/.config/sing-box/config.json" >/dev/null

# Subscription generation is a separate atomic writer and must keep the same
# contract even when the caller supplies a permissive umask.
. "$ROOT/src/MagicNet/lib/magicnet/chain.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
magicnet_singbox_sanitize_generated_config() { return 0; }
mkdir -p "$WORK/clean-path"
for command_name in jq chmod mv rm; do
    ln -s "$(command -v "$command_name")" "$WORK/clean-path/$command_name"
done
printf '%s\n' '[{"type":"vless","tag":"fixture-node","server":"node.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001"}]' \
    >"$WORK/outbounds.json"
jq -c . "$MODDIR/.config/sing-box/config.json" >"$WORK/config.minified.json"
mv "$WORK/config.minified.json" "$MODDIR/.config/sing-box/config.json"
chmod 644 "$MODDIR/.config/sing-box/config.json"
PATH="$WORK/clean-path" magicnet_singbox_update_config_with_nodes "$WORK/outbounds.json"
assert_mode_600 "$MODDIR/.config/sing-box/config.json"
printf '%s\n' '"outbounds": [{"type":"vless","tag":"legacy-cached-node","server":"legacy.invalid","server_port":443,"uuid":"00000000-0000-4000-8000-000000000002"}],' \
    >"$WORK/legacy-outbounds.fragment"
PATH="$WORK/clean-path" magicnet_singbox_update_config_with_nodes "$WORK/legacy-outbounds.fragment"
jq -e '.outbounds[0].tag == "legacy-cached-node"' "$MODDIR/.config/sing-box/config.json" >/dev/null
assert_mode_600 "$MODDIR/.config/sing-box/config.json"

for stale in \
    "$MODDIR/.config/sing-box/config.json.magicnet-dns.new" \
    "$MODDIR/.config/sing-box/config.json.zashboard.new" \
    "$MODDIR/.config/sing-box/config.json.new"; do
    [ ! -e "$stale" ] || {
        printf 'temporary config leaked: %s\n' "$stale" >&2
        exit 1
    }
done

printf '%s\n' 'config permission safety test passed'
