#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
HOTSPOT_RETURN_WORK="$WORK/internal-return"
HOTSPOT_DISABLED_WORK="$WORK/disabled-status"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

MODDIR="$WORK/module"
RULES="$WORK/ip-rules"
JQ_BIN=$(command -v jq)
mkdir -p "$MODDIR/.state/hotspot" "$MODDIR/.config/sing-box" "$MODDIR/bin"
ln -s "$JQ_BIN" "$MODDIR/bin/jq"
ln -s "$ROOT/src/MagicNet/lib" "$MODDIR/lib"
printf '%s\n' '0: from all lookup local' \
  '10000: from all uidrange 0-0 lookup wlan0' \
  '21000: from all iif wlan2 lookup wlan0' >"$RULES"
printf '%s\n' 'value=0' >"$MODDIR/.state/hotspot/tether-offload.previous"
HOTSPOT_CIDR=10.199.43.0/24
HOTSPOT_SECONDARY_CIDR=
HOTSPOT_INTERFACE_ORDER=primary-first
HOTSPOT_ROUTE_QUERY_FAIL=0
HOTSPOT_LINK_QUERY_FAIL=0
HOTSPOT_DUMPSYS_FAIL=0
HOTSPOT_IFACE_MISSING=0
TUN_ADDRESS=172.20.0.1/30
TUN_EXTRA_ADDRESS=
TUN_MAIN_ROUTE='172.20.0.0/30 dev magicnet0 proto kernel scope link src 172.20.0.1'
TUN_ADDRESS_QUERY_FAIL=0
TUN_MAIN_QUERY_FAIL=0
TUN_LOOKUP_FAIL=0
TUN_FORCE_RETURN_UPSTREAM=0
TUN_LOOKUP_VIA=0
: >"$WORK/ip-writes"
: >"$WORK/route-lookups"
cat >"$MODDIR/.config/sing-box/config.json" <<'EOF'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "selector", "tag": "proxy", "outbounds": ["direct"], "default": "direct"},
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
  'get global tether_offload_disabled') if [ -f "$WORK/offload" ]; then cat "$WORK/offload"; else printf 'null\n'; fi ;;
  'put global tether_offload_disabled') printf '%s\n' "${4:-}" >"$WORK/offload" ;;
  'delete global tether_offload_disabled') rm -f "$WORK/offload" ;;
  *) return 0 ;;
  esac
}

ip() {
  [ "${1:-}" != -4 ] || shift
  if [ "$*" = '-o addr show dev magicnet0' ]; then
    [ "$TUN_ADDRESS_QUERY_FAIL" -eq 0 ] || return 2
    [ -z "$TUN_ADDRESS" ] || printf '7: magicnet0 inet %s scope global magicnet0\n' "$TUN_ADDRESS"
    [ -z "$TUN_EXTRA_ADDRESS" ] || printf '7: magicnet0 inet %s scope global secondary magicnet0\n' "$TUN_EXTRA_ADDRESS"
    return 0
  fi
  if [ "$*" = 'route show table main dev magicnet0 scope link' ]; then
    [ "$TUN_MAIN_QUERY_FAIL" -eq 0 ] || return 2
    [ -z "$TUN_MAIN_ROUTE" ] || printf '%s\n' "$TUN_MAIN_ROUTE"
    return 0
  fi
  if [ "${1:-} ${2:-}" = 'route get' ]; then
    printf '%s\n' "$*" >>"$WORK/route-lookups"
    [ "$TUN_LOOKUP_FAIL" -eq 0 ] || return 2
    [ "${4:-} ${6:-} ${7:-}" = 'from uid 0' ] && [ "$#" -eq 7 ] || return 2
    if [ "$TUN_FORCE_RETURN_UPSTREAM" -eq 0 ] && awk -v peer="$3" '
      /uidrange 0-0/ { p=$1+0; if (!root_seen || p<root) root=p; root_seen=1 }
      $4 == "to" && ($5 == peer || $5 == peer "/32") && $6 == "lookup" && $7 == "main" {
        p=$1+0; if (!ret_seen || p<ret) ret=p; ret_seen=1
      }
      END { exit !(ret_seen && (!root_seen || ret<root)) }
    ' "$RULES"; then
      if [ "$TUN_LOOKUP_VIA" -eq 1 ]; then
        printf '%s from %s via 192.0.2.1 dev magicnet0 uid 0\n' "$3" "$5"
      else
        printf '%s from %s dev magicnet0 uid 0\n' "$3" "$5"
      fi
    else
      printf '%s from %s via 192.168.1.1 dev wlan0 table wlan0 uid 0\n' "$3" "$5"
    fi
    return 0
  fi
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
    printf '%s\n' "$*" >>"$WORK/ip-writes"
    [ -f "$(magicnet_hotspot_route_pending_file)" ] || return 2
    priority="${4:-}"
    iface="${6:-}"
    if [ "${5:-}" = to ]; then
      printf '%s: from all to %s lookup main\n' "$priority" "${iface%/32}" >>"$RULES"
    else
      printf '%s: from all iif %s lookup 2022\n' "$priority" "$iface" >>"$RULES"
    fi
    return 0
  fi
  if [ "${1:-}" = rule ] && [ "${2:-}" = del ]; then
    printf '%s\n' "$*" >>"$WORK/ip-writes"
    priority="${4:-}"
    iface="${6:-}"
    if [ "${5:-}" = to ]; then
      pattern="${priority}: from all to ${iface%/32} lookup main"
    else
      pattern="${priority}: from all iif ${iface} lookup 2022"
    fi
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
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/core.sh"
: >"$WORK/forward-rules"
magicnet_iptables_cmd() {
  action=$1
  shift
  case "$action" in
    -C) grep -Fqx -- "$*" "$WORK/forward-rules" ;;
    -I) printf '%s\n' "$*" >>"$WORK/forward-rules" ;;
    -D) awk -v rule="$*" '$0 != rule' "$WORK/forward-rules" >"$WORK/forward-rules.new"; mv "$WORK/forward-rules.new" "$WORK/forward-rules" ;;
    *) return 2 ;;
  esac
}
magicnet_iptables_ensure() { magicnet_iptables_cmd -C "$@" || magicnet_iptables_cmd -I "$@"; }

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

