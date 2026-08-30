#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMMON="$ROOT/src/MagicNet/lib/magicnet/common.sh"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

MODDIR="$WORKDIR/module"
export MODDIR
mkdir -p "$MODDIR/.config/magicnet"
import() { :; }

# common.sh resolves its other imports lazily; this contract only exercises the
# transparent-mode parser and its atomic publisher.
# shellcheck source=/dev/null
. "$COMMON"

MODE_FILE="$MODDIR/.config/magicnet/transparent-mode.conf"

assert_mode() {
    expected=$1
    actual=$(magicnet_transparent_mode)
    if [ "$actual" != "$expected" ]; then
        printf 'expected transparent mode %s, got %s\n' "$expected" "$actual" >&2
        exit 1
    fi
}

assert_rejected_without_change() {
    requested=$1
    before=$(cksum "$MODE_FILE")
    if magicnet_transparent_set_mode "$requested"; then
        printf 'invalid transparent mode was accepted: %s\n' "$requested" >&2
        exit 1
    fi
    after=$(cksum "$MODE_FILE")
    if [ "$after" != "$before" ]; then
        printf 'rejected transparent mode changed the active file: %s\n' "$requested" >&2
        exit 1
    fi
}

# No persisted selection is the backwards-compatible TUN default.
rm -f "$MODE_FILE"
assert_mode tun

# Both explicit modes are accepted and published with private permissions.
magicnet_transparent_set_mode tun
assert_mode tun
[ "$(stat -c '%a' "$MODE_FILE")" = 600 ]
magicnet_transparent_set_mode ebpf
assert_mode ebpf
[ "$(stat -c '%a' "$MODE_FILE")" = 600 ]

# Unknown requests, including the historical implicit/automatic spellings,
# must fail without touching the previous valid selection.
for invalid in unknown auto hybrid proxy external external-tun ''; do
    assert_rejected_without_change "$invalid"
done
assert_mode ebpf

# A persisted file must contain exactly one known mode assignment. Unknown
# values and duplicate assignments are rejected rather than silently falling
# back or selecting whichever line happened to be last.
for invalid_file in \
    'MAGICNET_TRANSPARENT_MODE=unknown' \
    'MAGICNET_TRANSPARENT_MODE=tun
MAGICNET_UNEXPECTED_ASSIGNMENT=1' \
    'MAGICNET_TRANSPARENT_MODE=tun
MAGICNET_TRANSPARENT_MODE=ebpf'; do
    printf '%s\n' "$invalid_file" >"$MODE_FILE"
    before=$(cksum "$MODE_FILE")
    if magicnet_transparent_mode >/dev/null 2>&1; then
        printf 'invalid transparent mode file was accepted:\n%s\n' "$invalid_file" >&2
        exit 1
    fi
    after=$(cksum "$MODE_FILE")
    [ "$after" = "$before" ] || {
        printf '%s\n' 'mode parser modified an invalid active file' >&2
        exit 1
    }
done

# Restore a valid old selection before exercising failed publications.
printf '%s\n' 'MAGICNET_TRANSPARENT_MODE=tun' >"$MODE_FILE"
chmod 600 "$MODE_FILE"
original_sum=$(cksum "$MODE_FILE")

# A temporary-file write failure must be visible and preserve the old file.
write_tmp="${MODE_FILE}.tmp.$$"
mkdir -p "$write_tmp"
if magicnet_transparent_set_mode ebpf >/dev/null 2>&1; then
    printf '%s\n' 'transparent mode update unexpectedly succeeded after write failure' >&2
    exit 1
fi
rm -rf "$write_tmp"
[ "$(cksum "$MODE_FILE")" = "$original_sum" ] || {
    printf '%s\n' 'temporary write failure replaced the active mode file' >&2
    exit 1
}

# A rename failure is equally atomic. Override only mv in a subshell so no
# production path or staged user work is changed.
if (
    # Called indirectly by magicnet_transparent_set_mode.
    # shellcheck disable=SC2329
    mv() { return 1; }
    magicnet_transparent_set_mode ebpf
); then
    printf '%s\n' 'transparent mode update unexpectedly succeeded after rename failure' >&2
    exit 1
fi
[ "$(cksum "$MODE_FILE")" = "$original_sum" ] || {
    printf '%s\n' 'rename failure replaced the active mode file' >&2
    exit 1
}
assert_mode tun

printf '%s\n' 'transparent mode config safety passed'
