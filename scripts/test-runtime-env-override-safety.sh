#!/usr/bin/env bash
# Android must ignore inherited library, /proc, and cgroup environment
# overrides. Host fixtures may still inject those paths.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-runtime-env.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

MODDIR="$WORK/module"
mkdir -p "$MODDIR/lib/magicnet"
cp "$ROOT/src/MagicNet/lib/magicnet/primitives.sh" "$MODDIR/lib/magicnet/primitives.sh"
export MODDIR

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"

fail() {
    printf 'runtime env override safety failed: %s\n' "$*" >&2
    exit 1
}

injected_lib="$WORK/injected-lib"
injected_proc="$WORK/injected-proc"
mkdir -p "$injected_lib" "$injected_proc"

MAGICNET_LIB_DIR="$injected_lib"
MAGICNET_PROC_ROOT="$injected_proc"
MAGICNET_PROCESS_CGROUP_ROOTS="$WORK/cgroup"
export MAGICNET_LIB_DIR MAGICNET_PROC_ROOT MAGICNET_PROCESS_CGROUP_ROOTS

host_lib="$(magicnet_lib_dir)"
host_proc="$(magicnet_runtime_proc_root "" "$MAGICNET_PROC_ROOT")"
[[ "$host_lib" == "$injected_lib" ]] || fail "host MAGICNET_LIB_DIR was ignored: $host_lib"
[[ "$host_proc" == "$injected_proc" ]] || fail "host MAGICNET_PROC_ROOT was ignored: $host_proc"

(
    magicnet_honor_runtime_env_overrides() { return 1; }
    android_lib="$(magicnet_lib_dir)"
    android_proc="$(magicnet_runtime_proc_root "" "$MAGICNET_PROC_ROOT")"
    android_explicit="$(magicnet_runtime_proc_root "$injected_proc" "$MAGICNET_PROC_ROOT")"
    [[ "$android_lib" == "$MODDIR/lib/magicnet" ]] ||
        fail "Android MAGICNET_LIB_DIR was honored: $android_lib"
    [[ "$android_proc" == /proc ]] ||
        fail "Android MAGICNET_PROC_ROOT was honored: $android_proc"
    [[ "$android_explicit" == "$injected_proc" ]] ||
        fail "explicit proc root was dropped on Android: $android_explicit"
)

printf 'runtime env override safety tests passed\n'