# Route preparation adds this selector field; the hotspot producer must emit
# it too or every watchdog poll incorrectly schedules config apply.
jq -e '[.outbounds[] | select(.tag == "hotspot")][0].interrupt_exist_connections == true' "$MODDIR/.config/sing-box/config.json" >/dev/null
(
  cp "$MODDIR/.config/sing-box/config.json" "$WORK/pretty-hotspot.json"
  jq -S -c . "$WORK/pretty-hotspot.json" >"$MODDIR/.config/sing-box/config.json"
  magicnet_singbox_hotspot_policy_current
  cp "$WORK/pretty-hotspot.json" "$MODDIR/.config/sing-box/config.json"
)
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
grep -Fqx 'return4|9999|172.20.0.2/32' "$MODDIR/.state/hotspot/tun-rules.list"
grep -Fqx '20999: from all iif wlan2 lookup 2022' "$RULES"

magicnet_hotspot_reconcile
[ "$(grep -c '^20999:' "$RULES")" -eq 1 ]

magicnet_hotspot_route_status >"$WORK/status"
grep -Fqx 'route_table_ready=1' "$WORK/status"
grep -Fqx 'downstream_interfaces=wlan2' "$WORK/status"
grep -Fqx 'downstream_networks=192.168.52.0/24' "$WORK/status"
grep -Fqx 'route_status=ready' "$WORK/status"
# A connected main-table route and installed ingress rules do not prove that
# local UID 0 replies use it. This models an earlier Android upstream policy.
TUN_FORCE_RETURN_UPSTREAM=1
magicnet_hotspot_route_status >"$WORK/status"
if grep -Fqx 'route_status=ready' "$WORK/status"; then
  printf '%s\n' 'hotspot status reported ready while the TUN internal reply selected wlan0' >&2
  exit 1
fi
TUN_FORCE_RETURN_UPSTREAM=0
[ "$(wc -l <"$WORK/forward-rules" | tr -d ' ')" -eq 2 ]
grep -Fq -- '-i wlan2 -o magicnet0' "$WORK/forward-rules"
grep -Fq -- '-i magicnet0 -o wlan2 -m conntrack --ctstate ESTABLISHED,RELATED' "$WORK/forward-rules"
HOTSPOT_SECONDARY_CIDR=10.88.0.0/24
magicnet_hotspot_route_status >"$WORK/status"
grep -Fqx 'route_status=degraded' "$WORK/status"
HOTSPOT_SECONDARY_CIDR=
HOTSPOT_ROUTE_QUERY_FAIL=1
magicnet_hotspot_route_status >"$WORK/status"
grep -Fqx 'route_status=degraded' "$WORK/status"
HOTSPOT_ROUTE_QUERY_FAIL=0

printf '1\n' >"$WORK/offload"
magicnet_hotspot_offload_restore
[ ! -s "$WORK/forward-rules" ]
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

