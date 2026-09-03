#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-runtime-env.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

MODDIR="$WORK/module"
mkdir -p "$MODDIR/lib/magicnet" "$MODDIR/.state/sing-box" "$WORK/evil" "$WORK/proc/123" "$WORK/cgroup-v2"
printf '# fixture\n' >"$MODDIR/lib/magicnet/primitives.sh"
: >"$WORK/cgroup-v2/cgroup.procs"
printf '0::/apps/uid_10346/pid_27334\n' >"$WORK/proc/123/cgroup"

# ROOT is computed at runtime from this test's location.
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"

MAGICNET_LIB_DIR="$WORK/evil"
MAGICNET_PROC_ROOT="$WORK/proc"
MAGICNET_PROC_QUERY_DIR="$WORK/evil"
MAGICNET_SINGBOX_PROC_ROOT="$WORK/proc"
MAGICNET_SUB_REFRESH_PROC_ROOT="$WORK/proc"
MAGICNET_PROCESS_CGROUP_ROOTS="$WORK/cgroup-v2"
export MAGICNET_LIB_DIR MAGICNET_PROC_ROOT MAGICNET_PROC_QUERY_DIR
export MAGICNET_SINGBOX_PROC_ROOT MAGICNET_SUB_REFRESH_PROC_ROOT
export MAGICNET_PROCESS_CGROUP_ROOTS

if test "$(magicnet_lib_dir)" != "$WORK/evil"; then
    printf 'host runtime must honor MAGICNET_LIB_DIR\n' >&2
    exit 1
fi
if test "$(magicnet_resolved_proc_root "")" != "$WORK/proc"; then
    printf 'host runtime must honor MAGICNET_PROC_ROOT\n' >&2
    exit 1
fi
if test "$(magicnet_resolved_proc_root "$MAGICNET_SINGBOX_PROC_ROOT")" != "$WORK/proc"; then
    printf 'host runtime must honor MAGICNET_SINGBOX_PROC_ROOT\n' >&2
    exit 1
fi
if test "$(magicnet_resolved_proc_root "$MAGICNET_SUB_REFRESH_PROC_ROOT")" != "$WORK/proc"; then
    printf 'host runtime must honor MAGICNET_SUB_REFRESH_PROC_ROOT\n' >&2
    exit 1
fi
host_query_file=$(magicnet_proc_query_temp_create) || {
    printf 'host runtime failed to create a proc query file\n' >&2
    exit 1
}
case "$host_query_file" in
"$WORK/evil"/.proc-query.*) ;;
*)
    printf 'host runtime must honor MAGICNET_PROC_QUERY_DIR\n' >&2
    exit 1
    ;;
esac
rm -f "$host_query_file"

magicnet_detach_pid_from_app_cgroup 123
if ! grep -qx '123' "$WORK/cgroup-v2/cgroup.procs"; then
    printf 'host runtime must honor MAGICNET_PROCESS_CGROUP_ROOTS\n' >&2
    exit 1
fi
: >"$WORK/cgroup-v2/cgroup.procs"

magicnet_env_override_allowed_test_hook() {
    return 1
}

if test "$(magicnet_lib_dir)" != "$MODDIR/lib/magicnet"; then
    printf 'Android runtime must ignore MAGICNET_LIB_DIR\n' >&2
    exit 1
fi
if test "$(magicnet_resolved_proc_root "")" != /proc; then
    printf 'Android runtime must ignore MAGICNET_PROC_ROOT\n' >&2
    exit 1
fi
if test "$(magicnet_resolved_proc_root "$MAGICNET_SINGBOX_PROC_ROOT")" != /proc; then
    printf 'Android runtime must ignore MAGICNET_SINGBOX_PROC_ROOT\n' >&2
    exit 1
fi
if test "$(magicnet_resolved_proc_root "$MAGICNET_SUB_REFRESH_PROC_ROOT")" != /proc; then
    printf 'Android runtime must ignore MAGICNET_SUB_REFRESH_PROC_ROOT\n' >&2
    exit 1
fi
android_query_file=$(magicnet_proc_query_temp_create) || {
    printf 'Android runtime failed to create a module-owned proc query file\n' >&2
    exit 1
}
case "$android_query_file" in
"$MODDIR/.state/sing-box"/.proc-query.*) ;;
*)
    printf 'Android runtime must ignore MAGICNET_PROC_QUERY_DIR\n' >&2
    exit 1
    ;;
esac
rm -f "$android_query_file"

# The fixture PID and cgroup root exist only under WORK. Android must keep
# using /proc and the default cgroup mounts, so this file stays empty.
magicnet_detach_pid_from_app_cgroup 123 || true
if [ -s "$WORK/cgroup-v2/cgroup.procs" ]; then
    printf 'Android runtime wrote into a caller-supplied cgroup root\n' >&2
    exit 1
fi

printf 'runtime env override safety test passed\n'
