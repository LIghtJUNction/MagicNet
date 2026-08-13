#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

MODDIR="$WORK/module"
RULES="$WORK/ip-rules"
mkdir -p "$MODDIR/.state/hotspot" "$MODDIR/.config/sing-box"
printf '%s\n' '21000: from all iif wlan2 lookup wlan0' >"$RULES"
printf '%s\n' 'value=0' >"$MODDIR/.state/hotspot/tether-offload.previous"
HOTSPOT_CIDR=10.199.43.0/24
HOTSPOT_SECONDARY_CIDR=
HOTSPOT_INTERFACE_ORDER=primary-first
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
  [ "$1" = magicnet0 ] || [ "$1" = wlan2 ] || [ "$1" = usb0 ]
}

magicnet_warn() {
  printf 'warning: %s\n' "$1" >&2
}

dumpsys() {
  [ "${1:-}" = tethering ] || return 1
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
  if [ "${1:-}" = route ] && [ "${2:-}" = show ] &&
    [ "${3:-}" = table ] && [ "${4:-}" = 2022 ]; then
    printf '%s\n' '0.0.0.0/5 dev magicnet0'
    return 0
  fi
  if [ "${1:-}" = route ] && [ "${2:-}" = show ] &&
    [ "${3:-}" = dev ] && [ "${4:-}" = wlan2 ] &&
    [ "${5:-}" = scope ] && [ "${6:-}" = link ]; then
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

. "$ROOT/src/MagicNet/lib/magicnet/routes.sh"

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

printf '%s\n' 'hotspot routing test passed'