assert_hotspot_ipv6_exempt_is_installed_and_removed() (
  ipv6_rules="$WORK/ipv6-mangle-rules"
  : >"$ipv6_rules"
  mkdir -p "$MODDIR/.config/magicnet"
  rm -f "$MODDIR/.config/magicnet/transparent-mode.conf"
  printf '%s\n' 'value=0' >"$MODDIR/.state/hotspot/tether-offload.previous"
  magicnet_cmd_exists() {
    case "$1" in
    dumpsys | ip | ip6tables) return 0 ;;
    *) return 1 ;;
    esac
  }
  magicnet_xtables_table_probe() {
    [ "$1" = ip6tables ] && [ "$2" = mangle ]
  }
  magicnet_ip6tables_cmd() {
    table=
    if [ "$1" = -t ]; then
      table=$2
      shift 2
    fi
    [ "$table" = mangle ] || return 2
    action=$1
    shift
    case "$action" in
    -C) grep -Fqx -- "$*" "$ipv6_rules" ;;
    -I)
      { printf '%s\n' "$*"; cat "$ipv6_rules"; } >"$ipv6_rules.new"
      mv "$ipv6_rules.new" "$ipv6_rules"
      ;;
    -D)
      if [ "${HOTSPOT_IPV6_LEGACY_DELETE_FAIL:-0}" -ne 0 ] &&
        [ "$*" = 'PREROUTING -i wlan2 -p tcp -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT' ]; then
        return 2
      fi
      awk -v rule="$*" '$0 != rule' "$ipv6_rules" >"$ipv6_rules.new"
      mv "$ipv6_rules.new" "$ipv6_rules"
      ;;
    -S)
      [ "${HOTSPOT_IPV6_LIST_FAIL:-0}" -eq 0 ] || return 2
      awk '{ print "-A " $0 }' "$ipv6_rules"
      ;;
    *) return 2 ;;
    esac
  }
  magicnet_ip6tables_ensure() {
    if [ "$1" = -t ]; then
      table=$2
      shift 2
      magicnet_ip6tables_cmd -t "$table" -C "$@" || magicnet_ip6tables_cmd -t "$table" -I "$@"
      return $?
    fi
    magicnet_ip6tables_cmd -C "$@" || magicnet_ip6tables_cmd -I "$@"
  }

  magicnet_hotspot_reconcile
  grep -Fqx 'PREROUTING -i wlan2 -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT' "$ipv6_rules"
  magicnet_hotspot_forward_access status wlan2

  # Older releases installed a TCP-only exemption. Its tuple must remain
  # removable after an upgrade, even when both rule formats are present.
  legacy_rule='PREROUTING -i wlan2 -p tcp -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT'
  unrelated_rule='PREROUTING -i wlan2 -p tcp -s 2001:db8::/64 -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT'
  printf '%s\n' "$legacy_rule" "$unrelated_rule" >>"$ipv6_rules"
  HOTSPOT_IPV6_LEGACY_DELETE_FAIL=1
  if magicnet_hotspot_route_cleanup; then
    printf '%s\n' 'failed legacy IPv6 rule removal was reported as a successful stop' >&2
    exit 1
  fi
  [ -f "$(magicnet_hotspot_route_pending_file)" ]
  grep -Fqx "$legacy_rule" "$ipv6_rules"
  HOTSPOT_IPV6_LEGACY_DELETE_FAIL=0
  magicnet_hotspot_route_cleanup
  if grep -Fqx "$legacy_rule" "$ipv6_rules"; then
    printf '%s\n' 'stop left the previous release TCP-only IPv6 exemption installed' >&2
    exit 1
  fi
  [ "$(cat "$ipv6_rules")" = "$unrelated_rule" ]
  [ ! -e "$(magicnet_hotspot_route_state_file)" ]
  magicnet_hotspot_reconcile

  # The core can re-prepend its hooks when the upstream network changes.
  # Membership alone must not let reconcile keep an exemption below them.
  { printf '%s\n' 'PREROUTING -j sing-box-prerouting-prematch'; cat "$ipv6_rules"; } >"$ipv6_rules.new"
  mv "$ipv6_rules.new" "$ipv6_rules"
  if magicnet_hotspot_forward_access status wlan2; then
    printf '%s\n' 'IPv6 exemption below a core hook was reported ready' >&2
    exit 1
  fi
  magicnet_hotspot_reconcile
  [ "$(head -n 1 "$ipv6_rules")" = 'PREROUTING -i wlan2 -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT' ]
  grep -Fqx 'PREROUTING -j sing-box-prerouting-prematch' "$ipv6_rules"

  # Several downstream exemptions may precede one another; they must not
  # trigger an endless reinstall on every watchdog poll.
  HOTSPOT_SECONDARY_CIDR=10.88.0.0/24
  magicnet_hotspot_reconcile
  magicnet_hotspot_forward_access status wlan2
  magicnet_hotspot_forward_access status usb0
  cp "$ipv6_rules" "$WORK/ipv6-before-noop"
  cp "$RULES" "$WORK/routes-before-noop"
  magicnet_hotspot_reconcile
  cmp -s "$ipv6_rules" "$WORK/ipv6-before-noop"
  cmp -s "$RULES" "$WORK/routes-before-noop"
  HOTSPOT_IPV6_LIST_FAIL=1
  if magicnet_hotspot_reconcile; then actual=0; else actual=$?; fi
  [ "$actual" -eq 2 ]
  cmp -s "$ipv6_rules" "$WORK/ipv6-before-noop"
  cmp -s "$RULES" "$WORK/routes-before-noop"
  HOTSPOT_IPV6_LIST_FAIL=0
  HOTSPOT_SECONDARY_CIDR=
  magicnet_hotspot_reconcile

  if magicnet_hotspot_ipv6_exempt ensure 'wlan2;id'; then
    printf '%s\n' 'IPv6 exemption accepted a metacharacter interface name' >&2
    exit 1
  fi
  if magicnet_hotspot_ipv6_exempt ensure eth0; then
    printf '%s\n' 'IPv6 exemption accepted a non-hotspot interface' >&2
    exit 1
  fi

  printf '1\n' >"$WORK/offload"
  magicnet_hotspot_offload_restore
  printf '%s\n' 'PREROUTING -j sing-box-prerouting-prematch' "$unrelated_rule" >"$WORK/expected-ipv6-after-stop"
  cmp -s "$ipv6_rules" "$WORK/expected-ipv6-after-stop"
  [ ! -s "$WORK/forward-rules" ]
  [ ! -e "$MODDIR/.state/hotspot/tun-rules.list" ]
)

