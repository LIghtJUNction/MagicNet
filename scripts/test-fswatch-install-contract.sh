#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
watch_name="magicnet-config-test"
wrong_pid=""
decoy_pid=""
argv2_pid=""
empty_argv2_pid=""
nohup_probe_file="$fixture/nohup-ld-library-path"
tr_counter_file="$fixture/tr-counter"
daemon_find_marker="$fixture/daemon-find"
daemon_cksum_marker="$fixture/daemon-cksum"
daemon_sort_marker="$fixture/daemon-sort"
daemon_sleep_marker="$fixture/daemon-sleep"
real_loop_marker="$fixture/fswatch-real-loop-marker"
test_bin="$fixture/bin"
real_cksum="$(command -v cksum)"
real_flock="$(command -v flock)"
real_find="$(command -v find)"
real_mv="$(command -v mv)"
real_nohup="$(command -v nohup)"
real_sh="$(command -v sh)"
real_sleep="$(command -v sleep)"
real_sort="$(command -v sort)"
real_tr="$(command -v tr)"
mkdir -p "$test_bin"

print() { printf '%s\n' "$*"; }
set_i18n() { :; }
i18n() { printf '%s\n' "$1"; }
t() { cat; }
info() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; }
success() { :; }

export TEST_REAL_CKSUM="$real_cksum"
export TEST_REAL_FLOCK="$real_flock"
export TEST_REAL_FIND="$real_find"
export TEST_REAL_MV="$real_mv"
export TEST_REAL_NOHUP="$real_nohup"
export TEST_REAL_SH="$real_sh"
export TEST_REAL_SLEEP="$real_sleep"
export TEST_REAL_SORT="$real_sort"
export TEST_REAL_TR="$real_tr"
export TEST_DAEMON_FIND_MARKER="$daemon_find_marker"
export TEST_DAEMON_CKSUM_MARKER="$daemon_cksum_marker"
export TEST_DAEMON_SORT_MARKER="$daemon_sort_marker"
export TEST_DAEMON_SLEEP_MARKER="$daemon_sleep_marker"
export TEST_NOHUP_PROBE="$nohup_probe_file"
export TEST_TR_COUNTER="$tr_counter_file"

cat >"$test_bin/cksum" <<'EOF'
#!/usr/bin/env bash
if test "${FSWATCH_TEST_DAEMON_CHILD:-0}" = 1; then
  : >"$TEST_DAEMON_CKSUM_MARKER"
fi
if test "${FSWATCH_TEST_SLOW_SNAPSHOT:-0}" = 1; then
  sleep 2
fi
exec "$TEST_REAL_CKSUM" "$@"
EOF

cat >"$test_bin/find" <<'EOF'
#!/usr/bin/env bash
if test "${FSWATCH_TEST_DAEMON_CHILD:-0}" = 1; then
  : >"$TEST_DAEMON_FIND_MARKER"
fi
exec "$TEST_REAL_FIND" "$@"
EOF

cat >"$test_bin/sort" <<'EOF'
#!/usr/bin/env bash
if test "${FSWATCH_TEST_DAEMON_CHILD:-0}" = 1; then
  if test "${LD_LIBRARY_PATH+x}" = x; then
    printf 'daemon sort inherited LD_LIBRARY_PATH\n' >&2
    exit 97
  fi
  : >"$TEST_DAEMON_SORT_MARKER"
fi
exec "$TEST_REAL_SORT" "$@"
EOF

cat >"$test_bin/sleep" <<'EOF'
#!/usr/bin/env bash
if test "${FSWATCH_TEST_DAEMON_CHILD:-0}" = 1; then
  if test "${LD_LIBRARY_PATH+x}" = x; then
    printf 'daemon sleep inherited LD_LIBRARY_PATH\n' >&2
    exit 98
  fi
  if test "${1:-}" = 1; then
    : >"$TEST_DAEMON_SLEEP_MARKER"
  fi
fi
exec "$TEST_REAL_SLEEP" "$@"
EOF

cat >"$test_bin/nohup" <<'EOF'
#!/usr/bin/env bash
if test "${LD_LIBRARY_PATH+x}" = x; then
  printf 'set:%s\n' "$LD_LIBRARY_PATH" >"$TEST_NOHUP_PROBE"
else
  printf 'unset\n' >"$TEST_NOHUP_PROBE"
fi
if test "${FSWATCH_TEST_DELAY_NOHUP:-0}" = 1; then
  sleep 3
