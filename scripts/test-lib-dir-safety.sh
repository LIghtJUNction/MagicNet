#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PRIMITIVES="$ROOT/src/MagicNet/lib/magicnet/primitives.sh"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

MODDIR="$WORKDIR/module"
export MODDIR
mkdir -p "$MODDIR/lib/magicnet/jq"
cp "$PRIMITIVES" "$MODDIR/lib/magicnet/primitives.sh"

# Isolated load of the helper under test.
# shellcheck source=/dev/null
. "$PRIMITIVES"

assert_eq() {
    expected=$1
    actual=$2
    label=$3
    if [ "$actual" != "$expected" ]; then
        printf '%s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# Host fixtures (no /system/bin/getprop) may opt into a workspace library tree.
MAGICNET_LIB_DIR="$WORKDIR/host-lib"
export MAGICNET_LIB_DIR
mkdir -p "$MAGICNET_LIB_DIR"
assert_eq "$MAGICNET_LIB_DIR" "$(magicnet_lib_dir)" "host MAGICNET_LIB_DIR override"

# When the override is absent, the live module tree wins.
unset MAGICNET_LIB_DIR
assert_eq "$MODDIR/lib/magicnet" "$(magicnet_lib_dir)" "module library fallback"

# Production Android detection must ignore a caller-provided redirect even if
# this host cannot create /system/bin/getprop. Re-evaluate the same predicate
# the helper uses so a future rewrite cannot silently drop the guard.
if [ -x /system/bin/getprop ]; then
    MAGICNET_LIB_DIR="$WORKDIR/attacker-lib"
    export MAGICNET_LIB_DIR
    mkdir -p "$MAGICNET_LIB_DIR"
    assert_eq "$MODDIR/lib/magicnet" "$(magicnet_lib_dir)" "android ignores MAGICNET_LIB_DIR"
    unset MAGICNET_LIB_DIR
fi