assert_hotspot_ipv6_exempt_is_installed_and_removed

assert_hotspot_ipv6_exempt_is_reprepended_above_tproxy() (
  ipv6_rules="$WORK/ipv6-mangle-reprepend"
  : >"$ipv6_rules"
  mkdir -p "$MODDIR/.config/magicnet"
  rm -f "$MODDIR/.config/magicnet/transparent-mode.conf"
  magicnet_cmd_exists() {
    case "$1" in
    ip6tables) return 0 ;;
    *) return 1 ;;
    esac
  }
  magicnet_xtables_table_probe() {
    [ "$1" = ip6tables ] && [ "$2" = mangle ]
  }
  magicnet_ip6tables_cmd() {
    table=
    if [ "$1" = -t ]; then
      table=$2
      shift 2
    fi
    [ "$table" = mangle ] || return 2
    action=$1
    shift
    case "$action" in
    -C) grep -Fqx -- "$*" "$ipv6_rules" ;;
    -I)
      { printf '%s\n' "$*"; cat "$ipv6_rules"; } >"$ipv6_rules.new"
      mv "$ipv6_rules.new" "$ipv6_rules"
      ;;
    -D)
      awk -v rule="$*" '$0 != rule' "$ipv6_rules" >"$ipv6_rules.new"
      mv "$ipv6_rules.new" "$ipv6_rules"
      ;;
    -S) awk '{ print "-A " $0 }' "$ipv6_rules" ;;
    *) return 2 ;;
    esac
  }

  printf '%s\n' \
    'PREROUTING -p tcp -j TPROXY' \
    'PREROUTING -i wlan2 -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT' \
    >"$ipv6_rules"
  magicnet_hotspot_ipv6_exempt ensure wlan2
  [ "$(sed -n '1p' "$ipv6_rules")" = \
    'PREROUTING -i wlan2 -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT' ]
  grep -Fqx 'PREROUTING -p tcp -j TPROXY' "$ipv6_rules"
  [ "$(grep -cF 'magicnet-hotspot-ipv6-exempt' "$ipv6_rules")" = 1 ]
)

assert_hotspot_ipv6_exempt_is_reprepended_above_tproxy

assert_hotspot_ipv6_skipped_when_ip6tables_absent() (
  magicnet_cmd_exists() {
    case "$1" in
    dumpsys | ip) return 0 ;;
    *) return 1 ;;
    esac
  }
  magicnet_ip6tables_cmd() {
    printf '%s\n' 'ip6tables should not be invoked when the binary is absent' >&2
    return 2
  }
  magicnet_hotspot_forward_access ensure wlan2
  magicnet_hotspot_forward_access status wlan2
  magicnet_hotspot_forward_access cleanup wlan2
)

assert_hotspot_ipv6_skipped_when_ip6tables_absent

assert_hotspot_ipv6_skipped_when_mangle_unsupported() (
  magicnet_cmd_exists() {
    case "$1" in
    dumpsys | ip | ip6tables) return 0 ;;
    *) return 1 ;;
    esac
  }
  magicnet_xtables_table_probe() {
    return 2
  }
  magicnet_ip6tables_cmd() {
    printf '%s\n' 'ip6tables should not be invoked when mangle is unsupported' >&2
    return 2
  }
  magicnet_hotspot_ipv6_exempt ensure wlan2
  magicnet_hotspot_ipv6_exempt status wlan2
  magicnet_hotspot_forward_access cleanup wlan2
)

assert_hotspot_ipv6_skipped_when_mangle_unsupported

assert_hotspot_ipv6_probe_failure_is_not_skipped() (
  magicnet_cmd_exists() { return 0; }
  magicnet_xtables_table_probe() { return 1; }
  for mode in ensure status cleanup; do
    if magicnet_hotspot_ipv6_exempt "$mode" wlan2; then
      printf 'IPv6 %s ignored a failed capability query\n' "$mode" >&2
      exit 1
    fi
  done
)

