#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-config-lock.XXXXXX")"
stopped_pid=''
race_pid=''
cleanup() {
    if [ -n "$race_pid" ]; then
        : >"$fixture/resume"
        wait "$race_pid" 2>/dev/null || true
    fi
    if [ -n "$stopped_pid" ]; then
        kill -KILL "$stopped_pid" 2>/dev/null || true
        wait "$stopped_pid" 2>/dev/null || true
    fi
    rm -rf "$fixture"
}
trap cleanup EXIT

export MODDIR="$fixture/module"
mkdir -p "$MODDIR/.state/config.lock"
import() { :; }
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"

# A stale signal trap from another PID must not remove the current owner.
printf '%s\n' '999999:1' >"$MODDIR/.state/config.lock/pid"
magicnet_config_lock_release
test -d "$MODDIR/.state/config.lock"

# The current owner can release its own marker, and the directory is removed
# only after the marker is gone (never with recursive deletion).
start="$(awk '{print $22}' /proc/$$/stat)"
printf '%s:%s\n' "$$" "$start" >"$MODDIR/.state/config.lock/pid"
magicnet_config_lock_release
test ! -e "$MODDIR/.state/config.lock"

# A stale reclaimer must not pass its ownership check, pause, then remove a
# different writer's directory. Pause at the actual unlink boundary rather
# than depending on scheduler timing to reproduce the old check/delete race.
mkdir -p "$MODDIR/.state/config.lock"
printf '999999:1\n' >"$MODDIR/.state/config.lock/pid"
(
    rm() {
        if [ "${2:-}" = "$MODDIR/.state/config.lock/pid" ]; then
            : >"$fixture/paused"
            while [ ! -e "$fixture/resume" ]; do sleep 0.01; done
        fi
        command rm "$@"
    }
    magicnet_config_lock_reclaim '999999:1'
) &
race_pid=$!
for _ in {1..100}; do
    [ ! -e "$fixture/paused" ] || break
    sleep 0.01
done
test -e "$fixture/paused"
if MAGICNET_CONFIG_LOCK_TIMEOUT=0 magicnet_config_lock_acquire; then race_rc=0; else race_rc=$?; fi
: >"$fixture/resume"
wait "$race_pid"
race_pid=''
[ "$race_rc" -ne 0 ] || {
    printf 'config lock acquisition overlapped a validated stale reclaimer\n' >&2
    exit 1
}
magicnet_config_lock_acquire
magicnet_config_lock_release
rm -f "$fixture/paused" "$fixture/resume"

# The mkdir-to-marker window belongs to the publisher, even when the empty
# directory grace period is zero. A contender must not remove its directory.
(
    printf() {
        case "${2:-}" in
        "$$" | "$$:"*)
            : >"$fixture/paused"
            while [ ! -e "$fixture/resume" ]; do sleep 0.01; done
            ;;
        esac
        command printf "$@"
    }
    magicnet_config_lock_acquire
) &
race_pid=$!
for _ in {1..100}; do
    [ ! -e "$fixture/paused" ] || break
    sleep 0.01
done
test -e "$fixture/paused"
if MAGICNET_CONFIG_LOCK_TIMEOUT=0 MAGICNET_CONFIG_LOCK_NO_PID_TIMEOUT=0 magicnet_config_lock_acquire; then race_rc=0; else race_rc=$?; fi
: >"$fixture/resume"
wait "$race_pid"
race_pid=''
[ "$race_rc" -ne 0 ] || {
    printf 'config lock acquisition stole an unpublished live directory\n' >&2
    exit 1
}
magicnet_config_lock_release
rm -f "$fixture/paused" "$fixture/resume"

# The guard must be gone before protected work can spawn long-lived children.
assert_metadata_guard_released() {
    flock -n "$(magicnet_config_lock_dir).guard" true
}
magicnet_with_config_lock assert_metadata_guard_released

# Missing flock cannot authorize unguarded mutation. A denied release remains
# a failure, preserves the marker, and propagates through the public wrapper.
(
    magicnet_fswatch_busybox_bin() { return 1; }
    magicnet_trusted_flock() { return 1; }
    if MAGICNET_CONFIG_LOCK_TIMEOUT=0 magicnet_config_lock_acquire; then exit 1; fi
    test ! -e "$MODDIR/.state/config.lock"
)
(
    rm() {
        [ "${2:-}" != "$MODDIR/.state/config.lock/pid" ] || return 1
        command rm "$@"
    }
    if magicnet_with_config_lock true; then
        printf 'config operation hid failed lock release\n' >&2
        exit 1
    fi
    test -s "$MODDIR/.state/config.lock/pid"
)
magicnet_config_lock_release