fi
exec "$TEST_REAL_NOHUP" "$@"
EOF

cat >"$test_bin/tr" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$TEST_TR_COUNTER"
exec "$TEST_REAL_TR" "$@"
EOF

cat >"$test_bin/mv" <<'EOF'
#!/usr/bin/env bash
destination=''
for argument in "$@"; do
  destination="$argument"
done
if test "${FSWATCH_TEST_FAIL_PID_PUBLISH:-0}" = 1 && test "$destination" = "$TEST_PID_PUBLISH_TARGET"; then
  exit 1
fi
exec "$TEST_REAL_MV" "$@"
EOF

cat >"$test_bin/mock-busybox" <<'EOF'
#!/usr/bin/env bash
applet="${1:-}"
shift || true
case "$applet" in
  flock)
    if test "${1:-}" = --help; then
      exit 0
    fi
    lock_file="$1"
    shift
    exec 10>>"$lock_file"
    "$TEST_REAL_FLOCK" -x 10
    exec "$@"
    ;;
  start-stop-daemon)
    if test "${1:-}" = --help; then
      exit 0
    fi
    pid_file=''
    executable=''
    while test "$#" -gt 0; do
      case "$1" in
        -S|-b|-m) shift ;;
        -p) pid_file="$2"; shift 2 ;;
        -x) executable="$2"; shift 2 ;;
        --) shift; break ;;
        *) exit 2 ;;
      esac
    done
    test -n "$pid_file"
    test -n "$executable"
    if test "$executable" = /system/bin/sh; then
      executable="$TEST_REAL_SH"
    fi
    (
      export FSWATCH_TEST_DAEMON_CHILD=1
      if test "${LD_LIBRARY_PATH+x}" = x; then
        printf 'set:%s\n' "$LD_LIBRARY_PATH" >"$TEST_NOHUP_PROBE"
      else
        printf 'unset\n' >"$TEST_NOHUP_PROBE"
      fi
      if test "${FSWATCH_TEST_DELAY_NOHUP:-0}" = 1; then
        sleep 3
      fi
      exec "$executable" "$@"
    ) &
    daemon_pid=$!
    printf '%s\n' "$daemon_pid" >"$pid_file"
    disown "$daemon_pid" 2>/dev/null || true
    ;;
  *) exit 2 ;;
esac
EOF

chmod +x "$test_bin/cksum" "$test_bin/find" "$test_bin/mv" "$test_bin/nohup" \
  "$test_bin/sleep" "$test_bin/sort" "$test_bin/tr" "$test_bin/mock-busybox"
PATH="$test_bin:$PATH"
export PATH

export MODDIR="$fixture/module"
export MODPATH="$MODDIR"
export KAM_HOME="$MODDIR"
export KAMFW_DIR="$fixture/kamfw"
export KAM_FSWATCH_STATE_DIR="$MODDIR/.state/fswatch"
export KAM_FSWATCH_LOG_FILE="$MODDIR/.log/fswatch.log"
export KAM_FSWATCH_BUSYBOX_BIN="$test_bin/mock-busybox"
export FSWATCH_SOURCE="$ROOT/src/MagicNet/lib/kamfw/fswatch.sh"
mkdir -p "$MODDIR/.config" "$MODDIR/.log" "$KAMFW_DIR"
printf 'fixture\n' >"$MODDIR/.config/value"

cat >"$KAMFW_DIR/.kamfwrc" <<'EOF'
print() { printf '%s\n' "$*"; }
set_i18n() { :; }
i18n() { printf '%s\n' "$1"; }
t() { cat; }
info() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; }
success() { :; }
import() {
  test "$1" = fswatch || return 0
  # shellcheck disable=SC1090
  . "$FSWATCH_SOURCE"
  if test "${FSWATCH_TEST_DAEMON_CHILD:-0}" != 1; then
    fswatch_changed() { return 1; }
  fi
}
EOF

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/kamfw/fswatch.sh"

pid_file="$KAM_FSWATCH_STATE_DIR/$watch_name.pid"
loop_script="$KAM_FSWATCH_STATE_DIR/$watch_name.loop.sh"
lifecycle_lock="$KAM_FSWATCH_STATE_DIR/$watch_name.lifecycle.lock"
export TEST_PID_PUBLISH_TARGET="$pid_file"

