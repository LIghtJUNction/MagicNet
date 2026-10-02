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

mkdir -p "$MODDIR/bin" "$WORKDIR/evil-bin"
printf '%s\n' '#!/bin/sh' 'exit 91' >"$MODDIR/bin/curl"
printf '%s\n' '#!/bin/sh' 'exit 92' >"$WORKDIR/evil-bin/curl"
chmod 755 "$MODDIR/bin/curl" "$WORKDIR/evil-bin/curl"
PATH="$WORKDIR/evil-bin:$PATH"
export PATH
[ "$(magicnet_trusted_curl)" = "$MODDIR/bin/curl" ] || fail "trusted curl did not prefer the packaged binary"

rm -f "$MODDIR/bin/curl"
# Without a packaged binary, PATH curl remains a last-resort host fixture.
case "$(magicnet_trusted_curl)" in
"$WORKDIR/evil-bin/curl"|*/curl) ;;
*) fail "trusted curl lost the last-resort PATH fallback: $(magicnet_trusted_curl)" ;;
esac

printf '%s\n' 'lib dir override safety test passed'
