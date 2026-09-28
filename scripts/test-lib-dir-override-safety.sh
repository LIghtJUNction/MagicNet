#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-lib-dir.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

MODDIR="$WORKDIR/module"
export MODDIR
mkdir -p "$MODDIR/lib/magicnet" "$WORKDIR/evil/lib/magicnet"
cp "$ROOT/src/MagicNet/lib/magicnet/primitives.sh" "$MODDIR/lib/magicnet/primitives.sh"

# shellcheck disable=SC1091
. "$MODDIR/lib/magicnet/primitives.sh"

[ "$(magicnet_lib_dir)" = "$MODDIR/lib/magicnet" ] || fail "default lib dir is not the module tree"

export MAGICNET_LIB_DIR="$WORKDIR/evil/lib/magicnet"
[ "$(magicnet_lib_dir)" = "$WORKDIR/evil/lib/magicnet" ] ||
    fail "host fixtures must still honor MAGICNET_LIB_DIR"

export MAGICNET_TEST_FORCE_ANDROID=1
[ "$(magicnet_lib_dir)" = "$MODDIR/lib/magicnet" ] ||
    fail "Android runtime honored a foreign MAGICNET_LIB_DIR"

export MAGICNET_LIB_DIR="$MODDIR/lib/magicnet"
[ "$(magicnet_lib_dir)" = "$MODDIR/lib/magicnet" ] ||
    fail "Android runtime rejected the module-owned MAGICNET_LIB_DIR"

unset MAGICNET_LIB_DIR MAGICNET_TEST_FORCE_ANDROID
[ "$(magicnet_lib_dir)" = "$MODDIR/lib/magicnet" ] || fail "cleared override did not restore the module tree"

printf '%s\n' 'lib dir override safety test passed'
