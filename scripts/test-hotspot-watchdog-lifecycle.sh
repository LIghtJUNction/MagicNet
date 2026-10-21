#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
MODDIR="$fixture/module"
KAM_HOME="$MODDIR"
KAMFW_DIR=''
export MODDIR KAM_HOME KAMFW_DIR
mkdir -p "$MODDIR/.state/watchdog" "$MODDIR/.log"
pid_file="$MODDIR/.state/watchdog/magicnet-hotspot-route.pid"
loop_file="${pid_file%.pid}.loop.sh"
lock_file="${pid_file%.pid}.lifecycle.lock"
decoy_pid=''
extra_pid=''
cleanup() {
    if declare -F magicnet_supervisor_orphan_pids >/dev/null; then
        for pid in $(magicnet_supervisor_orphan_pids hotspot-watchdog 2>/dev/null || true); do
            kill "$pid" 2>/dev/null || true
        done
    fi
    test -z "$decoy_pid" || kill "$decoy_pid" 2>/dev/null || true
    test -z "$extra_pid" || kill "$extra_pid" 2>/dev/null || true
    rm -rf "$fixture"
}
trap cleanup EXIT

print() { printf '%s\n' "$*"; }
set_i18n() { :; }
i18n() { printf '%s\n' "$1"; }
t() { cat; }
success() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; }
import() {
    test "$1" != watchdog || {
        # shellcheck disable=SC1091
        . "$ROOT/src/MagicNet/lib/kamfw/watchdog.sh"
    }
}
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"
# An optional source path lets a regression be run against the old revision.
# shellcheck disable=SC1090
. "${1:-$ROOT/src/MagicNet/lib/magicnet/supervisors.sh}"
# shellcheck disable=SC1091
. "$ROOT/scripts/test-lib/proc-reader-hook.sh"
magicnet_module_disabled() { return 1; }
magicnet_hotspot_proxy_enabled() { return 0; }
magicnet_kernel_running() { return 0; }
export MAGICNET_HOTSPOT_WATCH_INTERVAL=60
real_nohup=$(command -v nohup)
launch_entered="$fixture/launch-entered"
# Widen the real launcher's check/publish race without replacing its logic.
# Each background function execs the real command, preserving its PID.
nohup() { : >"$launch_entered"; sleep 0.2; exec "$real_nohup" "$@"; }

assert_one_loop() {
    local pids tracked
    pids=$(magicnet_supervisor_orphan_pids hotspot-watchdog)
    tracked=$(cat "$pid_file")
    test "$pids" = "$tracked" || {
        printf 'expected one tracked loop; observed [%s], tracked [%s]\n' "$pids" "$tracked" >&2
        return 1
    }
    magicnet_supervisor_pidfile_matches "$pid_file" "$tracked"
}

# Boot and explicit service startup can enter at the same time. Only one
# exact loop may survive, and the published PID must identify that loop.
starts=()
for ((attempt = 0; attempt < 4; attempt++)); do
    magicnet_hotspot_watchdog_start &
    starts+=("$!")
done
for pid in "${starts[@]}"; do wait "$pid"; done
assert_one_loop
tracked=$(cat "$pid_file")
# A persistent child must not inherit the short-lived start/stop lock.
(
    exec 7>"$lock_file"
    flock -n 7
)
for fd in /proc/"$tracked"/fd/*; do
    test "$(readlink "$fd" 2>/dev/null || true)" != "$lock_file"
done

# Reconcile an old duplicate without restarting the published healthy loop
# or killing a process whose argv merely mentions our script path.
sh "$loop_file" &
extra_pid=$!
sh -c 'sleep 60 & wait' "$loop_file decoy" &
decoy_pid=$!
sleep 0.05
magicnet_hotspot_watchdog_start
assert_one_loop
test "$(cat "$pid_file")" = "$tracked"
kill -0 "$decoy_pid"
if magicnet_supervisor_pid_live "$extra_pid"; then
    printf 'old duplicate survived startup reconciliation\n' >&2
    exit 1
fi
wait "$extra_pid" 2>/dev/null || true
extra_pid=''

# A missing PID file must not cause another orphan loop. The old exact
# instance is reclaimed before a new instance is published.
rm -f "$pid_file"
magicnet_hotspot_watchdog_start
assert_one_loop
test "$(cat "$pid_file")" != "$tracked"
kill -0 "$decoy_pid"

# Unknown process identity must leave the owner intact and refuse another
# start or a destructive stop.
tracked=$(cat "$pid_file")
saved_reader=$(declare -f magicnet_proc_reader_test_hook)
magicnet_proc_reader_test_hook() { return 2; }
for operation in magicnet_hotspot_watchdog_start magicnet_hotspot_watchdog_stop; do
    if "$operation" >/dev/null 2>&1; then
        printf '%s accepted unknown owner identity\n' "$operation" >&2
        exit 1
    else
        test "$?" -eq 2
    fi
done
test "$(cat "$pid_file")" = "$tracked"
kill -0 "$tracked"
eval "$saved_reader"

magicnet_hotspot_watchdog_stop
test ! -e "$pid_file"
if magicnet_supervisor_orphan_pids hotspot-watchdog >/dev/null; then
    printf 'hotspot watchdog stop left an exact loop\n' >&2
    exit 1
fi
kill -0 "$decoy_pid"

# Stop must wait for in-progress PID publication and then stop that generation.
rm -f "$launch_entered"
magicnet_hotspot_watchdog_start &
starting_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
    test ! -f "$launch_entered" || break
    sleep 0.01
done
test -f "$launch_entered"
magicnet_hotspot_watchdog_stop &
stopping_pid=$!
wait "$starting_pid"
wait "$stopping_pid"
test ! -e "$pid_file"
if magicnet_supervisor_orphan_pids hotspot-watchdog >/dev/null; then
    printf 'start/stop race left an exact loop\n' >&2
    exit 1
fi

# ash can optimize away a final subshell. Exercise the actual lock wrapper
# under Android mksh, BusyBox ash and the host shell: the external flock must
# receive its descriptor, and closing the worker's fd must not release the
# parent's guard before the worker returns.
cat >"$fixture/lock-lifetime.sh" <<'EOF'
set -eu
MODDIR="$1"
KAM_HOME="$MODDIR"
set_i18n() { :; }
. "$2"
# Some host BusyBox builds have ash but no flock applet.
magicnet_fswatch_busybox_bin() { return 1; }
magicnet_trusted_flock() { command -v flock; }
magicnet_hotspot_watchdog_start_unlocked() {
    printf 'begin\n' >>"$MODDIR/events"
    sleep 0.2
    printf 'end\n' >>"$MODDIR/events"
}
magicnet_hotspot_watchdog_start &
first=$!
magicnet_hotspot_watchdog_start &
second=$!
wait "$first"
wait "$second"
EOF
printf 'begin\nend\nbegin\nend\n' >"$fixture/expected-events"
for shell in sh busybox mksh; do
    command -v "$shell" >/dev/null || continue
    shell_command=("$shell")
    test "$shell" != busybox || shell_command+=(sh)
    mkdir -p "$fixture/lock-$shell"
    "${shell_command[@]}" "$fixture/lock-lifetime.sh" "$fixture/lock-$shell" \
        "${1:-$ROOT/src/MagicNet/lib/magicnet/supervisors.sh}"
    diff -u "$fixture/expected-events" "$fixture/lock-$shell/events"
done
printf '%s\n' 'hotspot watchdog lifecycle tests passed'
