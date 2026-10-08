#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# core.sh only declares lifecycle helpers, so sourcing it here is side-effect free.
# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/core.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

write_meminfo() {
    printf 'MemTotal:       %s kB\nMemFree:        1 kB\n' "$2" >"$1"
}

assert_limit() {
    _expected="$1"
    _mem_kib="$2"
    _meminfo="$WORK/meminfo"
    write_meminfo "$_meminfo" "$_mem_kib"
    _actual="$(MAGICNET_MEMINFO_PATH="$_meminfo" magicnet_singbox_runtime_memory_limit)"
    [ "$_actual" = "$_expected" ] ||
        fail "MemTotal=${_mem_kib}KiB expected $_expected, got $_actual"
    unset _expected _mem_kib _meminfo _actual
}

unset GOMEMLIMIT || true
assert_limit 192MiB 2097152
assert_limit 256MiB 4194304
assert_limit 384MiB 8388608
assert_limit 512MiB 16777216

# A broken/unavailable meminfo source must still produce a conservative valid
# Go runtime limit instead of launching the core without a budget.
[ "$(MAGICNET_MEMINFO_PATH="$WORK/missing" magicnet_singbox_runtime_memory_limit)" = 384MiB ] ||
    fail 'missing meminfo did not use the conservative fallback'

# An operator-supplied standard Go runtime limit always wins over auto sizing.
[ "$(GOMEMLIMIT=768MiB MAGICNET_MEMINFO_PATH="$WORK/missing" magicnet_singbox_runtime_memory_limit)" = 768MiB ] ||
    fail 'explicit GOMEMLIMIT was not preserved'
[ "$(GOMEMLIMIT=off MAGICNET_MEMINFO_PATH="$WORK/missing" magicnet_singbox_runtime_memory_limit)" = off ] ||
    fail 'GOMEMLIMIT=off was not preserved'

# Android must not honor a caller-injected meminfo fixture. Host tests still
# use MAGICNET_MEMINFO_PATH above because they do not force the Android path.
write_meminfo "$WORK/tiny-meminfo" 2097152
[ "$(MAGICNET_TEST_FORCE_ANDROID=1 MAGICNET_MEMINFO_PATH="$WORK/tiny-meminfo" magicnet_singbox_runtime_memory_limit)" != 192MiB ] ||
    fail 'Android runtime honored a caller-injected meminfo path'
[ "$(MAGICNET_TEST_FORCE_ANDROID=1 MAGICNET_TEST_ALLOW_PROC_ROOT=1 MAGICNET_MEMINFO_PATH="$WORK/tiny-meminfo" magicnet_singbox_runtime_memory_limit)" = 192MiB ] ||
    fail 'explicit Android meminfo fixture escape hatch was ignored'

# Keep the launcher integration from regressing into a computed-but-unused
# budget. The assignment is scoped to singbox_start, so it cannot leak to the
# Rust CLI or other module helpers.
grep -F "GOMEMLIMIT=\"\$_singbox_gomemlimit\"" "$ROOT/src/MagicNet/lib/magicnet/core.sh" >/dev/null ||
    fail 'sing-box launcher does not receive the runtime memory budget'

printf '%s\n' 'sing-box runtime memory tests passed'
