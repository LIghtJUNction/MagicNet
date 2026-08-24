#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-cgroup-detach.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

MODDIR="$WORK/module"
MAGICNET_PROC_ROOT="$WORK/proc"
MAGICNET_PROCESS_CGROUP_ROOTS="$WORK/cgroup-v2:$WORK/memcg/apps:$WORK/cpuset"
export MODDIR MAGICNET_PROC_ROOT MAGICNET_PROCESS_CGROUP_ROOTS

mkdir -p \
    "$MODDIR/bin" \
    "$MODDIR/.state/sing-box" \
    "$MAGICNET_PROC_ROOT/123" \
    "$MAGICNET_PROC_ROOT/456" \
    "$MAGICNET_PROC_ROOT/789" \
    "$WORK/cgroup-v2" \
    "$WORK/memcg/apps" \
    "$WORK/cpuset" \
    "$WORK/package-only"
: >"$WORK/cgroup-v2/cgroup.procs"
: >"$WORK/memcg/apps/tasks"
: >"$WORK/cpuset/cgroup.procs"
: >"$WORK/package-only/tasks"
printf '4:memory:/apps/com.example.manager\n0::/apps/uid_10346/pid_27334\n' >"$MAGICNET_PROC_ROOT/123/cgroup"
printf '%s\0' "$MODDIR/bin/sing-box" >"$MAGICNET_PROC_ROOT/123/cmdline"
ln -s "$MODDIR/bin/sing-box" "$MAGICNET_PROC_ROOT/123/exe"
printf '123\n' >"$MODDIR/.state/sing-box/pid"

printf '0::/apps/uid_10346/pid_27334\n' >"$MAGICNET_PROC_ROOT/456/cgroup"
printf '%s\0' '/system/bin/unrelated' >"$MAGICNET_PROC_ROOT/456/cmdline"
ln -s /system/bin/sh "$MAGICNET_PROC_ROOT/456/exe"
printf '456\n' >"$MODDIR/.state/unrelated.pid"
printf '4:memory:/apps/me.weishu.kernelsu\n' >"$MAGICNET_PROC_ROOT/789/cgroup"

# ROOT is computed at runtime from this test's location.
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
magicnet_detach_pid_from_app_cgroup 123
for target in "$WORK/cgroup-v2/cgroup.procs" "$WORK/memcg/apps/tasks" "$WORK/cpuset/cgroup.procs"; do
    grep -qx '123' "$target"
    : >"$target"
done

# A package-named v1 app cgroup must be sufficient on its own. This is the
# layout observed from KernelSU even when no /apps/uid_* line is present.
MAGICNET_PROCESS_CGROUP_ROOTS="$WORK/package-only"
export MAGICNET_PROCESS_CGROUP_ROOTS
magicnet_detach_pid_from_app_cgroup 789
grep -qx '789' "$WORK/package-only/tasks"

failed_root="$WORK/failed-cgroup"
mkdir -p "$failed_root"
MAGICNET_PROCESS_CGROUP_ROOTS="$WORK/cgroup-v2:$failed_root"
export MAGICNET_PROCESS_CGROUP_ROOTS
if magicnet_detach_pid_from_app_cgroup 123; then
    printf 'partial app-cgroup detachment was reported as success\n' >&2
    exit 1
fi
grep -qx '123' "$WORK/cgroup-v2/cgroup.procs"
: >"$WORK/cgroup-v2/cgroup.procs"
printf '0::/apps\n' >"$MAGICNET_PROC_ROOT/456/cgroup"
magicnet_detach_pid_from_app_cgroup 456
for target in "$WORK/cgroup-v2/cgroup.procs" "$WORK/memcg/apps/tasks" "$WORK/cpuset/cgroup.procs"; do
    if [ -s "$target" ]; then
        printf 'stable PID was unnecessarily moved through %s\n' "$target" >&2
        exit 1
    fi
done

printf 'process cgroup detach test passed\n'
