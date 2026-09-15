#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

MODDIR="$WORK/module"
mkdir -p "$MODDIR/.state/network"
RULE4="$WORK/rule4"
RULE6="$WORK/rule6"
ROUTE4="$WORK/route4"
ROUTE6="$WORK/route6"
EVENTS="$WORK/events"
: >"$RULE4"
: >"$RULE6"
: >"$ROUTE4"
: >"$ROUTE6"
: >"$EVENTS"

kernel_state=stopped

magicnet_warn() { printf 'warn:%s\n' "$*" >>"$EVENTS"; }
magicnet_transparent_mode() { printf '%s\n' tun; }
magicnet_iface_exists() { [ "$1" = magicnet0 ]; }
magicnet_kernel_running() {
    case "$kernel_state" in
    running) return 0 ;;
    stopped) return 1 ;;
    *) return 2 ;;
    esac
}
magicnet_refresh_status() {
    printf 'description:%s\n' "$kernel_state" >>"$EVENTS"
}
magicnet_hotspot_interface_allowed() {
    case "$1" in
    wlan[0-9]* | softap[0-9]* | ap_br_wlan[0-9]* | ap_br_softap[0-9]* | swlan[0-9]* | rndis[0-9]* | usb[0-9]* | bt-pan | bt-pan[0-9]* | p2p[0-9]* | p2p-*) return 0 ;;
    *) return 1 ;;
    esac
}
magicnet_hotspot_route_cleanup() {
    printf 'hotspot-state-cleanup\n' >>"$EVENTS"
    return 0
}
magicnet_hotspot_delete_rule() {
    priority="$1"
    iface="$2"
    awk -v expected="${priority}:" -v iface="$iface" '
        !($1 == expected && index($0, "iif " iface " ") > 0 && index($0, "lookup 2022") > 0)
    ' "$RULE4" >"$RULE4.new"
    mv "$RULE4.new" "$RULE4"
    printf 'hotspot-rule-del:%s:%s\n' "$priority" "$iface" >>"$EVENTS"
}

assert_absent() {
    _needle="$1"
    _file="$2"
    if grep -Fq "$_needle" "$_file"; then
        printf 'unexpected line remained: %s\n' "$_needle" >&2
        exit 1
    fi
}

ip() {
    family=4
    if [ "${1:-}" = -6 ]; then
        family=6
        shift
    fi
    case "$family" in
    4) rules="$RULE4"; routes="$ROUTE4" ;;
    6) rules="$RULE6"; routes="$ROUTE6" ;;
    esac

    case "${1:-}:${2:-}" in
    rule:show)
        cat "$rules"
        ;;
    rule:del)
        shift 2
        [ "${1:-}" = priority ] || return 64
        priority="$2"
        [ "${3:-}" = lookup ] || return 64
        [ "${4:-}" = 2022 ] || return 64
        awk -v expected="${priority}:" '
            BEGIN { removed = 0 }
            $1 == expected && index($0, "lookup 2022") > 0 && removed == 0 { removed = 1; next }
            { print }
        ' "$rules" >"$rules.new"
        mv "$rules.new" "$rules"
        printf 'rule-del:%s:%s:2022\n' "$family" "$priority" >>"$EVENTS"
        ;;
    route:show)
        cat "$routes"
        ;;
    route:flush)
        : >"$routes"
        printf 'route-flush:%s:%s\n' "$family" "${4:-}" >>"$EVENTS"
        ;;
    *)
        printf 'unexpected ip command: family=%s args=%s\n' "$family" "$*" >&2
        return 64
        ;;
    esac
}

# shellcheck source=/dev/null
. "$ROOT/src/MagicNet/lib/magicnet/lifecycle.sh"

printf 'default dev magicnet0 scope link\n' >"$ROUTE4"
printf 'default dev magicnet0 metric 1024\n' >"$ROUTE6"

# A stale TUN route is never sufficient to re-enable hotspot routing while the
# managed core is stopped.
kernel_state=stopped
if magicnet_hotspot_tun_route_table_ready; then
    printf 'route readiness ignored stopped kernel\n' >&2
    exit 1
fi
kernel_state=running
magicnet_hotspot_tun_route_table_ready

# A live process without a materialized MagicNet TUN table is not enough to
# claim table ownership.
STATE="$MODDIR/.state/network/kernel-route-table.state"
: >"$ROUTE4"
if magicnet_kernel_route_state_capture; then
    printf 'route ownership recorded before table materialization\n' >&2
    exit 1
fi
[ ! -e "$STATE" ]
printf 'default dev magicnet0 scope link\n' >"$ROUTE4"

# Start commit records route ownership and updates the module description only
# after the core and its route table are known to be live.
magicnet_lifecycle_after_start
[ -f "$STATE" ]
grep -Fqx 'table=2022' "$STATE"
grep -Fqx 'interface=magicnet0' "$STATE"
grep -Fqx 'description:running' "$EVENTS"

cat >"$RULE4" <<'EOF'
8999: from all iif wlan2 lookup 2022
9000: from all fwmark 0x200000 lookup 2022
9001: from all lookup 2022
9100: from all lookup 2022
32768: from all lookup 2022
9000: from all lookup 777
EOF
cat >"$RULE6" <<'EOF'
9000: from all lookup 2022
32768: from all lookup 2022
9100: from all lookup 2022
EOF

# Stop commit removes MagicNet hotspot rules, the owned sing-box rule window,
# the fallback rule, and both route-table families. Rules outside MagicNet's
# window and rules for another table must survive.
kernel_state=stopped
magicnet_lifecycle_after_stop

[ ! -s "$ROUTE4" ]
[ ! -s "$ROUTE6" ]
[ ! -e "$STATE" ]
assert_absent '8999:' "$RULE4"
assert_absent '9000: from all fwmark 0x200000 lookup 2022' "$RULE4"
assert_absent '9001: from all lookup 2022' "$RULE4"
assert_absent '32768: from all lookup 2022' "$RULE4"
grep -Fq '9100: from all lookup 2022' "$RULE4"
grep -Fq '9000: from all lookup 777' "$RULE4"
assert_absent '9000: from all lookup 2022' "$RULE6"
assert_absent '32768: from all lookup 2022' "$RULE6"
grep -Fq '9100: from all lookup 2022' "$RULE6"
grep -Fqx 'description:stopped' "$EVENTS"
grep -Fqx 'hotspot-rule-del:8999:wlan2' "$EVENTS"
grep -Fq 'rule-del:4:9000:2022' "$EVENTS"
grep -Fq 'rule-del:6:9000:2022' "$EVENTS"
grep -Fq 'route-flush:4:' "$EVENTS"
grep -Fq 'route-flush:6:' "$EVENTS"

# An indeterminate process state is fail-closed: do not claim that routing can
# be applied and do not destroy route ownership state.
kernel_state=unknown
printf 'table=2022\ninterface=magicnet0\n' >"$STATE"
if magicnet_kernel_route_cleanup_after_stop; then
    printf 'indeterminate kernel state allowed destructive cleanup\n' >&2
    exit 1
fi
[ -f "$STATE" ]

printf 'kernel route lifecycle tests passed\n'