count_loop_processes() {
  local pid count=0
  while IFS= read -r pid; do
    test -n "$pid" || continue
    if fswatch_pid_matches_script "$pid" "$loop_script"; then
      count=$((count + 1))
    fi
  done < <(pgrep -f -- "$loop_script" || true)
  printf '%s\n' "$count"
}

wait_for_script_argv2() {
  local pid="$1" expected_argv2="$2" attempt
  local -a argv=()
  for ((attempt = 0; attempt < 200; attempt++)); do
    argv=()
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || true
    if test "${#argv[@]}" -eq 3 && test "${argv[1]}" = "$loop_script" && test "${argv[2]}" = "$expected_argv2"; then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

lifecycle_lock_is_held() (
  exec 8>>"$lifecycle_lock"
  if flock -n 8; then
    flock -u 8
    return 1
  fi
  return 0
)

lifecycle_lock_is_free() (
  exec 8>>"$lifecycle_lock"
  flock -n 8
  flock -u 8
)

cleanup() {
  while IFS= read -r cleanup_pid; do
    test -n "$cleanup_pid" || continue
    if fswatch_pid_matches_script "$cleanup_pid" "$loop_script"; then
      kill "$cleanup_pid" 2>/dev/null || true
    fi
  done < <(pgrep -f -- "$loop_script" || true)
  test -z "$wrong_pid" || kill "$wrong_pid" 2>/dev/null || true
  test -z "$decoy_pid" || kill "$decoy_pid" 2>/dev/null || true
  test -z "$argv2_pid" || kill "$argv2_pid" 2>/dev/null || true
  test -z "$empty_argv2_pid" || kill "$empty_argv2_pid" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT
unset LD_LIBRARY_PATH

# Concurrent starts are serialized and converge on one exact loop process.
fswatch_start "$watch_name" "$MODDIR/.config" 30 ':' &
start_one=$!
fswatch_start "$watch_name" "$MODDIR/.config" 30 ':' &
start_two=$!
wait "$start_one"
wait "$start_two"
test "$(count_loop_processes)" -eq 1
lifecycle_lock_is_free
tracked_pid="$(sed -n '1p' "$pid_file")"
status_pid="$(fswatch_status "$watch_name")"
test "$tracked_pid" = "$status_pid"
fswatch_pid_matches_script "$tracked_pid" "$loop_script"
: >"$tr_counter_file"
_fw_read_d_supported=0 fswatch_pid_matches_script "$tracked_pid" "$loop_script"
test "$(wc -l <"$tr_counter_file")" -eq 1
# shellcheck disable=SC2031 # fswatch_start intentionally runs in a subshell.
test "${LD_LIBRARY_PATH+x}" != x

# read -d capable shells parse one proc cmdline FD without external tr. They
# must distinguish no argv2 from both nonempty and explicitly empty argv2.
sh "$loop_script" extra-argv2 &
argv2_pid=$!
sh "$loop_script" '' &
empty_argv2_pid=$!
wait_for_script_argv2 "$argv2_pid" extra-argv2
wait_for_script_argv2 "$empty_argv2_pid" ''
if fswatch_pid_matches_script "$argv2_pid" "$loop_script"; then
  printf 'nonempty argv2 was accepted as an exact loop process\n' >&2
  exit 1
fi
if fswatch_pid_matches_script "$empty_argv2_pid" "$loop_script"; then
  printf 'empty argv2 was accepted as an exact loop process\n' >&2
  exit 1
fi
if _fw_read_d_supported=0 fswatch_pid_matches_script "$empty_argv2_pid" "$loop_script"; then
  printf 'empty argv2 was accepted by the tr fallback\n' >&2
  exit 1
fi
: >"$tr_counter_file"
fswatch_stop_script_processes "$loop_script" >/dev/null
test ! -s "$tr_counter_file"
if kill -0 "$tracked_pid" 2>/dev/null; then
  printf 'exact loop process survived exact process scan\n' >&2
  exit 1
fi
kill -0 "$argv2_pid"
kill -0 "$empty_argv2_pid"
kill "$argv2_pid" "$empty_argv2_pid"
wait "$argv2_pid" 2>/dev/null || true
wait "$empty_argv2_pid" 2>/dev/null || true
argv2_pid=""
empty_argv2_pid=""

# A repeated start also replaces, rather than duplicates, the loop.
fswatch_start "$watch_name" "$MODDIR/.config" 30 ':'
test "$(count_loop_processes)" -eq 1
fswatch_status "$watch_name" >/dev/null

# The generated child clears host linker state before loading kamfw or tools.
test "$(sed -n '2p' "$loop_script")" = 'unset LD_LIBRARY_PATH'
sh -n "$loop_script"

# An alive but unrelated PID is never accepted or killed as this watcher.
sleep 60 &
wrong_pid=$!
printf '%s\n' "$wrong_pid" >"$pid_file"
if fswatch_status "$watch_name" >/dev/null 2>&1; then
  printf 'unrelated PID was accepted as fswatch owner\n' >&2
  exit 1
fi
kill -0 "$wrong_pid"

# A dead/stale PID is also rejected. The exact orphan remains discoverable and
# stop cleans it without touching the unrelated process.
printf '99999999\n' >"$pid_file"
if fswatch_status "$watch_name" >/dev/null 2>&1; then
  printf 'stale PID was accepted as fswatch owner\n' >&2
  exit 1
fi
fswatch_stop "$watch_name" >/dev/null
test "$(count_loop_processes)" -eq 0
kill -0 "$wrong_pid"

# Invalid names cannot escape the dedicated state directory or make lifecycle
# commands remove a caller-controlled path.
traversal_canary="$MODDIR/traversal-canary.pid"
mkdir -p "${traversal_canary%/*}"
printf 'preserve\n' >"$traversal_canary"
for lifecycle_action in start stop status; do
  if test "$lifecycle_action" = start; then
    if fswatch_start '../../traversal-canary' "$MODDIR/.config" 30 ':' >/dev/null 2>&1; then
      printf 'path-traversal watcher name was accepted by start\n' >&2
      exit 1
    fi
  elif "fswatch_$lifecycle_action" '../../traversal-canary' >/dev/null 2>&1; then
    printf 'path-traversal watcher name was accepted by %s\n' "$lifecycle_action" >&2
    exit 1
  fi
done
test "$(cat "$traversal_canary")" = preserve

# A non-running stop returns failure under errexit, but still releases the
# lifecycle lock it acquired before checking process state.
set +e
(
  set -e
  fswatch_stop "$watch_name" >/dev/null
  printf 'unreachable\n'
)
errexit_stop_rc=$?
set -e
if test "$errexit_stop_rc" -eq 0; then
  printf 'non-running stop unexpectedly succeeded\n' >&2
  exit 1
fi
lifecycle_lock_is_free

# start and stop share one lifecycle lock. Once start owns the lock, stop waits
# for it, then removes the watcher before both calls return.
FSWATCH_TEST_SLOW_SNAPSHOT=1 fswatch_start "$watch_name" "$MODDIR/.config/value" 30 ':' &
concurrent_start_pid=$!
for ((attempt = 0; attempt < 200; attempt++)); do
  lifecycle_lock_is_held && break
  sleep 0.01
done
lifecycle_lock_is_held
fswatch_stop "$watch_name" >/dev/null &
concurrent_stop_pid=$!
wait "$concurrent_start_pid"
wait "$concurrent_stop_pid"
test "$(count_loop_processes)" -eq 0

# Kernel advisory locks are released automatically when a killed holder closes
# its file descriptors; a new acquirer must continue without stale-owner logic.
# shellcheck disable=SC2016
"$KAM_FSWATCH_BUSYBOX_BIN" flock "$lifecycle_lock" sh -c ': >"$1"; sleep 60' kernel-holder "$fixture/kernel-lock-held" &
lock_holder_pid=$!
for ((attempt = 0; attempt < 200; attempt++)); do
  test -e "$fixture/kernel-lock-held" && break
  sleep 0.01
done
test -e "$fixture/kernel-lock-held"
lifecycle_lock_is_held
kill -9 "$lock_holder_pid"
set +e
wait "$lock_holder_pid" 2>/dev/null
set -e
lifecycle_lock_is_free
# shellcheck disable=SC2016
"$KAM_FSWATCH_BUSYBOX_BIN" flock "$lifecycle_lock" sh -c ': >"$1"' kernel-reacquire "$fixture/kernel-lock-reacquired"
test -e "$fixture/kernel-lock-reacquired"

# Host/util-linux uses -o so the locked action never receives the lock FD.
KAM_FSWATCH_BUSYBOX_BIN='' fswatch_start "$watch_name" "$MODDIR/.config" 30 ':'
fswatch_status "$watch_name" >/dev/null
lifecycle_lock_is_free
KAM_FSWATCH_BUSYBOX_BIN='' fswatch_stop "$watch_name" >/dev/null

# LD_LIBRARY_PATH is absent for nohup/sh startup, then restored exactly in the
# caller. The generated loop independently clears it again on line 2 before a
# real snapshot pass reaches find, cksum, sort, and sleep.
rm -f "$nohup_probe_file" "$daemon_find_marker" "$daemon_cksum_marker" \
  "$daemon_sort_marker" "$daemon_sleep_marker" "$real_loop_marker"
LD_LIBRARY_PATH="$fixture/poisoned-linker-path"
export LD_LIBRARY_PATH
fswatch_start "$watch_name" "$MODDIR/.config" 1 "printf 'changed\\n' >'$real_loop_marker'"
test "$LD_LIBRARY_PATH" = "$fixture/poisoned-linker-path"
test "$(cat "$nohup_probe_file")" = unset
test "$(sed -n '2p' "$loop_script")" = 'unset LD_LIBRARY_PATH'
for ((attempt = 0; attempt < 500; attempt++)); do
  test -e "$daemon_sleep_marker" && break
  sleep 0.01
done
test -e "$daemon_find_marker"
test -e "$daemon_cksum_marker"
test -e "$daemon_sort_marker"
test -e "$daemon_sleep_marker"
if test -e "$real_loop_marker"; then
  printf 'unchanged snapshot unexpectedly executed the watcher command\n' >&2
  exit 1
fi
printf 'changed\n' >>"$MODDIR/.config/value"
for ((attempt = 0; attempt < 500; attempt++)); do
  test -e "$real_loop_marker" && break
  sleep 0.01
done
test "$(cat "$real_loop_marker")" = changed
unset LD_LIBRARY_PATH
fswatch_stop "$watch_name" >/dev/null

# Delayed nohup cannot expose a pre-exec PID file. start returns only after the
# child has the exact shell+loop cmdline, so immediate status is reliable.
FSWATCH_TEST_DELAY_NOHUP=1 fswatch_start "$watch_name" "$MODDIR/.config" 30 ':' &
delayed_start_pid=$!
sleep 1
test ! -e "$pid_file"
wait "$delayed_start_pid"
fswatch_status "$watch_name" >/dev/null
test -s "$pid_file"
test "$(count_loop_processes)" -eq 1

# A command that merely carries the complete loop path as a non-script argv is
# neither accepted by status nor killed by stop.
sh -c 'while :; do sleep 60; done' "$loop_script" &
decoy_pid=$!
printf '%s\n' "$decoy_pid" >"$pid_file"
if fswatch_status "$watch_name" >/dev/null 2>&1; then
  printf 'non-script loop-path argv was accepted as fswatch owner\n' >&2
  exit 1
fi
fswatch_stop "$watch_name" >/dev/null
test "$(count_loop_processes)" -eq 0
kill -0 "$decoy_pid"

# A failed atomic pidfile publish must fail start, terminate the just-launched
# exact loop, remove publication state, and release the lifecycle lock.
if FSWATCH_TEST_FAIL_PID_PUBLISH=1 fswatch_start "$watch_name" "$MODDIR/.config" 30 ':' >/dev/null 2>&1; then
  printf 'fswatch start succeeded despite forced pidfile publication failure\n' >&2
  exit 1
fi
test ! -e "$pid_file"
if compgen -G "${pid_file}.publish.*" >/dev/null; then
  printf 'temporary pidfile remained after publication failure\n' >&2
  exit 1
fi
test "$(count_loop_processes)" -eq 0
lifecycle_lock_is_free

expected_url='launch url "https://github.com/LIghtJUNction/MagicNet/blob/main/src/MagicNet/README.md"'
grep -F -x "$expected_url" "$ROOT/src/MagicNet/customize.sh" >/dev/null
grep -F -x '## 使用说明与免责声明' "$ROOT/src/MagicNet/README.md" >/dev/null
grep -F '仅用于合法的自有网络和自有设备测试' "$ROOT/src/MagicNet/README.md" >/dev/null
grep -F '用户需自行确认配置来源、网络策略和实际用途合法合规' "$ROOT/src/MagicNet/README.md" >/dev/null
grep -F 'root 权限和网络栈改动可能造成断网、配置损坏' "$ROOT/src/MagicNet/README.md" >/dev/null
grep -F '本软件按现状提供' "$ROOT/src/MagicNet/README.md" >/dev/null

printf 'fswatch and install documentation contract tests passed\n'
