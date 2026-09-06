#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

set_i18n() { :; }
# shellcheck source=src/MagicNet/lib/magicnet/supervisors.sh
. "$ROOT/src/MagicNet/lib/magicnet/supervisors.sh"

magicnet_subscription_refresh_owner_file() { printf '%s/owner\n' "$fixture"; }
magicnet_subscription_refresh_loop_pids() { return "$scan_rc"; }
magicnet_watchdog_stop() { return 0; }
magicnet_fswatch_stop() { return 0; }
magicnet_wifi_policy_stop() { return 0; }
magicnet_hotspot_route_cleanup() { : >"$fixture/route-cleanup"; }
export MAGICNET_SUB_PRESERVE_REFRESH=0

assert_status() {
    local expected="$1" actual=0
    shift
    "$@" || actual=$?
    if [ "$actual" -ne "$expected" ]; then
        printf 'subscription stop safety: %s returned %s, expected %s\n' "$*" "$actual" "$expected" >&2
        exit 1
    fi
}

# No owner is not proof of absence: only a trustworthy empty scan permits
# aggregate stop to clean routes. An orphan or failed scan remains uncertain.
for scan_rc in 2 0 1; do
    expected=2
    [ "$scan_rc" -ne 1 ] || expected=0
    assert_status "$expected" magicnet_subscription_refresh_stop
    rm -f "$fixture/route-cleanup"
    assert_status "$expected" magicnet_supervisors_stop
    if [ "$expected" -eq 0 ]; then
        test -f "$fixture/route-cleanup"
    else
        test ! -e "$fixture/route-cleanup"
    fi
done

# With an owner record, an indeterminate PID must not reach the reaper.
# Once the PID is known dead, preserve the reaper's own tri-state result.
printf '123:456:subscription-refresh-v1\n' >"$fixture/owner"
magicnet_subscription_refresh_owner_matches() { return 1; }
magicnet_subscription_refresh_owner_pid_state() { return "$pid_state_rc"; }
magicnet_subscription_refresh_reap_state() {
    : >"$fixture/reaped"
    return "$reap_rc"
}
reap_rc=0
for pid_state_rc in 0 2; do
    expected=1
    [ "$pid_state_rc" -ne 2 ] || expected=2
    assert_status "$expected" magicnet_subscription_refresh_stop
    test ! -e "$fixture/reaped"
    test -f "$fixture/owner"
done
pid_state_rc=1
for reap_rc in 0 1 2; do
    assert_status "$reap_rc" magicnet_subscription_refresh_stop
    test -f "$fixture/reaped"
done

printf 'subscription stop safety tests passed\n'
