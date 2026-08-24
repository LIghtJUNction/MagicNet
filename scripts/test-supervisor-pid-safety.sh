#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
kernel_pid=''
decoy_pid=''
orphan_decoy_pid=''
cleanup() {
  if test -n "$kernel_pid"; then
    kill "$kernel_pid" 2>/dev/null || true
    wait "$kernel_pid" 2>/dev/null || true
  fi
  if test -n "$decoy_pid"; then
    kill "$decoy_pid" 2>/dev/null || true
    wait "$decoy_pid" 2>/dev/null || true
  fi
  if test -n "$orphan_decoy_pid"; then
    kill "$orphan_decoy_pid" 2>/dev/null || true
    wait "$orphan_decoy_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT HUP INT TERM

print() { printf '%s\n' "$*"; }
set_i18n() { :; }
i18n() { printf '%s\n' "$1"; }
t() { cat; }
info() { :; }
warn() { :; }
error() { :; }
success() { :; }
import() { :; }

export MODDIR="$fixture/module"
export KAM_HOME="$MODDIR"
mkdir -p "$MODDIR/.state/watchdog" "$MODDIR/.state/fswatch"
# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"
# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/magicnet/supervisors.sh"

# shellcheck disable=SC1091
. "$ROOT/scripts/test-lib/proc-reader-hook.sh"

# Subscription refresh process identity checks must use the same proc root as
# the scanner.  This makes disappearing-PID races testable and avoids mixing a
# synthetic/isolated proc view with the host's /proc.
refresh_proc_root="$MODDIR/fake-proc"
mkdir -p "$refresh_proc_root/4242"
printf '%s\n' '4242 (magicnet refresh (worker)) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242' \
  >"$refresh_proc_root/4242/stat"
if test "$(MAGICNET_SUB_REFRESH_PROC_ROOT="$refresh_proc_root" magicnet_subscription_refresh_proc_start 4242)" != 4242; then
  printf '%s\n' 'subscription refresh proc start must honor MAGICNET_SUB_REFRESH_PROC_ROOT' >&2
  exit 1
fi
rm -f "$refresh_proc_root/4242/stat"
if MAGICNET_SUB_REFRESH_PROC_ROOT="$refresh_proc_root" magicnet_subscription_refresh_proc_start 4242 >/dev/null 2>&1; then
  printf '%s\n' 'disappeared subscription refresh stat must not be treated as a live owner' >&2
  exit 1
fi

# A stale pidfile must never kill a reused, unrelated PID.
sleep 60 &
decoy_pid=$!
decoy_pid_file="$MODDIR/.state/watchdog/magicnet-kernel.pid"
printf '%s\n' "$decoy_pid" >"$decoy_pid_file"
magicnet_supervisor_stop_pidfile "$decoy_pid_file"
test ! -e "$decoy_pid_file"
kill -0 "$decoy_pid"

# Status must reject the same reused PID without mutating supervisor state;
# startup/stop commands own stale pidfile cleanup.
printf '%s\n' "$decoy_pid" >"$MODDIR/.state/fswatch/magicnet-config.pid"
if magicnet_fswatch_status >/dev/null 2>&1; then
  printf '%s\n' 'unrelated process reported as active fswatch' >&2
  exit 1
fi
test -e "$MODDIR/.state/fswatch/magicnet-config.pid"

# A command launched from the exact managed loop is stoppable.
kernel_loop="$MODDIR/.state/watchdog/magicnet-kernel.loop.sh"
cat >"$kernel_loop" <<'SH'
#!/bin/sh
sleep 60
SH
chmod 700 "$kernel_loop"
sh "$kernel_loop" &
kernel_pid=$!
kernel_pid_file="$MODDIR/.state/watchdog/magicnet-kernel.pid"
printf '%s\n' "$kernel_pid" >"$kernel_pid_file"
magicnet_supervisor_stop_pidfile "$kernel_pid_file"
attempt=0
while test "$attempt" -lt 50; do
  attempt=$((attempt + 1))
  if ! kill -0 "$kernel_pid" 2>/dev/null; then
    break
  fi
  sleep 0.02
done
if kill -0 "$kernel_pid" 2>/dev/null; then
  printf '%s\n' 'managed supervisor PID was not stopped' >&2
  exit 1
fi
wait "$kernel_pid" 2>/dev/null || true
kernel_pid=''

config_loop="$MODDIR/.state/fswatch/magicnet-config.loop.sh"
cat >"$config_loop" <<'SH'
#!/bin/sh
sleep 60
SH
chmod 700 "$config_loop"
sh "$config_loop" &
kernel_pid=$!
config_pid_file="$MODDIR/.state/fswatch/magicnet-config.pid"
printf '%s\n' "$kernel_pid" >"$config_pid_file"
magicnet_supervisor_stop_pidfile "$config_pid_file"
attempt=0
while test "$attempt" -lt 50; do
  attempt=$((attempt + 1))
  if ! kill -0 "$kernel_pid" 2>/dev/null; then
    break
  fi
  sleep 0.02
done
if kill -0 "$kernel_pid" 2>/dev/null; then
  printf '%s\n' 'managed fswatch PID was not stopped' >&2
  exit 1
fi
wait "$kernel_pid" 2>/dev/null || true
kernel_pid=''

# A process whose single argv contains the pkill pattern is not the managed
# config-apply command. Substring-based orphan cleanup must not kill it.
cat >"$MODDIR/cli" <<'SH'
#!/bin/sh
sleep 60
SH
chmod 700 "$MODDIR/cli"
sh -c 'sleep 60 & wait' "$MODDIR/cli config apply decoy" &
orphan_decoy_pid=$!
"$MODDIR/cli" config apply &
kernel_pid=$!
sleep 0.1
magicnet_supervisor_kill_orphans fswatch
if ! kill -0 "$orphan_decoy_pid" 2>/dev/null; then
  printf '%s\n' 'fswatch orphan cleanup killed a substring-only decoy process' >&2
  exit 1
fi
if kill -0 "$kernel_pid" 2>/dev/null; then
  printf '%s\n' 'fswatch orphan cleanup failed to stop an exact managed process' >&2
  exit 1
fi
wait "$kernel_pid" 2>/dev/null || true
kernel_pid=''
kill "$orphan_decoy_pid" 2>/dev/null || true
wait "$orphan_decoy_pid" 2>/dev/null || true
orphan_decoy_pid=''

# The Wi-Fi supervisor uses the same exact-argv rule.
cat >"$MODDIR/cli" <<'SH'
#!/bin/sh
test "${1:-} ${2:-}" = 'wifi watch' || exit 1
sleep 60
SH
chmod 700 "$MODDIR/cli"
sleep 60 &
decoy_pid=$!
if magicnet_wifi_policy_pid_matches "$decoy_pid"; then
  printf '%s\n' 'unrelated process matched Wi-Fi supervisor' >&2
  exit 1
fi
kill "$decoy_pid" 2>/dev/null || true
wait "$decoy_pid" 2>/dev/null || true
decoy_pid=''
"$MODDIR/cli" wifi watch &
kernel_pid=$!
wifi_match_attempt=0
wifi_matched=0
while test "$wifi_match_attempt" -lt 20; do
  if magicnet_wifi_policy_pid_matches "$kernel_pid"; then
    wifi_matched=1
    break
  fi
  wifi_match_attempt=$((wifi_match_attempt + 1))
  sleep 0.05
done
if test "$wifi_matched" -ne 1; then
  printf '%s\n' 'managed Wi-Fi supervisor did not match' >&2
  exit 1
fi
kill "$kernel_pid" 2>/dev/null || true
wait "$kernel_pid" 2>/dev/null || true
kernel_pid=''
unset wifi_match_attempt wifi_matched

# Starting the real Wi-Fi supervisor can race proc cmdline publication.  The
# start path must wait for an exact identity before reporting success; a single
# immediate check makes the supervisor appear intermittently absent and can
# start duplicate watchers on the next lifecycle pass.
(
  wifi_match_attempts=0
  magicnet_module_disabled() { return 1; }
  magicnet_wifi_policy_pid_matches() {
    wifi_match_attempts=$((wifi_match_attempts + 1))
    test "$wifi_match_attempts" -ge 4
  }
  wifi_pid=''
  cleanup_wifi_start_test() {
    if test -n "$wifi_pid"; then
      kill "$wifi_pid" 2>/dev/null || true
      wait "$wifi_pid" 2>/dev/null || true
    fi
    rm -f "$(magicnet_wifi_policy_pid_file)" "$MODDIR/.config/magicnet/wifi-policy.conf"
  }
  trap cleanup_wifi_start_test EXIT HUP INT TERM
  mkdir -p "$MODDIR/.config/magicnet"
  printf '%s\n' 'MAGICNET_WIFI_POLICY_ENABLED=1' >"$MODDIR/.config/magicnet/wifi-policy.conf"
  magicnet_wifi_policy_start
  wifi_pid="$(sed -n '1p' "$(magicnet_wifi_policy_pid_file)")"
  test "$wifi_match_attempts" -ge 4
)

sh -c 'sleep 60 & wait' "$MODDIR/cli wifi watch decoy" &
orphan_decoy_pid=$!
sleep 0.1
magicnet_supervisor_kill_orphans wifi-policy
if ! kill -0 "$orphan_decoy_pid" 2>/dev/null; then
  printf '%s\n' 'Wi-Fi orphan cleanup killed a substring-only decoy process' >&2
  exit 1
fi
kill "$orphan_decoy_pid" 2>/dev/null || true
wait "$orphan_decoy_pid" 2>/dev/null || true
orphan_decoy_pid=''

cat >"$MODDIR/cli" <<'SH'
#!/bin/sh
sleep 60
SH
chmod 700 "$MODDIR/cli"
sh -c 'sleep 60 & wait' "$MODDIR/cli service ensure decoy" &
orphan_decoy_pid=$!
"$MODDIR/cli" service ensure &
kernel_pid=$!
sleep 0.1
magicnet_watchdog_stop
if ! kill -0 "$orphan_decoy_pid" 2>/dev/null; then
  printf '%s\n' 'watchdog cleanup killed a substring-only decoy process' >&2
  exit 1
fi
if kill -0 "$kernel_pid" 2>/dev/null; then
  printf '%s\n' 'watchdog cleanup failed to stop an exact managed process' >&2
  exit 1
fi
wait "$kernel_pid" 2>/dev/null || true
kernel_pid=''
kill "$orphan_decoy_pid" 2>/dev/null || true
wait "$orphan_decoy_pid" 2>/dev/null || true
orphan_decoy_pid=''

printf '%s\n' 'supervisor pid safety test passed'
