#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-install-backup-marker.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
    printf 'install backup marker test failed: %s\n' "$*" >&2
    exit 1
}

# Source only the marker helper. customize.sh is an installer, not a library.
helper="$(sed -n '/^magicnet_install_backup_marker_valid()/,/^}/p' "$ROOT/src/MagicNet/customize.sh")"
[[ -n "$helper" ]] || fail "could not extract magicnet_install_backup_marker_valid"
# The helper must not mention external cat; restricted installer PATH omits it.
grep -F 'cat ' <<<"$helper" && fail "backup marker helper still depends on external cat"

# Host-only evaluation of the extracted POSIX helper.
# shellcheck disable=SC1090
eval "$helper"

assert_valid() {
    local path="$1"
    local label="$2"
    if ! (
        PATH="$WORK/empty-path"
        export PATH
        command -v cat >/dev/null 2>&1 && fail "cat must be unavailable in the restricted PATH"
        magicnet_install_backup_marker_valid "$path"
    ); then
        fail "$label should be accepted without external cat"
    fi
}

assert_invalid() {
    local path="$1"
    local label="$2"
    if (
        PATH="$WORK/empty-path"
        export PATH
        magicnet_install_backup_marker_valid "$path"
    ); then
        fail "$label should be rejected"
    fi
}

mkdir -p "$WORK/empty-path" "$WORK/dir"

printf '%s\n' 'magicnet-install-backup-v1' >"$WORK/exact"
assert_valid "$WORK/exact" "exact marker with trailing newline"

printf '%s' 'magicnet-install-backup-v1' >"$WORK/no-newline"
assert_valid "$WORK/no-newline" "exact marker without trailing newline"

printf '%s\n%s\n' 'magicnet-install-backup-v1' 'extra' >"$WORK/extra"
assert_invalid "$WORK/extra" "marker with a trailing extra line"

printf '%s\n' 'not-a-magicnet-backup' >"$WORK/wrong"
assert_invalid "$WORK/wrong" "wrong marker text"

: >"$WORK/empty"
assert_invalid "$WORK/empty" "empty marker file"

ln -s "$WORK/exact" "$WORK/symlink"
assert_invalid "$WORK/symlink" "symlink marker"

assert_invalid "$WORK/missing" "missing marker"

# Module-owned primitives win over an inherited MAGICNET_LIB_DIR.
mkdir -p "$WORK/module/lib/magicnet" "$WORK/attacker/lib/magicnet"
printf '%s\n' 'module-owned' >"$WORK/module/lib/magicnet/primitives.sh"
printf '%s\n' 'attacker' >"$WORK/attacker/lib/magicnet/primitives.sh"
lib_dir="$(
    MODDIR="$WORK/module"
    MAGICNET_LIB_DIR="$WORK/attacker/lib/magicnet"
    export MODDIR MAGICNET_LIB_DIR
    # shellcheck disable=SC1091
    . "$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
    magicnet_lib_dir
)"
[[ "$lib_dir" == "$WORK/module/lib/magicnet" ]] \
    || fail "magicnet_lib_dir honored inherited MAGICNET_LIB_DIR over the module tree"

printf 'install backup marker and runtime library path tests passed\n'
