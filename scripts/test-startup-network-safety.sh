#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MODDIR="$WORK/module"
MOCK_CALLS="$WORK/calls"
MOCK_RULES="$WORK/rules"
export MODDIR MOCK_CALLS MOCK_RULES
mkdir -p "$WORK/bin" "$MODDIR/.state"
: >"$MOCK_CALLS"
: >"$MOCK_RULES"

# Executable fixtures exercise the real timeout/wait wrappers, not the
# function-double shortcut in magicnet_xtables_available.
cat >"$WORK/bin/iptables" <<'MOCK'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >>"$MOCK_CALLS"
[ "${1:-}" != -w ] || shift 2
case "$*" in
'-t nat '*)
    if [ "$*" = '-t nat -L -n' ] && [ "${MOCK_PROBE_RC:-0}" -ne 0 ]; then
        echo 'xtables lock/permission failure' >&2
        exit "$MOCK_PROBE_RC"
    fi
    if [ "${MOCK_NAT:-missing}" = missing ] || [ "${0##*/}" = ip6tables ]; then
        echo "cannot initialize nat: Table does not exist" >&2
        exit 3
    fi ;;
esac
case "$*" in
'-t nat -L -n') exit 0 ;;
'-L') exit 0 ;;
'-S OUTPUT') cat "$MOCK_RULES"; exit 0 ;;
'-t nat -L magicnet-dns-output') exit 1 ;;
'-t nat -N '*|'-t nat -F '*|'-t nat -X '*|'-t nat -I '*|'-t nat -A '*)
    [ "${MOCK_WRITE_RC:-0}" -eq 0 ] || echo 'fixture write permission denied' >&2
    exit "${MOCK_WRITE_RC:-0}" ;;
'-t nat -C '*|'-t nat -D '*) exit 1 ;;
'-D OUTPUT '*)
    if [ "${MOCK_DELETE_RC:-0}" -ne 0 ]; then
        echo 'fixture delete permission denied' >&2
        exit "$MOCK_DELETE_RC"
    fi
    # All four guard protocols/ports are tried; only this fixture rule exists.
    case "$*" in *'-o rmnet0 -p udp --dport 53 -j REJECT') : >"$MOCK_RULES" ;; esac
    exit 0 ;;
'-C OUTPUT '*) [ -s "$MOCK_RULES" ]; exit $? ;;
esac
exit 0
MOCK
chmod +x "$WORK/bin/iptables"
ln -s iptables "$WORK/bin/ip6tables"
PATH="$WORK/bin:$PATH"
export PATH
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/network.sh"
magicnet_cmd_exists() { command -v "$1" >/dev/null 2>&1; }
magicnet_warn() { printf '%s\n' "$*" >&2; }
magicnet_log() { :; }
magicnet_transparent_mode() { printf '%s\n' "${TEST_MODE:-tun}"; }
magicnet_ipv6_mode() { printf '%s\n' "${TEST_IPV6:-prefer_ipv4}"; }
magicnet_dns_profile() { echo google; }
magicnet_dns_capture_singbox_mark() { echo 255; }
magicnet_dns_capture_singbox_udp_marked() { return 1; }
magicnet_hotspot_reconcile() { :; }
magicnet_collect_physical_egress_ifaces() { echo rmnet0; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
state="$MODDIR/.state/dns-leak-guard.ifaces"

# No NAT table and an obsolete saved interface must not abort TUN startup.
printf '%s\n' wlan0 >"$state"
magicnet_after_kernel_start_unlocked >"$WORK/log" 2>&1 || fail 'optional absent NAT/empty guard blocked startup'
[ ! -e "$state" ] || fail 'empty guard retained obsolete state'
! grep -q ' -D OUTPUT' "$MOCK_CALLS" || fail 'empty scan issued speculative deletes'
grep -q 'TUN DNS only' "$WORK/log" || fail 'degraded capture was not disclosed'
MAGIC_DNS_CAPTURE=0 magicnet_enable_dns_capture >/dev/null 2>&1 || fail 'disabled capture cleanup failed without NAT'
TEST_MODE=ebpf magicnet_enable_dns_capture >/dev/null 2>&1 || fail 'eBPF stale cleanup required NAT'
if TEST_IPV6=prefer_ipv6 magicnet_enable_dns_capture >/dev/null 2>&1; then
    fail 'required IPv6 capture silently degraded'
fi

# Lock/permission failures are indeterminate, not an unsupported table.
for MOCK_PROBE_RC in 4 124; do
    export MOCK_PROBE_RC
    if magicnet_enable_dns_capture >"$WORK/log" 2>&1; then fail 'probe failure hidden'; fi
    if magicnet_disable_dns_capture >/dev/null 2>&1; then fail 'uncertain cleanup reported success'; fi
    grep -q "exit=$MOCK_PROBE_RC" "$WORK/log" || fail 'probe exit status missing'
done
unset MOCK_PROBE_RC
MOCK_NAT=available
export MOCK_NAT
magicnet_enable_dns_capture >/dev/null 2>&1 || fail 'IPv4 capture rejected absent IPv6 NAT'
if MOCK_WRITE_RC=4 magicnet_enable_dns_capture >"$WORK/log" 2>&1; then fail 'write failure hidden'; fi
grep -q 'fixture write permission denied' "$WORK/log" || fail 'write stderr lost'

# A fresh scan finds a different interface; failed deletion must keep retry state.
printf '%s\n' '-A OUTPUT -o rmnet0 -p udp --dport 53 -j REJECT' >"$MOCK_RULES"
printf '%s\n' wlan0 >"$state"
if MOCK_DELETE_RC=4 magicnet_disable_dns_leak_guard >"$WORK/log" 2>&1; then fail 'delete failure hidden'; fi
[ -e "$state" ] || fail 'failed cleanup removed retry state'
grep -q 'fixture delete permission denied' "$WORK/log" || fail 'delete stderr lost'
magicnet_disable_dns_leak_guard || fail 'discovered rules were not cleaned'
[ ! -s "$MOCK_RULES" ] && [ ! -e "$state" ] || fail 'successful cleanup incomplete'
grep -q '^iptables -w 1 ' "$MOCK_CALLS" || fail 'IPv4 bounded lock wait missing'
grep -q '^ip6tables -w 1 ' "$MOCK_CALLS" || fail 'IPv6 bounded lock wait missing'

# Startup errors must describe the failed phase, not falsely claim no binary.
(
    # shellcheck disable=SC1091
    . "$ROOT/src/MagicNet/lib/magicnet/core.sh"
    magicnet_detach_pid_from_app_cgroup() { :; }
    magicnet_kernel_start_preamble() { :; }
    magicnet_kernel_running() { return 1; }
    magicnet_require_subscription_or_stop() { :; }
    magicnet_start_singbox_ready() { return 1; }
    magicnet_cmd_exists() { return 0; }
    magicnet_disable_dns_capture() { :; }
    magicnet_disable_dns_leak_guard() { :; }
    if magicnet_start_kernel >"$WORK/log" 2>&1; then fail 'failed start reported success'; fi
    grep -q 'preceding core or network error' "$WORK/log" || fail 'misleading startup diagnostic'
    magicnet_start_singbox_unlocked() { :; }
    magicnet_after_kernel_start_unlocked() { return 1; }
    import() { :; }
    singbox_stop() { : >"$WORK/stopped"; }
    if magicnet_start_singbox_ready_unlocked >/dev/null 2>&1; then fail 'rollback reported success'; fi
    [ -f "$WORK/stopped" ] || fail 'genuine post-start failure did not stop the core'
)
printf '%s\n' 'startup network safety regressions passed'