# Malformed metadata must fail before opening a FIFO or following a symlink.
# A blocked reader would otherwise hold the metadata flock beyond the budget.
for marker_kind in fifo symlink directory; do
    mkdir -p "$MODDIR/.state/config.lock"
    marker="$MODDIR/.state/config.lock/pid"
    case "$marker_kind" in
    fifo) mkfifo "$marker" ;;
    symlink) printf '999999:1\n' >"$fixture/foreign-owner"; ln -s "$fixture/foreign-owner" "$marker" ;;
    directory) mkdir "$marker" ;;
    esac
    for operation in acquire reclaim release; do
        if timeout 2 bash -s -- "$ROOT" "$operation" <<'CHILD'
import() { :; }
. "$1/src/MagicNet/lib/magicnet/common.sh"
case "$2" in
acquire) MAGICNET_CONFIG_LOCK_TIMEOUT=0 MAGICNET_CONFIG_LOCK_NO_PID_TIMEOUT=0 magicnet_config_lock_acquire ;;
reclaim) magicnet_config_lock_reclaim '999999:1' ;;
release) magicnet_config_lock_release ;;
esac
CHILD
        then actual=0; else actual=$?; fi
        case "$actual" in 1 | 2) ;; *)
            printf '%s did not promptly refuse %s owner metadata (exit=%s)\n' "$operation" "$marker_kind" "$actual" >&2
            exit 1 ;;
        esac
        test -e "$marker" || test -L "$marker"
    done
    rm -rf "$MODDIR/.state/config.lock"

    # Guard creation itself must not block opening malformed existing paths.
    marker="$MODDIR/.state/config.lock.guard"
    rm -f "$marker"
    case "$marker_kind" in
    fifo) mkfifo "$marker" ;;
    symlink) ln -s "$fixture/foreign-owner" "$marker" ;;
    directory) mkdir "$marker" ;;
    esac
    if timeout 2 bash -s -- "$ROOT" <<'CHILD'
import() { :; }
. "$1/src/MagicNet/lib/magicnet/common.sh"
MAGICNET_CONFIG_LOCK_TIMEOUT=0 magicnet_config_lock_acquire
CHILD
    then actual=0; else actual=$?; fi
    case "$actual" in 1 | 2) ;; *)
        printf 'acquire did not promptly refuse %s guard (exit=%s)\n' "$marker_kind" "$actual" >&2
        exit 1 ;;
    esac
    test -e "$marker" || test -L "$marker"
    test ! -e "$MODDIR/.state/config.lock"
    rm -rf "$marker"
done
test "$(cat "$fixture/foreign-owner")" = '999999:1'

# A nonempty corrupt marker is unknown ownership, not evidence of a dead
# process. Even zero timeout/grace must leave every byte available for repair.
for corrupt_owner in garbage ':1' 0 '0:1' '00:1' '999999:' '999999:bad' \
    '999999:1:extra' '99999999999999999999999:1' "$$:100000000000000000000" \
    $'999999:1\nunexpected' "$(printf '%129s' x)"; do
    mkdir -p "$MODDIR/.state/config.lock"
    printf '%s\n' "$corrupt_owner" >"$MODDIR/.state/config.lock/pid"
    cp "$MODDIR/.state/config.lock/pid" "$fixture/corrupt-owner.expected"
    if MAGICNET_CONFIG_LOCK_TIMEOUT=0 MAGICNET_CONFIG_LOCK_NO_PID_TIMEOUT=0 \
        magicnet_config_lock_acquire >/dev/null 2>&1; then
        printf 'config acquisition reclaimed corrupt nonempty ownership\n' >&2
        exit 1
    fi
    if magicnet_config_lock_owner_matches "$corrupt_owner"; then actual=0; else actual=$?; fi
    test "$actual" -eq 2
    if magicnet_config_lock_reclaim "$corrupt_owner"; then
        printf 'direct config reclamation accepted corrupt ownership\n' >&2
        exit 1
    fi
    cmp "$fixture/corrupt-owner.expected" "$MODDIR/.state/config.lock/pid"
    rm -f "$MODDIR/.state/config.lock/pid"
    rmdir "$MODDIR/.state/config.lock"
done

# A paused owner is still alive. The parent-death watchdog deliberately
# resumes stopped workers to run rollback; stealing their lock would let
# rollback race with a new writer. Ordinary SIGSTOP has the same proc state.
sleep 30 &
stopped_pid=$!
kill -STOP "$stopped_pid"
stopped_start="$(awk '{print $22}' "/proc/$stopped_pid/stat")"
mkdir -p "$MODDIR/.state/config.lock"
printf '%s:%s\n' "$stopped_pid" "$stopped_start" >"$MODDIR/.state/config.lock/pid"
for _ in {1..50}; do
    [ "$(awk '{print $3}' "/proc/$stopped_pid/stat")" = T ] && break
    sleep 0.01
done
test "$(awk '{print $3}' "/proc/$stopped_pid/stat")" = T
if MAGICNET_CONFIG_LOCK_TIMEOUT=0 magicnet_config_lock_acquire; then
    printf '%s\n' 'config lock acquisition stole a paused live owner' >&2
    exit 1
