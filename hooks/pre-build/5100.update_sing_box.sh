#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}
PROJECT_ROOT="${KAM_PROJECT_ROOT:-$(cd "$KAM_HOOKS_ROOT/.." && pwd)}"
SOURCE_DIR="${PROJECT_ROOT}/sing-box"
BUILD_SCRIPT="${PROJECT_ROOT}/scripts/build-sing-box.sh"
VERSION_FILE="${KAM_MODULE_ROOT}/singbox.version"
TARGET_DIR="${KAM_MODULE_ROOT}/bin"
TARGET_BIN="${TARGET_DIR}/sing-box"

if [ "$MAGIC_SINGBOX" -eq 0 ]; then
    rm -f "$VERSION_FILE" "$TARGET_BIN"
    exit 0
fi

if [ ! -x "$BUILD_SCRIPT" ]; then
    log_error "sing-box: build helper is missing or not executable: $BUILD_SCRIPT"
    exit 1
fi
if [ ! -f "$SOURCE_DIR/go.mod" ]; then
    log_error "sing-box: source submodule is not initialized; run git submodule update --init sing-box"
    exit 1
fi

SOURCE_REVISION=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null) || {
    log_error "sing-box: failed to resolve the fork source revision"
    exit 1
}
case "$SOURCE_REVISION" in
*[!0-9a-f]* | '')
    log_error "sing-box: invalid fork source revision"
    exit 1
    ;;
esac
SOURCE_REF="LIghtJUNction/sing-box@${SOURCE_REVISION}"

mkdir -p "$TARGET_DIR"
TARGET_NEW="${TARGET_BIN}.new.$$"
VERSION_NEW="${VERSION_FILE}.new.$$"
cleanup() {
    rm -f "$TARGET_NEW" "$VERSION_NEW"
}
trap cleanup EXIT

if ! MAGICNET_SINGBOX_SOURCE_DIR="$SOURCE_DIR" \
    "$BUILD_SCRIPT" android arm64 "$TARGET_NEW" >/dev/null; then
    log_error "sing-box: fork source build failed; existing target was not changed"
    exit 1
fi

printf '%s\n' "$SOURCE_REF" >"$VERSION_NEW" || {
    log_error "sing-box: failed to stage source provenance"
    exit 1
}
chmod 0755 "$TARGET_NEW"
mv -f "$TARGET_NEW" "$TARGET_BIN"
mv -f "$VERSION_NEW" "$VERSION_FILE"

log_success "sing-box built from $SOURCE_REF -> $TARGET_BIN"
