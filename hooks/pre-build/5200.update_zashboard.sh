#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"

MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}
REPO="Zephyruso/zashboard"
ASSET="dist-no-fonts.zip"
VERSION_FILE="${KAM_MODULE_ROOT}/zashboard.version"
TARGET_DIR="${KAM_MODULE_ROOT}/.config/sing-box/zashboard"

if [ "$MAGIC_SINGBOX" -eq 0 ]; then
    rm -rf "$VERSION_FILE" "$TARGET_DIR"
    exit 0
fi

require_command gh "github-cli not found!"
require_command curl "curl not found!"
require_command unzip "unzip not found!"

CURRENT_VERSION=$(hook_current_version "$VERSION_FILE")
log_info "zashboard 本地版本: $CURRENT_VERSION"

LATEST_TAG=$(github_latest_tag "$REPO")
[ -n "$LATEST_TAG" ] || { log_error "错误：无法获取 zashboard 远程版本号。"; exit 1; }
log_info "zashboard 远程最新版本: $LATEST_TAG"

if [ "$CURRENT_VERSION" = "$LATEST_TAG" ] && [ -f "$TARGET_DIR/index.html" ]; then
    log_info "zashboard 当前已是最新版本，无需下载。"
    exit 0
fi

TMP_DIR=$(hook_make_temp_dir)
DOWNLOAD_PATH=""
cleanup() {
    rm -rf "$TMP_DIR" "$DOWNLOAD_PATH" 2>/dev/null || true
}
trap cleanup EXIT

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${ASSET}"
DOWNLOAD_PATH=$(github_download_asset "$REPO" "$LATEST_TAG" "$ASSET" "$KAM_MODULE_ROOT" "$DOWNLOAD_URL") || {
    log_error "错误：下载 zashboard 失败。"
    exit 1
}

github_verify_asset_digest "$REPO" "$LATEST_TAG" "$ASSET" "$DOWNLOAD_PATH" || exit 1

rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
unzip -o "$DOWNLOAD_PATH" -d "$TARGET_DIR" >/dev/null

if [ -f "$TARGET_DIR/dist/index.html" ]; then
    TMP_ZASHBOARD_DIR="${TARGET_DIR}.new"
    rm -rf "$TMP_ZASHBOARD_DIR"
    mkdir -p "$TMP_ZASHBOARD_DIR"
    cp -a "$TARGET_DIR/dist"/. "$TMP_ZASHBOARD_DIR"/
    rm -rf "$TARGET_DIR"
    mv "$TMP_ZASHBOARD_DIR" "$TARGET_DIR"
fi

if [ ! -f "$TARGET_DIR/index.html" ]; then
    log_error "zashboard archive did not contain index.html"
    exit 1
fi

printf '%s\n' "$LATEST_TAG" >"$VERSION_FILE"
log_success "zashboard installed to $TARGET_DIR"
