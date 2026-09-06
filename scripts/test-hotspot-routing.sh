#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

MODDIR="$WORK/module"
RULES="$WORK/ip-rules"
JQ_BIN=$(command -v jq)
mkdir -p "$MODDIR/.state/hotspot" "$MODDIR/.config/sing-box" "$MODDIR/bin"
ln -s "$JQ_BIN" "$MODDIR/bin/jq"
printf '%s\n' '21000: from all iif wlan2 lookup wlan0' >"$RULES"
printf '%s\n' 'value=0' >"$MODDIR/.state/hotspot/tether-offload.previous"
HOTSPOT_CIDR=10.199.43.0/24
HOTSPOT_SECONDARY_CIDR=
HOTSPOT_INTERFACE_ORDER=primary-first
HOTSPOT_ROUTE_QUERY_FAIL=0
HOTSPOT_LINK_QUERY_FAIL=0
HOTSPOT_DUMPSYS_FAIL=0
HOTSPOT_IFACE_MISSING=0
cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "outbounds": [
    {"type": "selector", "tag": "hotspot", "outbounds": ["direct", "proxy"], "default": "direct"}
  ],
  "route": {
    "rules": [
      {"inbound": ["mixed-in", "tun-in"], "action": "sniff"},
      {"domain_suffix": ["qq.com"], "outbound": "cn-direct"},
      {
        "inbound": ["tun-in"],
        "source_ip_cidr": ["198.51.100.0/24"],
        "network": "tcp",
        "outbound": "hotspot"
      }
    ]
  }
}
EOF

magicnet_cmd_exists() {
  case "$1" in
  dumpsys | ip) return 0 ;;
  *) return 1 ;;
  esac
}

magicnet_iface_exists() {
  [ "$1" != wlan2 ] || [ "$HOTSPOT_IFACE_MISSING" -eq 0 ] || return 1
  [ "$1" = magicnet0 ] || [ "$1" = wlan2 ] || [ "$1" = usb0 ]
}

magicnet_warn() {
  printf 'warning: %s\n' "$1" >&2
}

dumpsys() {
  [ "${1:-}" = tethering ] || return 1
  [ "$HOTSPOT_DUMPSYS_FAIL" -eq 0 ] || return 2
  if [ -n "$HOTSPOT_SECONDARY_CIDR" ] && [ "$HOTSPOT_INTERFACE_ORDER" = secondary-first ]; then
    printf '%s\n' \
      'usb0 - TetheredState - lastError = 0' \
      'wlan2 - TetheredState - lastError = 0'
  else
    printf '%s\n' 'wlan2 - TetheredState - lastError = 0'
    [ -z "$HOTSPOT_SECONDARY_CIDR" ] ||
      printf '%s\n' 'usb0 - TetheredState - lastError = 0'
  fi
}

settings() {
  case "${1:-} ${2:-} ${3:-}" in
  'put global tether_offload_disabled') printf '%s\n' "${4:-}" >"$WORK/offload" ;;
  'delete global tether_offload_disabled') rm -f "$WORK/offload" ;;
  *) return 0 ;;
  esac
}

ip() {
  if [ "${1:-} ${2:-} ${3:-}" = '-o link show' ]; then
    [ "$HOTSPOT_LINK_QUERY_FAIL" -eq 0 ] || return 2
    printf '%s\n' '5: wlan2: <BROADCAST,MULTICAST,UP>'
    return 0
  fi
  if [ "${1:-}" = route ] && [ "${2:-}" = show ] &&
    [ "${3:-}" = table ] && [ "${4:-}" = 2022 ]; then
    printf '%s\n' '0.0.0.0/5 dev magicnet0'
    return 0
  fi
  if [ "${1:-}" = route ] && [ "${2:-}" = show ] &&
    [ "${3:-}" = dev ] && [ "${4:-}" = wlan2 ] &&
    [ "${5:-}" = scope ] && [ "${6:-}" = link ]; then
    [ "$HOTSPOT_ROUTE_QUERY_FAIL" -eq 0 ] || return 2
    printf '%s proto kernel scope link src 10.199.43.11\n' "$HOTSPOT_CIDR"
    return 0
  fi
  if [ "${1:-}" = route ] && [ "${2:-}" = show ] &&
    [ "${3:-}" = dev ] && [ "${4:-}" = usb0 ] &&
    [ "${5:-}" = scope ] && [ "${6:-}" = link ]; then
    [ -z "$HOTSPOT_SECONDARY_CIDR" ] ||
      printf '%s proto kernel scope link src 10.88.0.1\n' "$HOTSPOT_SECONDARY_CIDR"
    return 0
  fi
  if [ "${1:-}" = rule ] && [ "${2:-}" = show ]; then
    cat "$RULES"
    return 0
  fi
  if [ "${1:-}" = rule ] && [ "${2:-}" = add ]; then
    priority="${4:-}"
    iface="${6:-}"
    printf '%s: from all iif %s lookup 2022\n' "$priority" "$iface" >>"$RULES"
    return 0
  fi
  if [ "${1:-}" = rule ] && [ "${2:-}" = del ]; then
    priority="${4:-}"
    iface="${6:-}"
    pattern="${priority}: from all iif ${iface} lookup 2022"
    grep -F -v -x "$pattern" "$RULES" >"$WORK/ip-rules.new" || true
    mv -f "$WORK/ip-rules.new" "$RULES"
    return 0
  fi
  return 1
}

