#!/usr/bin/env bash
# Real netlink negative controls. Never touches the runner's routing namespace.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --inside ]]; then
    [[ $EUID == 0 ]] || { echo 'network namespace regression requires root' >&2; exit 1; }
    command -v ip >/dev/null
    ns="mn-ownership-$$-$RANDOM"
    work="$(mktemp -d)"
    cleanup() { ip netns del "$ns" >/dev/null 2>&1 || true; rm -rf "$work"; }
    trap cleanup EXIT
    ip netns add "$ns"
    ip netns exec "$ns" bash "$0" --inside "$work"
    exit
fi
MODDIR="$2/module"
mkdir -p "$MODDIR/.state/network"
kernel_state=stopped
magicnet_kernel_running() { [[ "$kernel_state" == running ]] && return 0; return 1; }
magicnet_transparent_mode() { printf 'tun\n'; }
magicnet_iface_exists() { ip link show dev "$1" >/dev/null 2>&1; }
magicnet_warn() { printf '%s\n' "$*" >&2; }
magicnet_refresh_status() { :; }
magicnet_hotspot_route_cleanup() { :; }
# shellcheck source=/dev/null
. "$ROOT/src/MagicNet/lib/magicnet/lifecycle.sh"

ip link add magicnet0 type dummy
ip link add foreign0 type dummy
ip link set magicnet0 up
ip link set foreign0 up
ip route add 198.51.100.0/24 dev foreign0 table 2022
ip rule add priority 9002 from 192.0.2.0/24 lookup 2022
# Linux rejects a broad new rule when a more-specific matching one already
# exists. Cover the valid wildcard collision and both orders for two nonzero
# source selectors instead of fabricating an impossible kernel state.
for scenario in wildcard-owned-first prefixed-foreign-first prefixed-owned-first; do
    owned=(priority 9000 fwmark 0x200000 lookup 2022)
    if [[ "$scenario" == prefixed-* ]]; then owned+=(from 192.0.2.128/25); fi
    magicnet_kernel_route_state_begin
    ip rule add "${owned[@]}"
    ip route add default dev magicnet0 table 2022
    kernel_state=running
    magicnet_kernel_route_state_capture
    ip rule del "${owned[@]}"
    if [[ "$scenario" == prefixed-foreign-first ]]; then
        ip rule add priority 9000 from 203.0.113.0/24 fwmark 0x200000 lookup 2022
        ip rule add "${owned[@]}"
    else
        ip rule add "${owned[@]}"
        ip rule add priority 9000 from 203.0.113.0/24 fwmark 0x200000 lookup 2022
    fi
    before="$(ip rule show)"
    kernel_state=stopped
    rc=0
    magicnet_kernel_route_cleanup_after_stop || rc=$?
    [[ "$rc" == 2 ]] || { echo 'ambiguous netlink deletion was allowed' >&2; exit 1; }
    [[ "$(ip rule show)" == "$before" ]]
    test -f "$(magicnet_kernel_route_state_file)"
    # The fixture owns this foreign rule: its nonzero source prefix selects it.
    ip rule del priority 9000 from 203.0.113.0/24 fwmark 0x200000 lookup 2022
    magicnet_kernel_route_cleanup_after_stop
    ip rule show | grep -F '9002:' | grep -F 'from 192.0.2.0/24' | grep -F 'lookup 2022'
    ip route show table 2022 | grep -F 'dev foreign0'
    if ip route show table 2022 | grep -F 'dev magicnet0'; then exit 1; fi
    if ip rule show | grep -F '9000:'; then exit 1; fi
    test ! -e "$(magicnet_kernel_route_state_file)"
    before="$(ip rule show; ip route show table 2022)"
    magicnet_kernel_route_cleanup_after_stop
    [[ "$(ip rule show; ip route show table 2022)" == "$before" ]]
done
echo 'Real netlink ownership, collision, scoped cleanup and repeated-stop regressions passed'
