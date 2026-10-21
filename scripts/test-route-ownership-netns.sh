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
[[ $# == 2 && $EUID == 0 ]] || { echo 'invalid isolated fixture invocation' >&2; exit 1; }
current_netns="$(readlink /proc/self/ns/net)"
parent_netns="$(readlink "/proc/$PPID/ns/net")"
[[ -n "$current_netns" && -n "$parent_netns" && "$current_netns" != "$parent_netns" ]] || {
    echo 'refusing to exercise routes in the caller network namespace' >&2
    exit 1
}
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

# Retire this fixture's foreign resources before the independent hotspot case.
ip rule del priority 9002 from 192.0.2.0/24 lookup 2022
ip route del 198.51.100.0/24 dev foreign0 table 2022
ip link del foreign0

fail() { printf '%s\n' "$*" >&2; exit 1; }
expect_route() {
    local destination="$1" source="$2" expected="$3" result
    result="$(ip -4 route get "$destination" from "$source" uid 0)"
    printf '%s\n' "$result" | awk -v expected="$expected" '
        { for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == expected) found = 1 }
        END { exit !found }
    ' || fail "UID 0 route to $destination selected the wrong interface: $result"
}
expect_not_ready() {
    local status
    status="$(magicnet_hotspot_route_status)"
    printf '%s\n' "$status" | awk -F= '
        $1 == "route_status" {
            count++
            if (NF == 2 && ($2 == "pending" || $2 == "degraded" || $2 == "unknown")) valid++
        }
        END { exit !(count == 1 && valid == 1) }
    ' || fail "hotspot must report one pending/degraded/unknown state: $status"
}
read_return_record() {
    local records
    records="$(awk -F'|' '$1 == "return4" {print}' "$(magicnet_hotspot_route_state_file)")"
    [[ "$(printf '%s\n' "$records" | wc -l)" == 1 && -n "$records" ]] ||
        fail 'expected exactly one owned return-path record'
    IFS='|' read -r record_kind return_priority return_cidr extra <<<"$records"
    [[ "$record_kind" == return4 && "$return_priority" =~ ^[0-9]+$ &&
        "$return_cidr" == "$1/32" && -z "$extra" ]] || fail 'invalid return-path ownership record'
}

# Use production address discovery, RPDB inspection, installation and cleanup.
# Only Android tether discovery and FORWARD permissions are outside this FIB
# fixture's scope. No ip/addr/route/rule command is mocked.
# shellcheck source=/dev/null
. "$ROOT/src/MagicNet/lib/magicnet/routes.sh"
# Keep the production core-liveness override in the normal source order.
# shellcheck source=/dev/null
. "$ROOT/src/MagicNet/lib/magicnet/lifecycle.sh"
magicnet_hotspot_discover_interfaces() { printf 'wlan2\n'; }
magicnet_hotspot_forward_access() {
    case "$1" in ensure | status | cleanup) return 0 ;; *) return 2 ;; esac
}
kernel_state=running
mkdir -p "$MODDIR/.state/hotspot"
printf 'value=0\n' >"$(magicnet_hotspot_offload_state_file)"
ip link set lo up
ip addr add 172.20.0.1/30 dev magicnet0
ip link add upstream0 type dummy
ip addr add 192.0.2.2/24 dev upstream0
ip link set upstream0 up
ip link add wlan2 type dummy
ip addr add 192.168.52.1/24 dev wlan2
ip link set wlan2 up
ip route add default via 192.0.2.1 dev upstream0 table 100
ip rule add priority 10000 uidrange 0-0 lookup 100
ip rule add priority 21000 iif wlan2 lookup 100
ip route add default dev magicnet0 table 2022
upstream_rules="$(ip -4 rule show | awk '$1 == "10000:" || $1 == "21000:"')"
upstream_routes="$(ip -4 route show table 100)"

# The peer MUST NOT be assigned locally: table local would hide the regression.
# The connected main route exists, yet an earlier Android-style UID policy wins.
ip -4 route show table main dev magicnet0 scope link | grep -F '172.20.0.0/30'
expect_route 172.20.0.2 172.20.0.1 upstream0
magicnet_hotspot_reconcile
expect_route 172.20.0.2 172.20.0.1 magicnet0
[[ "$(magicnet_hotspot_return_path)" == '172.20.0.1|172.20.0.2|172.20.0.2/32' ]]
magicnet_hotspot_return_path_ready 172.20.0.1 172.20.0.2
magicnet_hotspot_routes_current 'wlan2|192.168.52.0/24'
magicnet_hotspot_route_status | grep -Fx 'route_status=ready'
expect_route 203.0.113.80 192.0.2.2 upstream0
read_return_record 172.20.0.2
before="$(ip -4 rule show; cat "$(magicnet_hotspot_route_state_file)")"
magicnet_hotspot_reconcile
[[ "$(ip -4 rule show; cat "$(magicnet_hotspot_route_state_file)")" == "$before" ]]

