#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$ROOT/src/MagicNet/lib/magicnet/common.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# common.sh is normally loaded by kamfw, whose import dispatcher is not
# present in this isolated regression test.
import() { :; }
info() { :; }
warn() { :; }

MODDIR="$WORKDIR/module"
export MODDIR
# shellcheck disable=SC1090
. "$COMMON"

TEST_MODE_FILE="$MODDIR/.config/magicnet/transparent-mode.conf"
mkdir -p "$(dirname "$TEST_MODE_FILE")"
printf '%s\n' 'MAGICNET_TRANSPARENT_MODE=proxy' >"$TEST_MODE_FILE"

# A failed replacement must not truncate the last known-good mode file.
mv() {
    return 1
}

if magicnet_transparent_set_mode tun; then
    printf '%s\n' 'transparent mode update unexpectedly succeeded after mv failure' >&2
    exit 1
fi

[ "$(<"$TEST_MODE_FILE")" = 'MAGICNET_TRANSPARENT_MODE=proxy' ] || {
    printf '%s\n' 'transparent mode update corrupted the existing config on failure' >&2
    exit 1
}
[ ! -e "${TEST_MODE_FILE}.tmp.$$" ] || {
    printf '%s\n' 'transparent mode update leaked its temporary file on failure' >&2
    exit 1
}

printf '%s\n' 'transparent mode config safety test passed'
