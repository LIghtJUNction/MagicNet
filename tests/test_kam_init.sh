#!/bin/sh
# test_kam_init.sh
# Tests for kam_init arch-based copying:
# - .kam/<prefix>/<arch>/* -> <moddir>/<prefix>/*
# - Falls back to ABI32 and generic 'all' directories
# - Copies generic files under .kam/<prefix>/ when no arch dirs present
# - Legacy behavior: .kam/<arch> single file -> .local/bin/
#
# Usage:
#   cd <repo_root>/MagicNet
#   sh tests/test_kam_init.sh
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_SRC="$REPO_ROOT/src/MagicNet"

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'OK: %s\n' "$*"
}

# Run kam_init in a clean subshell with MODDIR pointing at tmpdir
run_kam_init() {
    tmp="$1"
    # call in a subshell to avoid polluting current environment
    (
        set -eu
        export MODDIR="$tmp"
        # ARCH and ABI32 should be exported by caller if needed

        # Create a temporary version of the library with the automatic
        # final `kam_load base` call disabled so sourcing does not trigger
        # module loading (which can fail during test setup).
        tmp_lib="$tmp/kam-utils.noload.sh"
        sed 's/^kam_load base$/# kam_load base (disabled in tests)/' "$MODDIR/lib/kam-utils.sh" > "$tmp_lib"

        # Source the modified copy to avoid auto-loading during sourcing
        . "$tmp_lib"
        rm -f "$tmp_lib" 2>/dev/null || true

        # Sourcing the library may override MODDIR (it uses ${0%/*}), restore it
        export MODDIR="$tmp"

        # Now call kam_init which will perform loading using the correct MODDIR
        kam_init
    )
}

# Test 1: arch-specific files under system/bin/<arch> -> moddir/system/bin/
test_arch_system_bin() (
    set -eu
    tmpdir="$(mktemp -d 2>/dev/null || (printf '/tmp/kamtest.%s\n' "$RANDOM" && mkdir -p "/tmp/kamtest.$RANDOM" && printf "/tmp/kamtest.%s\n" "$RANDOM"))"
    trap 'rm -rf "$tmpdir"' EXIT

    cp -a "$MODULE_SRC/lib" "$tmpdir/" || die "failed to copy lib"
    mkdir -p "$tmpdir/.kam/system/bin/arm64"
    printf 'echo hello64\n' > "$tmpdir/.kam/system/bin/arm64/tool64"
    chmod 0644 "$tmpdir/.kam/system/bin/arm64/tool64"

    export ARCH=arm64
    run_kam_init "$tmpdir"

    [ -f "$tmpdir/system/bin/tool64" ] || die "tool64 was not installed to system/bin"
    [ -x "$tmpdir/system/bin/tool64" ] || die "tool64 should be executable (755)"
    ok "arch-specific system/bin -> tool64 installed and executable"
)

# Test 2: fallback to ABI32 (e.g. ARCH=arm64 with ABI32=armeabi-v7a)
test_arch_fallback_abi32() (
    set -eu
    tmpdir="$(mktemp -d 2>/dev/null || (printf '/tmp/kamtest.%s\n' "$RANDOM" && mkdir -p "/tmp/kamtest.$RANDOM" && printf "/tmp/kamtest.%s\n" "$RANDOM"))"
    trap 'rm -rf "$tmpdir"' EXIT

    cp -a "$MODULE_SRC/lib" "$tmpdir/" || die "failed to copy lib"
    mkdir -p "$tmpdir/.kam/system/bin/armeabi-v7a"
    printf 'echo arm32\n' > "$tmpdir/.kam/system/bin/armeabi-v7a/arm32tool"
    chmod 0755 "$tmpdir/.kam/system/bin/armeabi-v7a/arm32tool"

    export ARCH=arm64
    export ABI32=armeabi-v7a
    run_kam_init "$tmpdir"

    [ -f "$tmpdir/system/bin/arm32tool" ] || die "arm32tool was not installed to system/bin"
    [ -x "$tmpdir/system/bin/arm32tool" ] || die "arm32tool should be executable (755)"
    ok "fallback ABI32 -> arm32tool installed and executable"
)

# Test 3: generic files under .kam/<prefix>/ (no arch) copied to moddir/<prefix>
test_generic_prefix_files() (
    set -eu
    tmpdir="$(mktemp -d 2>/dev/null || (printf '/tmp/kamtest.%s\n' "$RANDOM" && mkdir -p "/tmp/kamtest.$RANDOM" && printf "/tmp/kamtest.%s\n" "$RANDOM"))"
    trap 'rm -rf "$tmpdir"' EXIT

    cp -a "$MODULE_SRC/lib" "$tmpdir/" || die "failed to copy lib"
    mkdir -p "$tmpdir/.kam/system/lib"
    printf 'libdata' > "$tmpdir/.kam/system/lib/libfoo.so"
    chmod 0644 "$tmpdir/.kam/system/lib/libfoo.so"

    export ARCH=arm64
    run_kam_init "$tmpdir"

    [ -f "$tmpdir/system/lib/libfoo.so" ] || die "libfoo.so was not copied to system/lib"
    if [ -x "$tmpdir/system/lib/libfoo.so" ]; then
        die "libfoo.so should NOT be executable"
    fi
    ok "generic files in system/lib copied and not executable"
)

# Test 4: legacy single file .kam/<arch> copied to .local/bin/
test_legacy_single_file() (
    set -eu
    tmpdir="$(mktemp -d 2>/dev/null || (printf '/tmp/kamtest.%s\n' "$RANDOM" && mkdir -p "/tmp/kamtest.$RANDOM" && printf "/tmp/kamtest.%s\n" "$RANDOM"))"
    trap 'rm -rf "$tmpdir"' EXIT

    cp -a "$MODULE_SRC/lib" "$tmpdir/" || die "failed to copy lib"
    mkdir -p "$tmpdir/.kam"
    printf 'legacy' > "$tmpdir/.kam/arm64"
    chmod 0755 "$tmpdir/.kam/arm64"

    export ARCH=arm64
    run_kam_init "$tmpdir"

    [ -f "$tmpdir/.local/bin/arm64" ] || die "legacy single file not copied to .local/bin"
    [ -x "$tmpdir/.local/bin/arm64" ] || die "legacy single file should be executable"
    ok "legacy single arch file copied to .local/bin and executable"
)

echo "Running tests..."
test_arch_system_bin
test_arch_fallback_abi32
test_generic_prefix_files
test_legacy_single_file

echo "All tests passed."