assert_hotspot_ipv6_probe_failure_is_not_skipped

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

(
  dumpsys() { printf '%s\n' 'ap0 - TetheredState - lastError = 0'; }
  magicnet_iface_exists() { [ "$1" = ap0 ]; }
  ip() {
    case "$*" in
      'route show dev ap0 scope link') return 0 ;;
      'route show table all dev ap0 scope link') printf '%s\n' '192.168.44.0/24 dev ap0 table 1043 proto kernel scope link src 192.168.44.1' ;;
      *) return 2 ;;
    esac
  }
  [ "$(magicnet_hotspot_active_networks_uncached)" = 'ap0|192.168.44.0/24' ]
)
(
  magicnet_transparent_mode() { printf '%s\n' ebpf; }
  magicnet_hotspot_proxy_enabled() { return 0; }
  magicnet_hotspot_tun_route_table_ready() { echo 'TUN probe is invalid for eBPF' >&2; exit 99; }
  [ "$(magicnet_hotspot_route_status)" = 'route_status=shared-tc-unverified' ]
)
(
  ip() {
    if [ "${1:-}" = route ] && [ "${2:-}" = show ] && [ "${3:-}" = table ]; then
      printf '%s\n' '10.0.0.0/8 dev magicnet0-extra proto static'
      return 0
    fi
    return 2
  }
  if magicnet_hotspot_tun_route_table_ready; then
    printf '%s\n' 'substring magicnet0-extra was treated as magicnet0' >&2
    exit 1
  fi
)
(
  ip() {
    if [ "${1:-}" = route ] && [ "${2:-}" = show ] && [ "${3:-}" = table ]; then
      printf '%s\n' '10.0.0.0/8 dev magicnet0 proto static'
      return 0
    fi
    return 2
  }
  magicnet_hotspot_tun_route_table_ready
)

# Standalone configs are valid without the template proxy/direct names. Use
# the real renderer and reject every dangling member, including stale hotspot.
(
  magicnet_hotspot_source_cidrs_json() { printf '%s\n' '[]'; }
  for tag in direct custom; do
    jq -n --arg tag "$tag" '{outbounds:[{type:"direct",tag:$tag}],route:{final:$tag,rules:[]}}' >"$WORK/standalone.json"
    magicnet_singbox_render_hotspot_policy "$WORK/standalone.json" "$WORK/standalone-rendered.json"
    jq -e --arg tag "$tag" '
      [.outbounds[].tag] as $tags
      | (.outbounds[] | select(.tag == "hotspot")) as $hotspot
      | $hotspot.outbounds == [$tag] and $hotspot.default == $tag
        and ($hotspot.outbounds | all(. as $member | $tags | index($member) != null))
    ' "$WORK/standalone-rendered.json" >/dev/null
    magicnet_singbox_render_hotspot_policy "$WORK/standalone-rendered.json" "$WORK/standalone-twice.json"
    cmp -s "$WORK/standalone-rendered.json" "$WORK/standalone-twice.json"
  done
  printf '%s\n' '{"outbounds":[{"type":"direct","tag":"first"},{"type":"direct","tag":"final"}],"route":{"final":"final"}}' >"$WORK/standalone.json"
  magicnet_singbox_render_hotspot_policy "$WORK/standalone.json" "$WORK/standalone-rendered.json"
  jq -e '.outbounds[] | select(.tag == "hotspot") | .outbounds == ["final"] and .default == "final"' "$WORK/standalone-rendered.json" >/dev/null
  printf '%s\n' '{"outbounds":[],"route":{}}' >"$WORK/standalone.json"
  if magicnet_singbox_render_hotspot_policy "$WORK/standalone.json" "$WORK/standalone-rendered.json"; then
    printf '%s\n' 'empty standalone config unexpectedly gained a usable hotspot selector' >&2
    exit 1
  fi
  [ ! -e "$WORK/standalone-rendered.json" ]
)

