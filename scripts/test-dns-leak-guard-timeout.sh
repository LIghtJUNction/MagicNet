#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/network.sh"

MODDIR="$WORK/module"
export MODDIR
mkdir -p "$MODDIR/.state"
state_file="$MODDIR/.state/dns-leak-guard.ifaces"
printf '%s\n' wlan0 >"$state_file"
attempts_file="$MODDIR/.state/xtables-attempts"
: >"$attempts_file"

iptables() {
    printf 'attempt\n' >>"$attempts_file"
    return 124
}
magicnet_cmd_exists() { [ "${1:-}" = iptables ]; }
magicnet_collect_physical_egress_ifaces() { printf '%s\n' wlan0; }
magicnet_warn() { :; }

MAGICNET_XTABLES_TIMEOUT=7
if magicnet_disable_dns_leak_guard; then
    printf '%s\n' 'timed-out DNS leak guard cleanup unexpectedly succeeded' >&2
    exit 1
fi
[ "$(wc -l <"$attempts_file" | tr -d ' ')" -eq 1 ] || {
    printf '%s\n' 'xtables timeout did not stop remaining cleanup probes' >&2
    exit 1
}
[ -e "$state_file" ] || {
    printf '%s\n' 'timed-out cleanup removed its retry state' >&2
    exit 1
}
[ "$MAGICNET_XTABLES_TIMEOUT" = 7 ] || {
    printf '%s\n' 'cleanup did not restore the caller xtables timeout' >&2
    exit 1
}

(
    MODDIR="$WORK/probe-timeout-module"
    export MODDIR
    mkdir -p "$MODDIR/.state"
    probe_state="$MODDIR/.state/dns-leak-guard.ifaces"
    printf '%s\n' wlan0 >"$probe_state"
    magicnet_xtables_available() { return 124; }

    if magicnet_disable_dns_leak_guard; then
        printf '%s\n' 'timed-out xtables availability probe was treated as unavailable' >&2
        exit 1
    fi
    [ -e "$probe_state" ] || {
        printf '%s\n' 'probe timeout removed DNS leak guard retry state' >&2
        exit 1
    }
)

printf '%s\n' 'DNS leak guard timeout circuit-breaker test passed'
