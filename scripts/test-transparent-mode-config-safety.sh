#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMMON="$ROOT/src/MagicNet/lib/magicnet/common.sh"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

MODDIR="$WORKDIR/module"
export MODDIR
mkdir -p "$MODDIR/.config/magicnet"
ln -s "$ROOT/src/MagicNet/lib" "$MODDIR/lib"
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

# Whitespace/comments and a final line without LF retain the existing parser
# contract; data is never interpreted as shell syntax.
printf ' \t# fixture\r\n\tMAGICNET_TRANSPARENT_MODE=tun\t\r\n' >"$MODE_FILE"
assert_mode tun
printf '%s' 'MAGICNET_TRANSPARENT_MODE=ebpf' >"$MODE_FILE"
assert_mode ebpf

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
    '' \
    '# comment only' \
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

# A rejected stdout write must not become success merely because cleanup ran
# afterward. Cover both the implicit default and each validated persisted mode.
[ -c /dev/full ] || { echo 'mode output regression requires /dev/full' >&2; exit 1; }
for mode in default tun ebpf; do
    if [ "$mode" = default ]; then
        rm -f "$MODE_FILE"
    else
        printf 'MAGICNET_TRANSPARENT_MODE=%s\n' "$mode" >"$MODE_FILE"
    fi
    if magicnet_transparent_mode >/dev/full 2>/dev/null; then
        echo "transparent mode output failure was accepted: $mode" >&2
        exit 1
    fi
done

# Run the external-applet budget in mksh even when CI invokes this script with
# sh/bash (whose printf builtins would bypass PATH). Executable PATH shims also
# see `command printf` / `command awk`, unlike shell-function interception.
(
    mode_test_mksh=$(command -v mksh) || {
        echo 'mode applet regression requires mksh' >&2
        exit 1
    }
    mode_test_bin="$WORKDIR/applet-bin"
    mkdir "$mode_test_bin"
    MAGICNET_MODE_TEST_CALLS="$WORKDIR/mode-read-calls"
    MAGICNET_MODE_TEST_AWK=$(command -v awk)
    MAGICNET_MODE_TEST_PRINTF=$("$mode_test_mksh" -c 'command -v printf')
    MAGICNET_MODE_TEST_AWK_FAIL=0
    export MAGICNET_MODE_TEST_CALLS MAGICNET_MODE_TEST_AWK MAGICNET_MODE_TEST_PRINTF MAGICNET_MODE_TEST_AWK_FAIL
    cat >"$mode_test_bin/printf" <<'SH'
#!/bin/sh
echo printf >>"$MAGICNET_MODE_TEST_CALLS"
exec "$MAGICNET_MODE_TEST_PRINTF" "$@"
SH
    cat >"$mode_test_bin/awk" <<'SH'
#!/bin/sh
echo awk >>"$MAGICNET_MODE_TEST_CALLS"
if [ "$MAGICNET_MODE_TEST_AWK_FAIL" = 1 ]; then echo tun; exit 1; fi
exec "$MAGICNET_MODE_TEST_AWK" "$@"
SH
    chmod +x "$mode_test_bin/printf" "$mode_test_bin/awk"
    "$mode_test_mksh" -s -- "$COMMON" "$MODE_FILE" "$mode_test_bin" <<'MKSH'
    set -eu
    import() { :; }
    . "$1"
    mode_test_file=$2
    mode_test_bin=$3
    PATH="$mode_test_bin:$PATH"
    export PATH
    [ "$(command -v printf)" = "$mode_test_bin/printf" ] || {
        echo 'mksh must use the external printf shim' >&2
        exit 1
    }

    # Positive controls prove that command-prefixed calls are counted too.
    : >"$MAGICNET_MODE_TEST_CALLS"
    printf '%s\n' control >/dev/null
    command printf '%s\n' control >/dev/null
    awk 'BEGIN {}'
    command awk 'BEGIN {}'
    [ "$(cat "$MAGICNET_MODE_TEST_CALLS")" = 'printf
printf
awk
awk' ] || { echo 'applet counter missed a command invocation' >&2; exit 1; }

    for mode in tun ebpf; do
        echo "MAGICNET_TRANSPARENT_MODE=$mode" >"$mode_test_file"
        : >"$MAGICNET_MODE_TEST_CALLS"
        actual=$(magicnet_transparent_mode)
        [ "$actual" = "$mode" ]
        [ "$(cat "$MAGICNET_MODE_TEST_CALLS")" = awk ] || {
            echo 'mode read spawned redundant external applets' >&2
            exit 1
        }
    done
    rm -f "$mode_test_file"
    : >"$MAGICNET_MODE_TEST_CALLS"
    actual=$(magicnet_transparent_mode)
    [ "$actual" = tun ]
    [ ! -s "$MAGICNET_MODE_TEST_CALLS" ] || {
        echo 'default mode spawned external applets' >&2
        exit 1
    }

    # A partial valid-looking awk result followed by read failure stays private.
    echo 'MAGICNET_TRANSPARENT_MODE=tun' >"$mode_test_file"
    MAGICNET_MODE_TEST_AWK_FAIL=1
    export MAGICNET_MODE_TEST_AWK_FAIL
    if actual=$(magicnet_transparent_mode); then
        echo 'failed mode read was accepted' >&2
        exit 1
    fi
    [ -z "$actual" ] || {
        echo 'failed mode read exposed partial output' >&2
        exit 1
    }
MKSH
)

printf '%s\n' 'transparent mode config safety passed'