fi
test "$(cat "$MODDIR/.state/config.lock/pid")" = "$stopped_pid:$stopped_start"
magicnet_config_lock_owner_matches "$stopped_pid:$stopped_start"
kill -CONT "$stopped_pid"
magicnet_config_lock_owner_matches "$stopped_pid:$stopped_start"
kill -KILL "$stopped_pid" 2>/dev/null || true
wait "$stopped_pid" 2>/dev/null || true
stopped_pid=''
magicnet_config_lock_acquire
magicnet_config_lock_release
test ! -e "$MODDIR/.state/config.lock"

# Locking must not replace a caller's transaction/signal cleanup handlers.
# The subscription updater relies on its TERM trap to roll back its journal.
trap 'exit 143' TERM
caller_term_trap="$(trap -p TERM)"
assert_caller_trap_preserved() {
    test "$(trap -p TERM)" = "$caller_term_trap"
}
magicnet_with_config_lock assert_caller_trap_preserved
test "$(trap -p TERM)" = "$caller_term_trap"
trap - TERM

# Stale and marker-less owners are reclaimed without recursive deletion.
mkdir -p "$MODDIR/.state/config.lock"
printf '%s\n' '999999:1' >"$MODDIR/.state/config.lock/pid"
magicnet_config_lock_acquire
test "$(cut -d: -f1 "$MODDIR/.state/config.lock/pid")" = "$$"
magicnet_config_lock_release

mkdir -p "$MODDIR/.state/config.lock"
MAGICNET_CONFIG_LOCK_NO_PID_TIMEOUT=1 magicnet_config_lock_acquire
test "$(cut -d: -f1 "$MODDIR/.state/config.lock/pid")" = "$$"
magicnet_config_lock_release

# An unreadable/blocked proc identity is indeterminate, not proof that a live
# owner died. Acquisition must time out without stealing or rewriting it.
mkdir -p "$MODDIR/.state/config.lock"
printf '%s:%s\n' "$$" "$start" >"$MODDIR/.state/config.lock/pid"
magicnet_proc_reader_test_hook() {
    test "$1" != stat || return 2
    return 1
}
set +e
MAGICNET_CONFIG_LOCK_TIMEOUT=1 magicnet_config_lock_acquire
indeterminate_rc=$?
set -e
unset -f magicnet_proc_reader_test_hook
[ "$indeterminate_rc" -ne 0 ]
test "$(cat "$MODDIR/.state/config.lock/pid")" = "$$:$start"
rm -f "$MODDIR/.state/config.lock/pid"
rmdir "$MODDIR/.state/config.lock"

# A starttime mismatch is definite PID reuse and can be reclaimed after the
# marker is rechecked immediately before removal.
mkdir -p "$MODDIR/.state/config.lock"
printf '%s:%s\n' "$$" '1' >"$MODDIR/.state/config.lock/pid"
magicnet_config_lock_acquire
test "$(cut -d: -f1 "$MODDIR/.state/config.lock/pid")" = "$$"
magicnet_config_lock_release

# A marker write failure must not leave an empty directory that blocks every
# later config update until the timeout-based reclamation path runs.
printf() {
    case "${2:-}" in
    "$$" | "$$:"*) return 1 ;;
    esac
    command printf "$@"
}
set +e
magicnet_config_lock_acquire
acquire_rc=$?
set -e
unset -f printf
[ "$acquire_rc" -ne 0 ] || {
    printf '%s\n' 'config lock acquisition succeeded after marker write failure' >&2
    exit 1
}
[ ! -e "$MODDIR/.state/config.lock" ] || {
    printf '%s\n' 'failed config lock acquisition leaked its directory' >&2
    exit 1
}

printf '%s\n' 'config lock safety test passed'

# Reclaiming a marker-less directory may fail (foreign entry/permissions).
# Regression: an unconditional continue here previously bypassed timeout
# accounting and could hold a detached service start forever.
mkdir -p "$MODDIR/.state/config.lock"
printf 'do not delete\n' >"$MODDIR/.state/config.lock/foreign"
set +e
timeout 4 bash -s -- "$ROOT" <<'CHILD'
  import() { :; }
  . "$1/src/MagicNet/lib/magicnet/common.sh"
  MAGICNET_CONFIG_LOCK_TIMEOUT=1 MAGICNET_CONFIG_LOCK_NO_PID_TIMEOUT=1 magicnet_config_lock_acquire
CHILD
foreign_rc=$?
set -e
test "$foreign_rc" -eq 1
test "$(cat "$MODDIR/.state/config.lock/foreign")" = 'do not delete'
test ! -e "$MODDIR/.state/config.lock/pid"
printf 'Marker-less failed reclaim remains bounded and preserves foreign files\n'