# Run the real startup materializer after stop has restored offload and
# removed its ownership evidence. The persisted selector is still intent.
assert_startup_restores_persisted_hotspot() (
  source_config="$MODDIR/.config/sing-box/config.json"
  WORK="$WORK/startup"
  MODDIR="$WORK/module"
  RULES="$WORK/ip-rules"
  mkdir -p "$MODDIR/.config/magicnet" "$MODDIR/.config/sing-box" "$MODDIR/.state/hotspot" "$MODDIR/bin"
  ln -s "$JQ_BIN" "$MODDIR/bin/jq"
  cp "$source_config" "$MODDIR/.config/sing-box/config.json"
  printf '%s\n' '21000: from all iif wlan2 lookup wlan0' >"$RULES"
  printf '%s\n' '{"hotspot":"proxy","proxy":"private-node"}' >"$MODDIR/.config/magicnet/selector-selections.json"
  cp "$MODDIR/.config/magicnet/selector-selections.json" "$WORK/saved-intent"
  printf '0\n' >"$WORK/offload"
  : >"$WORK/forward-rules"
  HOTSPOT_CIDR=192.168.52.0/24
  HOTSPOT_SECONDARY_CIDR=
  magicnet_module_disabled() { return 1; }
  magicnet_cmd_exists() { case "$1" in sing-box | ip | dumpsys) return 0 ;; *) return 1 ;; esac; }
  is_singbox_running() { return 1; }
  magicnet_prepare_singbox_nodes_unlocked() { :; }
  magicnet_singbox_chain_apply() { :; }
  magicnet_singbox_apply_transparent_mode() { :; }
  magicnet_dns_apply_unlocked() { :; }
  magicnet_tailscale_apply_unlocked() { :; }
  magicnet_app_policy_apply_unlocked() { :; }
  magicnet_warp_apply_unlocked() { :; }
  magicnet_singbox_apply_zashboard() { :; }
  magicnet_tailscale_inject_auth_key() { :; }
  magicnet_tailscale_scrub_auth_key() { :; }
  magicnet_validate_singbox_transparent_config() { :; }
  magicnet_singbox_running_has_nodes() { return 0; }
  singbox_start() {
    [ "$(cat "$WORK/offload")" = 1 ] &&
      [ -f "$(magicnet_hotspot_offload_state_file)" ] &&
      jq -e '[.route.rules[] | select(.outbound == "hotspot" and (has("network") | not))][0].source_ip_cidr == ["192.168.52.0/24"]' "$MODDIR/.config/sing-box/config.json" >/dev/null
  }

  magicnet_start_singbox_unlocked
  cmp -s "$MODDIR/.config/magicnet/selector-selections.json" "$WORK/saved-intent"
  magicnet_hotspot_offload_restore
  [ "$(cat "$WORK/offload")" = 0 ]
  [ ! -e "$(magicnet_hotspot_offload_state_file)" ]
  magicnet_start_singbox_unlocked
  cmp -s "$MODDIR/.config/magicnet/selector-selections.json" "$WORK/saved-intent"

  # Primary intent wins over the migration input; Direct must restore only
  # our own offload change instead of silently re-enabling Proxy.
  mkdir -p "$MODDIR/.state/sing-box"
  printf '%s\n' '{"hotspot":"proxy"}' >"$MODDIR/.state/sing-box/selector-selections.json"
  printf '%s\n' '{"hotspot":"direct"}' >"$MODDIR/.config/magicnet/selector-selections.json"
  magicnet_hotspot_offload_prepare
  [ "$(cat "$WORK/offload")" = 0 ]
  [ ! -e "$(magicnet_hotspot_offload_state_file)" ]
  rm "$MODDIR/.config/magicnet/selector-selections.json"
  magicnet_hotspot_offload_prepare
  [ "$(cat "$WORK/offload")" = 1 ]

  # Invalid intent is unknown, never permission to change the Android setting
  # or launch a core with a different hotspot policy.
  for invalid in '{broken' '{"hotspot":"other"}' '{"hotspot":null}' '{"hotspot":"proxy","proxy":3}' '[]'; do
    printf '%s\n' "$invalid" >"$MODDIR/.config/magicnet/selector-selections.json"
    if magicnet_hotspot_offload_prepare; then actual=0; else actual=$?; fi
    [ "$actual" -eq 2 ]
    [ "$(cat "$WORK/offload")" = 1 ]
    [ -f "$(magicnet_hotspot_offload_state_file)" ]
  done
  # A bad intent must also stop the full ready-start path without restoring
  # settings or trying to launch/tear down a core from incomplete evidence.
  magicnet_rollback_failed_start_unlocked() { printf '%s\n' 'unknown intent authorized cleanup' >&2; exit 99; }
  singbox_start() { printf '%s\n' 'unknown intent authorized launch' >&2; exit 99; }
  if magicnet_start_singbox_ready_unlocked; then actual=0; else actual=$?; fi
  [ "$actual" -eq 2 ]
  [ "$(cat "$WORK/offload")" = 1 ]

  # The default Direct choice is authoritative when the primary store exists
  # without a hotspot entry; an old legacy Proxy choice must not override it.
  printf '%s\n' '{"proxy":"private-node"}' >"$MODDIR/.config/magicnet/selector-selections.json"
  magicnet_hotspot_offload_prepare
  [ "$(cat "$WORK/offload")" = 0 ]
  [ ! -e "$(magicnet_hotspot_offload_state_file)" ]
  rm "$MODDIR/.config/magicnet/selector-selections.json"
  ln -s "$WORK/saved-intent" "$MODDIR/.config/magicnet/selector-selections.json"
  if magicnet_hotspot_offload_prepare; then actual=0; else actual=$?; fi
  [ "$actual" -eq 2 ]
  [ "$(cat "$WORK/offload")" = 0 ]
  [ ! -e "$(magicnet_hotspot_offload_state_file)" ]
)