import() { :; }
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/subscribe_bootstrap.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/transparent.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/routes.sh"

# common.sh supplies the production default; restore the deterministic command
# availability fixture after all production files have been sourced.
magicnet_cmd_exists() {
  case "$1" in
  dumpsys | ip) return 0 ;;
  *) return 1 ;;
  esac
}

magicnet_singbox_apply_hotspot_policy
jq -e '
  [.route.rules[] | select(
    .inbound == ["tun-in"] and .outbound == "hotspot"
      and ((has("network") | not))
  )] == [{
    "inbound": ["tun-in"],
    "source_ip_cidr": ["10.199.43.0/24"],
    "outbound": "hotspot"
  }]
' "$MODDIR/.config/sing-box/config.json" >/dev/null
magicnet_singbox_hotspot_policy_current
jq -e '
  [.route.rules[] | select(
    .inbound == ["tun-in"]
      and .source_ip_cidr == ["198.51.100.0/24"]
      and .network == "tcp"
      and .outbound == "hotspot"
  )] | length == 1
' "$MODDIR/.config/sing-box/config.json" >/dev/null
if jq -e '
  [.route.rules[] | select(
    .outbound == "hotspot"
      and (.source_ip_cidr // [] | index("192.168.0.0/16")) != null
  )] | length > 0
' "$MODDIR/.config/sing-box/config.json" >/dev/null; then
  printf '%s\n' 'phone Wi-Fi RFC1918 space leaked into the hotspot source policy' >&2
  exit 1
fi
HOTSPOT_CIDR=192.168.52.0/24
HOTSPOT_SECONDARY_CIDR=10.88.0.0/24
if magicnet_singbox_hotspot_policy_current; then
  printf '%s\n' 'renumbered hotspot subnet was incorrectly treated as current' >&2
  exit 1
fi
magicnet_singbox_apply_hotspot_policy
jq -e '
  [.route.rules[] | select(
    .inbound == ["tun-in"] and .outbound == "hotspot"
      and ((has("network") | not))
  )][0].source_ip_cidr == ["10.88.0.0/24", "192.168.52.0/24"]
' "$MODDIR/.config/sing-box/config.json" >/dev/null
magicnet_singbox_hotspot_policy_current
HOTSPOT_INTERFACE_ORDER=secondary-first
magicnet_singbox_hotspot_policy_current
HOTSPOT_SECONDARY_CIDR=

magicnet_hotspot_reconcile
grep -Fqx '20999|wlan2' "$MODDIR/.state/hotspot/tun-rules.list"
grep -Fqx '20999: from all iif wlan2 lookup 2022' "$RULES"

magicnet_hotspot_reconcile
[ "$(grep -c '^20999:' "$RULES")" -eq 1 ]

magicnet_hotspot_route_status >"$WORK/status"
grep -Fqx 'route_table_ready=1' "$WORK/status"
grep -Fqx 'downstream_interfaces=wlan2' "$WORK/status"
grep -Fqx 'downstream_networks=192.168.52.0/24' "$WORK/status"
grep -Fqx 'route_status=ready' "$WORK/status"

magicnet_hotspot_offload_restore
[ ! -e "$MODDIR/.state/hotspot/tun-rules.list" ]
if grep -q '^20999:' "$RULES"; then
  exit 1
fi
magicnet_singbox_apply_hotspot_policy
jq -e '
  [.route.rules[] | select(
    .inbound == ["tun-in"] and .outbound == "hotspot"
      and ((has("network") | not))
  )] | length == 0
' "$MODDIR/.config/sing-box/config.json" >/dev/null
jq -e '
  [.route.rules[] | select(
    .inbound == ["tun-in"]
      and .source_ip_cidr == ["198.51.100.0/24"]
      and .network == "tcp"
      and .outbound == "hotspot"
  )] | length == 1
' "$MODDIR/.config/sing-box/config.json" >/dev/null
magicnet_singbox_hotspot_policy_current

# The hotspot route reconciler is TUN-only. In explicit eBPF mode the shared
# path owns downstream interception, so no table-2022 rule may be installed and
# no conventional wlan0 name may be guessed.
assert_ebpf_skips_tun_hotspot_routes() (
  mkdir -p "$MODDIR/.config/magicnet"
  printf '%s\n' 'MAGICNET_TRANSPARENT_MODE=ebpf' >"$MODDIR/.config/magicnet/transparent-mode.conf"
  chmod 600 "$MODDIR/.config/magicnet/transparent-mode.conf"
  command_log="$WORK/ebpf-route-commands.log"
  : >"$command_log"
  magicnet_hotspot_proxy_enabled() { return 0; }
  magicnet_hotspot_route_cleanup() { printf '%s\n' cleanup >>"$command_log"; }
  ip() {
    printf 'ip %s\n' "$*" >>"$command_log"
    return 0
  }
  magicnet_hotspot_reconcile
  if grep -Eq 'table[[:space:]]+2022|lookup[[:space:]]+2022|(^|[[:space:]])wlan0($|[[:space:]])' "$command_log"; then
    printf '%s\n' 'eBPF hotspot reconciliation installed or guessed TUN state' >&2
    cat "$command_log" >&2
    exit 1
  fi
)

assert_ebpf_skips_tun_hotspot_routes

assert_hotspot_probe_errors_preserve_config() (
  magicnet_transparent_mode() { printf '%s\n' ebpf; }
  magicnet_hotspot_proxy_enabled() { return 0; }
  config="$MODDIR/.config/sing-box/config.json"
  jq '.inbounds = [{"type":"ebpf","tag":"tun-in","mode":"hybrid",
    "shared":{"interface":["wlan2"],"include_source_cidr":["192.168.52.0/24"]}}]' \
    "$config" >"$config.new"
  mv "$config.new" "$config"
  magicnet_singbox_apply_hotspot_policy
  magicnet_singbox_hotspot_policy_current
  cp "$config" "$WORK/last-good-hotspot.json"

  assert_status() {
    expected="$1"
    shift
    if "$@" >/dev/null; then actual=0; else actual=$?; fi
    [ "$actual" -eq "$expected" ] || {
      printf '%s returned %s, expected %s\n' "$1" "$actual" "$expected" >&2
      exit 1
    }
  }

  # A route-query failure must survive every pipeline and must never publish
  # an empty hotspot policy, which would cause a full sing-box restart.
  HOTSPOT_ROUTE_QUERY_FAIL=1
  assert_status 2 magicnet_hotspot_active_networks
  assert_status 2 magicnet_hotspot_source_cidrs_json "$JQ_BIN"
  assert_status 2 magicnet_ebpf_hotspot_config_current
  assert_status 2 magicnet_singbox_hotspot_policy_current
  assert_status 1 magicnet_singbox_apply_hotspot_policy
  cmp -s "$config" "$WORK/last-good-hotspot.json"
  HOTSPOT_ROUTE_QUERY_FAIL=0
  magicnet_singbox_hotspot_policy_current
  HOTSPOT_IFACE_MISSING=1
  assert_status 2 magicnet_singbox_hotspot_policy_current
  HOTSPOT_IFACE_MISSING=0
  magicnet_singbox_hotspot_policy_current

  # Keep OEM fallback discovery, but do not turn failure of both discovery
  # methods into a successful empty topology.
  HOTSPOT_DUMPSYS_FAIL=1
  magicnet_singbox_hotspot_policy_current
  HOTSPOT_LINK_QUERY_FAIL=1
  assert_status 2 magicnet_singbox_hotspot_policy_current
  cmp -s "$config" "$WORK/last-good-hotspot.json"
  HOTSPOT_DUMPSYS_FAIL=0
  HOTSPOT_LINK_QUERY_FAIL=0
  magicnet_singbox_hotspot_policy_current

  # A successful empty route query is a real disappearance and must still
  # remove the managed source policy. Recovery is a confirmed change again.
  HOTSPOT_CIDR=
  assert_status 1 magicnet_singbox_hotspot_policy_current
  magicnet_singbox_apply_hotspot_policy
  jq -e '[.route.rules[] | select(.outbound == "hotspot" and (has("network") | not))] == []' "$config" >/dev/null
  HOTSPOT_CIDR=192.168.52.0/24
  assert_status 1 magicnet_singbox_hotspot_policy_current
  magicnet_singbox_apply_hotspot_policy
  magicnet_singbox_hotspot_policy_current
  cmp -s "$config" "$WORK/last-good-hotspot.json"
)

assert_hotspot_probe_errors_preserve_config

printf '%s\n' 'hotspot routing test passed'