# Rule membership alone is insufficient when a newly installed foreign policy
# takes precedence. The status/current probes must notice, then reconcile repairs
# the return route without removing or weakening the UID 0 upstream exclusion.
preempt_priority=$((return_priority - 1))
[[ "$preempt_priority" -gt 0 ]]
ip rule add priority "$preempt_priority" uidrange 0-0 lookup 100
preempt_rule="$(ip -4 rule show | awk -v p="${preempt_priority}:" '$1 == p')"
expect_route 172.20.0.2 172.20.0.1 upstream0
expect_not_ready
if magicnet_hotspot_routes_current 'wlan2|192.168.52.0/24'; then
    fail 'an earlier foreign policy was mistaken for a current return route'
fi
magicnet_hotspot_reconcile
expect_route 172.20.0.2 172.20.0.1 magicnet0
ip -4 rule show | grep -Fx "$preempt_rule"
expect_route 203.0.113.80 192.0.2.2 upstream0

# A rebuilt TUN address changes the internal peer; a persisted old /32 cannot
# establish readiness for the new peer or remain installed after reconciliation.
read_return_record 172.20.0.2
old_return_priority="$return_priority"
ip addr del 172.20.0.1/30 dev magicnet0
ip addr add 172.21.0.1/30 dev magicnet0
# Deleting the last IPv4 address also flushes this device's table 2022 route.
# Model the core rebuilding its route before reconciling module-owned rules.
ip route replace default dev magicnet0 table 2022
magicnet_hotspot_tun_route_table_ready
expect_route 172.21.0.2 172.21.0.1 upstream0
expect_not_ready
magicnet_hotspot_reconcile
expect_route 172.21.0.2 172.21.0.1 magicnet0
read_return_record 172.21.0.2
rc=0
magicnet_hotspot_return_rule_present "$old_return_priority" 172.20.0.2/32 || rc=$?
[[ "$rc" == 1 ]] || fail 'the old TUN peer rule was not confirmed absent after address replacement'
expect_route 172.20.0.2 172.21.0.1 upstream0

# Two possible local/peer pairs are unknown, not a license to guess one.
ip addr add 172.22.0.1/30 dev magicnet0
rc=0
magicnet_hotspot_return_path >/dev/null || rc=$?
[[ "$rc" == 2 ]] || fail 'ambiguous TUN addresses were accepted'
expect_not_ready
ip addr del 172.22.0.1/30 dev magicnet0
magicnet_hotspot_route_status | grep -Fx 'route_status=ready'

# Linux's deletion selector can match a foreign sibling with an additional
# source prefix. Reject that ambiguity before deleting either rule; keep the
# pending journal so a later cleanup can finish after the fixture removes it.
owned_return_rule="$(ip -4 rule show | awk -v p="${return_priority}:" '$1 == p')"
ip -4 rule add priority "$return_priority" from 203.0.113.0/24 to "$return_cidr" lookup main
foreign_return_rule="$(ip -4 rule show | awk -v p="${return_priority}:" '$1 == p && $2 == "from" && $3 == "203.0.113.0/24"')"
[[ -n "$owned_return_rule" && -n "$foreign_return_rule" ]]
before="$(ip -4 rule show)"
rc=0
magicnet_hotspot_delete_return_rule "$return_priority" "$return_cidr" || rc=$?
[[ "$rc" == 2 ]] || fail 'ambiguous return-rule deletion was allowed'
[[ "$(ip -4 rule show)" == "$before" ]]
if magicnet_hotspot_route_cleanup; then fail 'ambiguous return cleanup claimed success'; fi
test -f "$(magicnet_hotspot_route_pending_file)"
ip -4 rule show | grep -Fx "$owned_return_rule"
ip -4 rule show | grep -Fx "$foreign_return_rule"
expect_not_ready
ip -4 rule del priority "$return_priority" from 203.0.113.0/24 to "$return_cidr" lookup main
connected_routes="$(ip -4 route show table main dev magicnet0 scope link)"
magicnet_hotspot_route_cleanup
test ! -e "$(magicnet_hotspot_route_state_file)"
test ! -e "$(magicnet_hotspot_route_pending_file)"
[[ "$(ip -4 rule show | awk '$1 == "10000:" || $1 == "21000:"')" == "$upstream_rules" ]]
ip -4 rule show | grep -Fx "$preempt_rule"
[[ "$(ip -4 route show table 100)" == "$upstream_routes" ]]
[[ "$(ip -4 route show table main dev magicnet0 scope link)" == "$connected_routes" ]]
expect_route 172.21.0.2 172.21.0.1 upstream0
expect_route 203.0.113.80 192.0.2.2 upstream0
before="$(ip -4 rule show; ip -4 route show table all)"
magicnet_hotspot_route_cleanup
[[ "$(ip -4 rule show; ip -4 route show table all)" == "$before" ]]
echo 'Real kernel hotspot return priority, UID 0 exclusion, address replacement and scoped cleanup passed'
echo 'NOT_TESTED: TUN TCP handshake, Android netd, OEM kernels, physical hotspot clients'