assert_startup_restores_persisted_hotspot

assert_hotspot_internal_return_routing() (
  WORK="$HOTSPOT_RETURN_WORK"
  MODDIR="$WORK/module"
  RULES="$WORK/ip-rules"
  mkdir -p "$MODDIR/.state/hotspot"
  printf '%s\n' 'value=0' >"$MODDIR/.state/hotspot/tether-offload.previous"
  printf '%s\n' '0: from all lookup local' \
    '10000: from all uidrange 0-0 lookup wlan0' \
    '21000: from all iif wlan2 lookup wlan0' >"$RULES"
  : >"$WORK/forward-rules"
  : >"$WORK/ip-writes"
  : >"$WORK/route-lookups"
  magicnet_transparent_mode() { printf 'tun\n'; }
  expect_return_status() {
    _expected="$1"
    shift
    if "$@" >/dev/null; then _actual=0; else _actual=$?; fi
    [ "$_actual" -eq "$_expected" ] || {
      printf '%s returned %s, expected %s\n' "$1" "$_actual" "$_expected" >&2
      exit 1
    }
  }

  [ "$(magicnet_hotspot_return_path)" = '172.20.0.1|172.20.0.2|172.20.0.2/32' ]
  expect_return_status 1 magicnet_hotspot_return_path_ready 172.20.0.1 172.20.0.2
  [ "$(magicnet_hotspot_choose_return_rule_priority 9999)" = 9998 ]
  magicnet_hotspot_reconcile
  magicnet_hotspot_return_path_ready 172.20.0.1 172.20.0.2
  grep -Fqx 'return4|9999|172.20.0.2/32' "$(magicnet_hotspot_route_state_file)"
  grep -Fqx 'route get 172.20.0.2 from 172.20.0.1 uid 0' "$WORK/route-lookups"
  cp "$WORK/ip-writes" "$WORK/writes-before-observation"
  magicnet_hotspot_routes_current 'wlan2|192.168.52.0/24'
  magicnet_hotspot_route_status >"$WORK/status"
  grep -Fqx 'return_route_ready=1' "$WORK/status"
  grep -Fqx 'policy_rule_count=1' "$WORK/status"
  grep -Fqx 'route_status=ready' "$WORK/status"
  magicnet_hotspot_reconcile
  cmp -s "$WORK/ip-writes" "$WORK/writes-before-observation"

  # Read errors cannot authorize cleanup or an attempted reinstallation.
  for failure in address main lookup; do
    case "$failure" in
      address) TUN_ADDRESS_QUERY_FAIL=1 ;;
      main) TUN_MAIN_QUERY_FAIL=1 ;;
      lookup) TUN_LOOKUP_FAIL=1 ;;
    esac
    expect_return_status 2 magicnet_hotspot_reconcile
    magicnet_hotspot_route_status >"$WORK/status"
    grep -Fqx 'route_status=unknown' "$WORK/status"
    cmp -s "$WORK/ip-writes" "$WORK/writes-before-observation"
    TUN_ADDRESS_QUERY_FAIL=0 TUN_MAIN_QUERY_FAIL=0 TUN_LOOKUP_FAIL=0
  done
  TUN_EXTRA_ADDRESS=172.21.0.1/30
  expect_return_status 2 magicnet_hotspot_reconcile
  cmp -s "$WORK/ip-writes" "$WORK/writes-before-observation"
  TUN_EXTRA_ADDRESS=

  # Existing ownership is insufficient after Android inserts an earlier rule.
  printf '%s\n' '5000: from all uidrange 0-0 lookup wlan0' >>"$RULES"
  expect_return_status 1 magicnet_hotspot_routes_current 'wlan2|192.168.52.0/24'
  magicnet_hotspot_route_status >"$WORK/status"
  grep -Fqx 'route_status=degraded' "$WORK/status"
  magicnet_hotspot_reconcile
  grep -Fqx 'return4|4999|172.20.0.2/32' "$(magicnet_hotspot_route_state_file)"
  grep -Fqx '5000: from all uidrange 0-0 lookup wlan0' "$RULES"
  TUN_LOOKUP_VIA=1
  expect_return_status 1 magicnet_hotspot_return_path_ready 172.20.0.1 172.20.0.2
  magicnet_hotspot_route_status >"$WORK/status"
  grep -Fqx 'route_status=degraded' "$WORK/status"
  TUN_LOOKUP_VIA=0

  # Renumbering replaces only the previously recorded /32. Even a wide TUN
  # address must never install a broad destination-network or UID exemption.
  TUN_ADDRESS=172.21.0.1/8
  TUN_MAIN_ROUTE='172.0.0.0/8 proto kernel src 172.21.0.1'
  magicnet_hotspot_reconcile
  grep -Fqx 'return4|4999|172.21.0.2/32' "$(magicnet_hotspot_route_state_file)"
  if grep -Fq 'to 172.20.0.2' "$RULES"; then exit 1; fi
  if grep -Eq 'to [^ ]+/(8|30) |uidrange.*lookup main' "$RULES"; then exit 1; fi
  for bad_route in '' 'default dev magicnet0 scope link' \
    '172.0.0.0/8 dev magicnet0 via 192.0.2.1 scope link src 172.21.0.1' \
    '172.0.0.0/8 dev wlan0 scope link src 172.21.0.1' \
    '172.0.0.0/8 dev magicnet0 scope link src 172.21.0.5'; do
    TUN_MAIN_ROUTE="$bad_route"
    expect_return_status 1 magicnet_hotspot_return_path
  done
  TUN_MAIN_ROUTE='172.0.0.0/8 proto kernel src 172.21.0.1'
  TUN_ADDRESS=172.21.0.2/30
  expect_return_status 2 magicnet_hotspot_return_path
  TUN_ADDRESS=
  expect_return_status 1 magicnet_hotspot_return_path
  TUN_ADDRESS=172.21.0.1/8
  magicnet_hotspot_route_cleanup
  grep -Fqx '5000: from all uidrange 0-0 lookup wlan0' "$RULES"
  grep -Fqx '10000: from all uidrange 0-0 lookup wlan0' "$RULES"
  if grep -Fq 'lookup main' "$RULES"; then exit 1; fi

  # A known bad path after installation must roll back, not publish active.
  TUN_FORCE_RETURN_UPSTREAM=1
  expect_return_status 1 magicnet_hotspot_reconcile
  [ ! -e "$(magicnet_hotspot_route_state_file)" ]
  [ ! -e "$(magicnet_hotspot_route_pending_file)" ]
  [ ! -s "$WORK/forward-rules" ]
  if grep -Fq 'lookup main' "$RULES"; then exit 1; fi
  (
    HOTSPOT_CIDR=
    TUN_ADDRESS_QUERY_FAIL=1
    magicnet_iface_exists() { [ "$1" != magicnet0 ]; }
    magicnet_hotspot_route_status >"$WORK/status"
    grep -Fqx 'route_status=waiting-for-hotspot' "$WORK/status"
    printf '%s\n' 'return4|4999|172.21.0.2/32' >"$(magicnet_hotspot_route_state_file)"
    magicnet_hotspot_route_status >"$WORK/status"
    grep -Fqx 'route_status=unknown' "$WORK/status"
  )
)

