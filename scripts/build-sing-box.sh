#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${MAGICNET_SINGBOX_SOURCE_DIR:-$ROOT/sing-box}"
VERSION_FILE="$ROOT/sing-box.version"

usage() {
    printf 'usage: %s <goos> <goarch> <output>\n' "${0##*/}" >&2
}

if [[ $# -ne 3 ]]; then
    usage
    exit 64
fi

GOOS_TARGET="$1"
GOARCH_TARGET="$2"
OUTPUT_PATH="$3"

if [[ ! "$GOOS_TARGET" =~ ^[a-z0-9]+$ ]] || [[ ! "$GOARCH_TARGET" =~ ^[a-z0-9]+$ ]]; then
    printf 'sing-box build: invalid target %s/%s\n' "$GOOS_TARGET" "$GOARCH_TARGET" >&2
    exit 64
fi

if [[ ! -f "$SOURCE_DIR/go.mod" ]] || ! git -C "$SOURCE_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    printf 'sing-box build: source submodule is not initialized: %s\n' "$SOURCE_DIR" >&2
    printf 'run: git submodule update --init sing-box\n' >&2
    exit 1
fi

if ! grep -Fxq 'module github.com/sagernet/sing-box' "$SOURCE_DIR/go.mod"; then
    printf 'sing-box build: unexpected Go module in %s\n' "$SOURCE_DIR" >&2
    exit 1
fi

if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=normal)" ]]; then
    printf 'sing-box build: source submodule has uncommitted changes: %s\n' "$SOURCE_DIR" >&2
    exit 1
fi

command -v go >/dev/null 2>&1 || {
    printf 'sing-box build: Go is required\n' >&2
    exit 127
}

CGO_ENABLED_TARGET=0
CC_TARGET=""
if [[ "$GOOS_TARGET/$GOARCH_TARGET" = "android/amd64" ]]; then
    NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
    if [[ -z "$NDK_ROOT" ]] && [[ -n "${ANDROID_HOME:-}" ]] &&
        [[ -d "$ANDROID_HOME/ndk" ]]; then
        NDK_ROOT="$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d -print |
            sort -V | tail -n1)"
    fi
    if [[ -z "$NDK_ROOT" ]] && [[ -d /opt/android-ndk ]]; then
        NDK_ROOT=/opt/android-ndk
    fi
    NDK_TOOLCHAINS="$NDK_ROOT/toolchains/llvm/prebuilt"
    if [[ -d "$NDK_TOOLCHAINS" ]]; then
        CC_TARGET="$(find "$NDK_TOOLCHAINS" -type f \
            -name 'x86_64-linux-android21-clang' -print -quit)"
    fi
    if [[ ! -x "$CC_TARGET" ]]; then
        printf 'sing-box build: Android NDK clang is required for android/amd64\n' >&2
        exit 1
    fi
    CGO_ENABLED_TARGET=1
fi

BUILD_TAGS_FILE="$SOURCE_DIR/release/DEFAULT_BUILD_TAGS_OTHERS"
SHARED_LDFLAGS_FILE="$SOURCE_DIR/release/LDFLAGS"
if [[ ! -s "$BUILD_TAGS_FILE" ]] || [[ ! -s "$SHARED_LDFLAGS_FILE" ]] ||
    [[ ! -s "$VERSION_FILE" ]]; then
    printf 'sing-box build: fork release metadata is missing\n' >&2
    exit 1
fi

BUILD_TAGS="$(tr -d '\r\n' <"$BUILD_TAGS_FILE")"
SHARED_LDFLAGS="$(tr '\r\n' '  ' <"$SHARED_LDFLAGS_FILE")"
BASE_VERSION="$(tr -d '\r\n' <"$VERSION_FILE")"
if [[ ! "$BUILD_TAGS" =~ ^[a-zA-Z0-9_,.-]+$ ]]; then
    printf 'sing-box build: fork build tags contain unsupported characters\n' >&2
    exit 1
fi
if [[ ! "$BASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    printf 'sing-box build: invalid base version in %s\n' "$VERSION_FILE" >&2
    exit 1
fi

SOURCE_REVISION="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
SOURCE_VERSION="${BASE_VERSION}+LIghtJUNction.${SOURCE_REVISION:0:12}"
LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=${SOURCE_VERSION} ${SHARED_LDFLAGS} -s -w -buildid="

mkdir -p "$(dirname "$OUTPUT_PATH")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)"
OUTPUT_PATH="$OUTPUT_DIR/$(basename "$OUTPUT_PATH")"
TMP_OUTPUT="${OUTPUT_PATH}.tmp.$$"
cleanup() {
    rm -f "$TMP_OUTPUT"
}
trap cleanup EXIT

printf 'sing-box build: %s @ %s for %s/%s (CGO=%s)\n' \
    'LIghtJUNction/sing-box' "$SOURCE_REVISION" "$GOOS_TARGET" "$GOARCH_TARGET" \
    "$CGO_ENABLED_TARGET" >&2
(
    cd "$SOURCE_DIR"
    GO_ENV=(
        "CGO_ENABLED=$CGO_ENABLED_TARGET"
        "GOOS=$GOOS_TARGET"
        "GOARCH=$GOARCH_TARGET"
        "GOTOOLCHAIN=local"
        "GOWORK=off"
    )
    if [[ -n "$CC_TARGET" ]]; then
        GO_ENV+=("CC=$CC_TARGET")
    fi
    env "${GO_ENV[@]}" \
        go build \
        -mod=readonly \
        -trimpath \
        -buildvcs=false \
        -tags "$BUILD_TAGS" \
        -ldflags "$LDFLAGS" \
        -o "$TMP_OUTPUT" \
        ./cmd/sing-box
)

[[ -s "$TMP_OUTPUT" ]] || {
    printf 'sing-box build: compiler did not create an output binary\n' >&2
    exit 1
}
chmod 0755 "$TMP_OUTPUT"
mv -f "$TMP_OUTPUT" "$OUTPUT_PATH"
printf '%s\n' "LIghtJUNction/sing-box@$SOURCE_REVISION"
