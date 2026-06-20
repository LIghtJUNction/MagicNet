#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"

MAGIC_ECAPTURE=${MAGIC_ECAPTURE:-1}
VERSION_FILE="${KAM_MODULE_ROOT}/ecapture.version"
TARGET_DIR="${KAM_MODULE_ROOT}/bin"
TARGET_BIN="${TARGET_DIR}/ecapture"
REPO="gojue/ecapture"

select_ecapture_asset() {
    local asset_names="$1"
    local tag="$2"
    local expected_asset="ecapture-${tag}-android-arm64.tar.gz"

    if printf '%s\n' "$asset_names" | grep -xF "$expected_asset" >/dev/null 2>&1; then
        printf '%s\n' "$expected_asset"
        return 0
    fi

    hook_select_asset \
        "$asset_names" \
        'ecapture-.*android-arm64.*\.tar\.gz$' \
        'ecapture-.*android.*(arm64|aarch64).*\.tar\.gz$' \
        'android.*(arm64|aarch64).*\.tar\.gz$' || true
}

if [ "$MAGIC_ECAPTURE" -eq 0 ]; then
    rm -f "$VERSION_FILE" "$TARGET_BIN"
    exit 0
fi

require_command gh "github-cli not found!"
require_command curl "curl not found!"
require_command tar "tar not found!"

mkdir -p "$TARGET_DIR"

CURRENT_VERSION=$(hook_current_version "$VERSION_FILE")
log_info "eCapture local version: $CURRENT_VERSION"

log_info "Checking latest eCapture release..."
LATEST_TAG=$(github_latest_tag "$REPO")
[ -n "$LATEST_TAG" ] || { log_error "cannot resolve latest eCapture release tag"; exit 1; }
log_info "eCapture latest version: $LATEST_TAG"

if [ "$CURRENT_VERSION" = "$LATEST_TAG" ] && [ -x "$TARGET_BIN" ]; then
    log_info "eCapture is already up to date."
    exit 0
fi

ASSET_NAMES=$(github_asset_names "$REPO" "$LATEST_TAG" || true)
PREFERRED_ASSET=$(select_ecapture_asset "$ASSET_NAMES" "$LATEST_TAG")

if [ -z "$PREFERRED_ASSET" ]; then
    log_error "could not find Android arm64 eCapture release asset in $REPO $LATEST_TAG"
    exit 1
fi

log_info "Selected eCapture asset: $PREFERRED_ASSET"

TMP_DIR=$(hook_make_temp_dir)
DOWNLOAD_PATH=""
cleanup() {
    rm -rf "$TMP_DIR" "$DOWNLOAD_PATH" 2>/dev/null || true
}
trap cleanup EXIT

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${PREFERRED_ASSET}"
DOWNLOAD_PATH=$(github_download_asset "$REPO" "$LATEST_TAG" "$PREFERRED_ASSET" "$KAM_MODULE_ROOT" "$DOWNLOAD_URL") || {
    log_error "eCapture download failed"
    exit 1
}

github_verify_asset_digest "$REPO" "$LATEST_TAG" "$PREFERRED_ASSET" "$DOWNLOAD_PATH" || exit 1
hook_extract_binary "$DOWNLOAD_PATH" "$TMP_DIR" "ecapture" "*ecapture*" || {
    log_error "could not find ecapture executable in release archive"
    exit 1
}

mv -f "$HOOK_EXTRACTED_BINARY" "$TARGET_BIN"
chmod 0755 "$TARGET_BIN"
printf '%s\n' "$LATEST_TAG" >"$VERSION_FILE"

log_success "eCapture installed: $TARGET_BIN"
log_success "eCapture version updated to: $LATEST_TAG"