assert_hotspot_internal_return_routing

# A disabled selector does not prove successful cleanup. Interrupted writes
# and disappeared downstreams must retain their recovery/unknown status.
(
  WORK="$HOTSPOT_DISABLED_WORK"
  MODDIR="$WORK/module"
  RULES="$WORK/ip-rules"
  mkdir -p "$MODDIR/.state/hotspot"
  printf '%s\n' '10000: from all uidrange 0-0 lookup wlan0' >"$RULES"
  : >"$WORK/forward-rules"
  : >"$WORK/ip-writes"
  : >"$WORK/route-lookups"
  HOTSPOT_CIDR=
  magicnet_transparent_mode() { printf 'tun\n'; }
  assert_disabled_status() {
    magicnet_hotspot_route_status >"$WORK/status"
    grep -Fqx "route_status=$1" "$WORK/status" || {
      printf 'expected disabled hotspot status %s\n' "$1" >&2
      cat "$WORK/status" >&2
      exit 1
    }
  }
  assert_disabled_status disabled
  printf '%s\n' 'return4|9999|172.20.0.2/32' >"$(magicnet_hotspot_route_pending_file)"
  printf '%s\n' '9999: from all to 172.20.0.2 lookup main' >>"$RULES"
  assert_disabled_status pending
  printf '%s\n' '8999|wlan2' >>"$(magicnet_hotspot_route_pending_file)"
  printf '%s\n' '8999: from all iif wlan2 lookup 2022' >>"$RULES"
  assert_disabled_status pending
  grep -Fqx 'policy_rule_observed=1' "$WORK/status"
  printf '%s\n' 'corrupt' >"$(magicnet_hotspot_route_pending_file)"
  assert_disabled_status unknown
  printf '%s\n' 'return4|9999|172.20.0.2/32' '8999|wlan2' >"$(magicnet_hotspot_route_pending_file)"
  mv "$(magicnet_hotspot_route_pending_file)" "$(magicnet_hotspot_route_state_file)"
  assert_disabled_status degraded
  magicnet_hotspot_route_cleanup
  assert_disabled_status disabled
  HOTSPOT_ROUTE_QUERY_FAIL=1
  assert_disabled_status unknown
)

printf '%s\n' 'hotspot routing test passed'
