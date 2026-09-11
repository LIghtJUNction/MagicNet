#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/network.sh"
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/core.sh"

MODDIR="$WORK/module"
mkdir -p "$MODDIR/.state"
CALLS="$WORK/calls"
: >"$CALLS"
magicnet_warn() { printf '%s\n' "$*" >&2; }
magicnet_log() { :; }
magicnet_cmd_exists() { return 0; }
magicnet_xtables_function_defined() { return 1; }
magicnet_transparent_mode() { printf 'tun\n'; }
magicnet_dns_profile() { printf 'secure\n'; }
magicnet_ipv6_mode() { printf '%s\n' "${TEST_IPV6_MODE:-prefer_ipv4}"; }
magicnet_dns_capture_singbox_mark() { printf '123\n'; }
magicnet_dns_capture_singbox_udp_marked() { return 1; }
magicnet_collect_physical_egress_ifaces() { printf 'wlan0\n'; }
magicnet_hotspot_reconcile() { :; }
magicnet_start_singbox_unlocked() { touch "$WORK/running"; }
singbox_stop() { rm -f "$WORK/running"; }
import() { :; }

# File-backed rules survive the production helpers' subshells. IPv4 NAT and
# both filter tables work; IPv6 NAT is absent, as in the reported device.
mock_xtables() {
    local family="$1" table=filter command rules line
    shift
    printf '%s %s\n' "$family" "$*" >>"$CALLS"
    if [ "${1:-}" = -t ]; then table="$2"; shift 2; fi
    command="$1"; shift
    rules="$WORK/$family-$table.rules"
    touch "$rules"
    if [ "$family:$table" = ip6tables:nat ]; then
        printf "can't initialize ip6tables table nat: Table does not exist\n" >&2
        return 3
    fi
    case "$command" in
    -L)
        # A nonnumeric listing may block in reverse DNS during startup.
        case " $* " in *' -n '*) ;; *) return 124 ;; esac
        if [ "${1:-}" = magicnet-dns-output ]; then
            [ -e "$rules.chain" ] || return 2
        fi
        ;;
    -S)
        printf '%s\n' '-P OUTPUT ACCEPT'
        sed -n 's/^OUTPUT /-A OUTPUT /p' "$rules"
        ;;
    -N) [ ! -e "$rules.chain" ] || return 1; touch "$rules.chain" ;;
    -F)
        [ "$1" = magicnet-dns-output ] || return 99
        sed '/^magicnet-dns-output /d' "$rules" >"$rules.new"
        mv "$rules.new" "$rules"
        ;;
    -X) [ "$1" = magicnet-dns-output ] || return 99; rm -f "$rules.chain" ;;
    -C | -D)
        if [ "$command" = -C ] && [ -n "${TEST_CHECK_ERROR:-}" ]; then
            printf '%s\n' "$TEST_CHECK_ERROR" >&2
            return "${TEST_CHECK_RC:-2}"
        fi
        if ! grep -Fxq -- "$*" "$rules"; then
            printf 'Bad rule (does a matching rule exist in that chain?).\n' >&2
            return 2
        fi
        if [ "$command" = -D ]; then
            if [ -e "$WORK/transient-delete" ]; then
                rm -f "$WORK/transient-delete"
                return 1
            fi
            if [ "${TEST_DELETE_FAIL:-0}" = 1 ]; then
                printf 'permission denied deleting rule\n' >&2
                return "${TEST_DELETE_RC:-4}"
            fi
            awk -v rule="$*" '$0 == rule && !removed { removed=1; next } { print }' "$rules" >"$rules.new"
            mv "$rules.new" "$rules"
        fi
        ;;
    -A | -I)
        if [ "${TEST_ADD_FAIL:-0}" = 1 ]; then
            printf 'permission denied adding rule\n' >&2
            return 4
        fi
        line="$*"
        if [ "$command" = -I ] && [ "${2:-}" = 1 ]; then
            line="$1 ${*:3}"
        fi
        printf '%s\n' "$line" >>"$rules"
        ;;
    *) printf 'unexpected mock command: %s\n' "$command" >&2; return 99 ;;
    esac
}
magicnet_iptables_cmd() { mock_xtables iptables "$@"; }
magicnet_ip6tables_cmd() { mock_xtables ip6tables "$@"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

printf '%s\n' 'OUTPUT -j mihomo-output' 'OUTPUT -j sing-box-output' >"$WORK/iptables-nat.rules"
printf '%s\n' 'OUTPUT -j oem_out' >"$WORK/iptables-filter.rules"
printf 'wlan0\n' >"$MODDIR/.state/dns-leak-guard.ifaces"
magicnet_start_singbox_ready_unlocked 2>"$WORK/start.log" || fail 'IPv4-first startup failed'
[ -e "$WORK/running" ] || fail 'healthy core was rolled back'
[ ! -e "$MODDIR/.state/dns-leak-guard.ifaces" ] || fail 'absent legacy rules prevented cleanup'
for proto in udp tcp; do
    grep -Fq -- "-p $proto --dport 53 -j REDIRECT --to-ports 1053" "$WORK/iptables-nat.rules" || fail 'IPv4 DNS capture missing'
done
magicnet_enable_dns_capture 2>>"$WORK/start.log" || fail 'repeated capture failed'
[ "$(grep -Fxc 'OUTPUT -j magicnet-dns-output' "$WORK/iptables-nat.rules")" = 1 ] || fail 'duplicate capture jump'
MAGIC_DNS_LEAK_GUARD=1 magicnet_enable_dns_leak_guard || fail 'IPv6 filter guard required IPv6 NAT'
grep -Fq -- '-p udp --dport 53 -j REJECT' "$WORK/ip6tables-filter.rules" || fail 'IPv6 leak guard missing'
magicnet_disable_dns_leak_guard || fail 'guard cleanup failed'
magicnet_disable_dns_capture || fail 'capture cleanup failed'
[ "$(cat "$WORK/iptables-nat.rules")" = "$(printf '%s\n' 'OUTPUT -j mihomo-output' 'OUTPUT -j sing-box-output')" ] || fail 'foreign NAT rules changed'
[ "$(cat "$WORK/iptables-filter.rules")" = 'OUTPUT -j oem_out' ] || fail 'OEM rules changed'

# Required IPv6 and actual IPv4 write failures must still roll back the core.
for scenario in ipv6 write; do
    TEST_IPV6_MODE=prefer_ipv4 TEST_ADD_FAIL=0
    if [ "$scenario" = ipv6 ]; then TEST_IPV6_MODE=prefer_ipv6; else TEST_ADD_FAIL=1; fi
    if magicnet_start_singbox_ready_unlocked 2>"$WORK/$scenario.log"; then fail "$scenario failure was hidden"; fi
    [ ! -e "$WORK/running" ] || fail "$scenario failure left core running"
done
grep -Fq 'permission denied adding rule' "$WORK/write.log" || fail 'write error was discarded'
unset TEST_IPV6_MODE TEST_ADD_FAIL

# rc=2 alone never means absence: extension/syntax errors remain visible.
for TEST_CHECK_ERROR in 'unknown option --bad-extension' 'No chain/target/match by that name'; do
    if magicnet_iptables_ensure OUTPUT -j REJECT 2>"$WORK/check.log"; then fail 'ambiguous error accepted'; fi
    grep -Fq "$TEST_CHECK_ERROR" "$WORK/check.log" || fail 'check error was discarded'
done
TEST_CHECK_ERROR='lock wait timed out' TEST_CHECK_RC=124
if magicnet_iptables_ensure OUTPUT -j REJECT 2>"$WORK/timeout.log"; then fail 'timeout accepted'; else rc=$?; fi
[ "$rc" = 124 ] || fail 'timeout status changed'
unset TEST_CHECK_ERROR TEST_CHECK_RC

printf '%s\n' 'OUTPUT -j REJECT' >>"$WORK/iptables-filter.rules"
touch "$WORK/transient-delete"
magicnet_xtables_delete_rule magicnet_iptables_cmd '' OUTPUT -j REJECT || fail 'transient deletion was not retried'
if grep -Fxq 'OUTPUT -j REJECT' "$WORK/iptables-filter.rules"; then fail 'transient deletion left a rule'; fi

printf '%s\n' 'OUTPUT -j REJECT' >>"$WORK/iptables-filter.rules"
TEST_DELETE_FAIL=1
before="$(wc -l <"$CALLS")"
if magicnet_xtables_delete_rule magicnet_iptables_cmd '' OUTPUT -j REJECT 2>"$WORK/delete.log"; then fail 'failed deletion accepted'; fi
[ "$(( $(wc -l <"$CALLS") - before ))" = 2 ] || fail 'failed deletion retried indefinitely'
grep -Fq 'permission denied deleting rule' "$WORK/delete.log" || fail 'delete error was discarded'
grep -Fxq 'OUTPUT -j REJECT' "$WORK/iptables-filter.rules" || fail 'failed deletion changed rule'
TEST_DELETE_RC=1
before="$(wc -l <"$CALLS")"
if magicnet_xtables_delete_rule magicnet_iptables_cmd '' OUTPUT -j REJECT 2>"$WORK/retry.log"; then fail 'persistent generic deletion error accepted'; fi
[ "$(( $(wc -l <"$CALLS") - before ))" = 6 ] || fail 'transient deletion retries are not bounded'
unset TEST_DELETE_FAIL TEST_DELETE_RC
printf 'Android xtables startup regression tests passed\n'
