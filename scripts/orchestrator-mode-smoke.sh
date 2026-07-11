#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "orchestrator smoke failed: missing required command: $1" >&2
        exit 1
    fi
}

require jq

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-orchestrator.XXXXXX")
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

MODDIR="$TMPDIR/module"
export MODDIR
mkdir -p "$MODDIR/.config/sing-box" "$MODDIR/.config/magicnet" "$MODDIR/bin"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"

cat >"$TMPDIR/harness.sh" <<'HARNESS'
#!/usr/bin/env sh
set -eu
import() { :; }
info() { :; }
warn() { printf '%s\n' "$*" >&2; }
magicnet_warn() { warn "$@"; }
magicnet_singbox_dns_strategy_for_mode() { printf '%s\n' "prefer_ipv4"; }
singbox_prepare_route_config() { :; }
. "$ROOT_DIR/src/MagicNet/lib/magicnet/common.sh"
. "$ROOT_DIR/src/MagicNet/lib/magicnet/transparent.sh"
magicnet_singbox_apply_transparent_mode
HARNESS
# shellcheck disable=SC2016
perl -0pi -e 's#\$ROOT_DIR#'"$ROOT_DIR"'#g' "$TMPDIR/harness.sh"
chmod +x "$TMPDIR/harness.sh"

write_sample_config() {
    cat >"$MODDIR/.config/sing-box/config.json" <<'JSON'
{
  "dns": {
    "strategy": "prefer_ipv6",
    "servers": [
      { "type": "local", "tag": "local" }
    ]
  },
  "inbounds": [
    { "type": "mixed", "tag": "user-mixed", "listen": "127.0.0.1", "listen_port": 1080 },
    { "type": "tun", "tag": "old-tun", "interface_name": "old0" },
    { "type": "tproxy", "tag": "old-tproxy" },
    { "type": "mixed", "tag": "magicnet-old", "listen": "127.0.0.1", "listen_port": 10000 }
  ],
  "route": {
    "rules": [
      { "action": "sniff", "inbound": ["magicnet-old"] },
      { "inbound": ["magicnet-old"], "outbound": "direct" },
      { "domain_suffix": ["example.com"], "outbound": "proxy-rule" }
    ],
    "final": "direct"
  },
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
JSON
}

assert_mode() {
    local mode=$1
    local expect_tun=$2
    write_sample_config
    printf 'MAGICNET_TRANSPARENT_MODE=%s\n' "$mode" >"$MODDIR/.config/magicnet/transparent-mode.conf"
    "$TMPDIR/harness.sh"

    local config="$MODDIR/.config/sing-box/config.json"
    jq -e '.inbounds[] | select(.type == "mixed" and .tag == "mixed-in" and .listen == "127.0.0.1" and .listen_port == 7892)' "$config" >/dev/null
    jq -e '.inbounds[] | select(.type == "direct" and .tag == "magicnet-dns-in" and .listen == "127.0.0.1" and .listen_port == 1053)' "$config" >/dev/null
    jq -e '.route.rules[] | select(.action == "hijack-dns" and .protocol == "dns" and (.inbound == ["magicnet-dns-in"]))' "$config" >/dev/null
    jq -e '.inbounds[] | select(.tag == "user-mixed")' "$config" >/dev/null
    if jq -e '.inbounds[] | select(.type == "tproxy" or .tag == "magicnet-old" or .tag == "old-tun")' "$config" >/dev/null; then
        echo "orchestrator smoke failed: stale managed inbound survived for mode $mode" >&2
        jq '.inbounds' "$config" >&2
        exit 1
    fi

    if [ "$expect_tun" = "yes" ]; then
        jq -e '.inbounds[] | select(.type == "tun" and .tag == "tun-in" and .interface_name == "magicnet0" and .stack == "gvisor" and .mtu == 1400)' "$config" >/dev/null
        jq -e '.route.rules[] | select(.action == "sniff" and (.inbound == ["mixed-in", "tun-in"]))' "$config" >/dev/null
    else
        if jq -e '.inbounds[] | select(.type == "tun" or .tag == "tun-in")' "$config" >/dev/null; then
            echo "orchestrator smoke failed: mode $mode unexpectedly emitted a managed TUN inbound" >&2
            jq '.inbounds' "$config" >&2
            exit 1
        fi
        jq -e '.route.rules[] | select(.action == "sniff" and (.inbound == ["mixed-in"]))' "$config" >/dev/null
    fi

    if jq -e '.route.rules[] | select((.inbound // []) | index("magicnet-old"))' "$config" >/dev/null; then
        echo "orchestrator smoke failed: stale magicnet inbound route reference survived for mode $mode" >&2
        jq '.route.rules' "$config" >&2
        exit 1
    fi

    jq -e '.dns.strategy == "prefer_ipv4"' "$config" >/dev/null
}

assert_mode proxy no
assert_mode external-tun no
assert_mode hybrid yes
assert_mode tun yes

# Exercise the explicit jq-less awk fallback with a PATH that cannot discover host jq.
rm -f "$MODDIR/bin/jq"
FALLBACK_BIN="$TMPDIR/fallback-bin"
mkdir -p "$FALLBACK_BIN"
for command_name in awk mv rm; do
    ln -s "$(command -v "$command_name")" "$FALLBACK_BIN/$command_name"
done
cat >"$MODDIR/.config/sing-box/config.json" <<'JSON'
{
  "dns": { "strategy": "prefer_ipv6", "servers": [] },
  "inbounds": [
    {
      "type": "tun",
      "tag": "old-tun"
    }
  ],
  "route": { "rules": [], "final": "direct" },
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
JSON
printf 'MAGICNET_TRANSPARENT_MODE=tun\n' >"$MODDIR/.config/magicnet/transparent-mode.conf"
PATH="$FALLBACK_BIN" /bin/sh "$TMPDIR/harness.sh"
jq -e '.inbounds[] | select(.type == "tun" and .tag == "tun-in" and .stack == "gvisor" and .mtu == 1400)' "$MODDIR/.config/sing-box/config.json" >/dev/null

echo "orchestrator mode smoke passed"
