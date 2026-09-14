#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export MODDIR="$fixture/module"
mkdir -p "$MODDIR/bin" "$MODDIR/.config/sing-box" "$MODDIR/.config/magicnet"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"
import() { :; }
info() { :; }
config() { :; }
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/config.sh"
magicnet_singbox_subscription_filter_file() { printf '%s\n' "$fixture/filters"; }
magicnet_singbox_chain_apply() { return 0; }
active="$MODDIR/.config/sing-box/config.json"
printf '%s\n' '{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":7892}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' >"$fixture/base"
cp "$fixture/base" "$active"

# Successful commands can produce no/invalid output. None may replace live JSON.
for invalid in '' ' ' null '[]' '{}{}' '{"broken":'; do
    cp "$fixture/base" "$active"
    if magicnet_jq_install_config "$active" "$active.new" printf '%s' "$invalid"; then
        echo 'accepted invalid config output' >&2; exit 1
    fi
    cmp "$fixture/base" "$active"
    test ! -e "$active.new"
done
partial_then_fail() { printf '{}'; return 7; }
if magicnet_jq_install_config "$active" "$active.new" partial_then_fail; then
    echo 'accepted failed generator output' >&2; exit 1
fi
cmp "$fixture/base" "$active"
if magicnet_jq_install_config "$active" "$active" true; then exit 1; fi
cmp "$fixture/base" "$active"
ln -s "$active" "$active.new"
if magicnet_jq_install_config "$active" "$active.new" true; then exit 1; fi
cmp "$fixture/base" "$active"
rm "$active.new"
magicnet_jq_install_config "$active" "$active.new" cat "$fixture/base"
test "$(stat -c %a "$active")" = 600

# Sanitization must reject empty/multi-document input before mutating it.
for invalid in '' ' ' null '[]' '{}{}' '{'; do
    printf '%s' "$invalid" >"$active"
    cp "$active" "$fixture/before"
    if magicnet_singbox_sanitize_generated_config "$active"; then exit 1; fi
    cmp "$fixture/before" "$active"
    test ! -e "$active.sanitized"
done
printf '%s\n' '[{"type":"socks","tag":"US-test","server":"127.0.0.1","server_port":1080,"version":"5"}]' >"$fixture/nodes"
: >"$active"
if magicnet_singbox_update_config_with_nodes "$fixture/nodes"; then exit 1; fi
test ! -s "$active"
test ! -e "$active.new"
cp "$fixture/base" "$active"
# Fault injection: even a successful sanitizer that loses its output cannot
# pass the final installation guard. The old file survives byte-for-byte.
(
    magicnet_singbox_sanitize_generated_config() { : >"$1"; }
    if magicnet_singbox_update_config_with_nodes "$fixture/nodes"; then exit 1; fi
)
cmp "$fixture/base" "$active"
test ! -e "$active.new"

# The fake core isolates transaction mechanics. A separate real-core routing
# regression and the release gate validate actual sing-box behavior.
cat >"$MODDIR/bin/sing-box" <<'CORE'
#!/bin/sh
[ "$1" = check ] && [ "$2" = -c ] || exit 99
[ ! -f "$MODDIR/reject-core-check" ] || exit 42
jq -e '(.inbounds | length > 0) and (.outbounds | length > 0)' "$3" >/dev/null
CORE
chmod +x "$MODDIR/bin/sing-box"
magicnet_singbox_build_outbounds_file_with_jq "$fixture/nodes" /dev/null "$fixture/outbounds"
magicnet_singbox_update_config_with_nodes "$fixture/outbounds"
# Do not retain the one-use Tailscale login key in the recovery envelope.
jq '.endpoints=[{type:"tailscale",tag:"test-tail",auth_key:"fixture-only"}]' "$active" >"$active.new"
mv "$active.new" "$active"
magicnet_singbox_save_last_good
checkpoint="$MODDIR/.state/sing-box/last-good-config.json"
jq -e '.schema == 1 and .mode == "tun" and (.config.endpoints[0] | has("auth_key") | not)' "$checkpoint" >/dev/null
test "$(stat -c %a "$checkpoint")" = 600
test "$(stat -c %a "${checkpoint%/*}")" = 700
cp "$checkpoint" "$fixture/known-good"
jq '.config' "$checkpoint" >"$fixture/recovered"
# Failed validation/empty saves preserve the preceding validated checkpoint.
touch "$MODDIR/reject-core-check"
if magicnet_singbox_save_last_good; then exit 1; fi
cmp "$fixture/known-good" "$checkpoint"
rm "$MODDIR/reject-core-check"
: >"$active"
if magicnet_singbox_save_last_good; then exit 1; fi
cmp "$fixture/known-good" "$checkpoint"

# Missing node cache and subscription do not prevent local recovery at startup.
# Real config_has_nodes/canonical selector validation runs on the restored file.
magicnet_cmd_exists() { return 1; }
magicnet_singbox_standalone_config_ready() { return 1; }
magicnet_singbox_has_subscription() { return 1; }
# The public startup gate must permit recovery even without a URL or node cache.
magicnet_require_subscription_or_stop
magicnet_prepare_singbox_nodes_unlocked
cmp "$fixture/recovered" "$active"
test "$(stat -c %a "$active")" = 600
if magicnet_singbox_restore_last_good; then exit 1; fi
cmp "$fixture/recovered" "$active"

# Core rejection and mode mismatch must leave a broken active file untouched.
printf 'broken-active' >"$active"
touch "$MODDIR/reject-core-check"
if magicnet_singbox_restore_last_good; then exit 1; fi
test "$(cat "$active")" = broken-active
rm "$MODDIR/reject-core-check"
printf 'MAGICNET_TRANSPARENT_MODE=ebpf\n' >"$MODDIR/.config/magicnet/transparent-mode.conf"
if magicnet_singbox_restore_last_good; then exit 1; fi
test "$(cat "$active")" = broken-active
rm "$MODDIR/.config/magicnet/transparent-mode.conf"
magicnet_singbox_restore_last_good
cmp "$fixture/recovered" "$active"
# Empty/malformed recovery envelopes are never installed.
: >"$active"
for invalid in '' '{}' '{"schema":1}'; do
    printf '%s' "$invalid" >"$checkpoint"
    if magicnet_singbox_restore_last_good; then exit 1; fi
    test ! -s "$active"
done
cp "$fixture/known-good" "$checkpoint"
# A timeout fails closed and does not overwrite either active or checkpoint.
timeout() { return 124; }
if magicnet_singbox_restore_last_good; then exit 1; fi
test ! -s "$active"
cmp "$fixture/known-good" "$checkpoint"
unset -f timeout
magicnet_singbox_restore_last_good
cmp "$fixture/recovered" "$active"
# No checkpoint/no config: fail, never invent a direct-only configuration.
rm "$checkpoint" "$active"
if magicnet_singbox_restore_last_good; then exit 1; fi
test ! -e "$active"
# All successful and failed paths clean their owned staging files.
if find "$MODDIR" -name '*.recover.*' -o -name '.last-good.*' | grep -q .; then
    echo 'leaked recovery staging file' >&2; exit 1
fi
printf 'Empty-output guards, validated checkpoint, no-cache startup, failed recovery and cleanup passed\n'
