#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"

MAGIC_MIHOMO=${MAGIC_MIHOMO:-1}
VERSION_FILE="${KAM_MODULE_ROOT}/mihomo.version"
TARGET_DIR="${KAM_MODULE_ROOT}/bin"
TARGET_BIN="${TARGET_DIR}/mihomo"
REPO="MetaCubeX/mihomo"
ARCH="android-arm64-v8"

if [ "$MAGIC_MIHOMO" -eq 0 ]; then
    rm -f "$VERSION_FILE" "$TARGET_BIN"
    exit 0
fi

require_command gh "github-cli not found!"
require_command curl "curl not found!"
require_command gunzip "gunzip not found!"

mkdir -p "$TARGET_DIR"

CURRENT_VERSION=$(hook_current_version "$VERSION_FILE")
log_info "本地版本: $CURRENT_VERSION"

log_info "正在检查远程最新版本..."
LATEST_TAG=$(github_latest_tag "$REPO")
[ -n "$LATEST_TAG" ] || { log_error "错误：无法获取远程版本号，请检查 gh 登录状态或网络。"; exit 1; }
log_info "远程最新版本: $LATEST_TAG"

if [ "$CURRENT_VERSION" = "$LATEST_TAG" ] && [ -x "$TARGET_BIN" ]; then
    log_info "当前已是最新版本，无需下载。"
    exit 0
fi

ASSET="mihomo-${ARCH}-${LATEST_TAG}.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${ASSET}"
TMP_DIR=$(hook_make_temp_dir)
cleanup() {
    rm -rf "$TMP_DIR" "${KAM_MODULE_ROOT:?}/$ASSET" 2>/dev/null || true
}
trap cleanup EXIT

log_info "发现新版本，准备下载: $ASSET"
DOWNLOAD_PATH=$(github_download_asset "$REPO" "$LATEST_TAG" "$ASSET" "$KAM_MODULE_ROOT" "$DOWNLOAD_URL") || {
    log_error "错误：下载失败，请检查网络。"
    exit 1
}

github_verify_asset_digest "$REPO" "$LATEST_TAG" "$ASSET" "$DOWNLOAD_PATH" || exit 1
hook_extract_binary "$DOWNLOAD_PATH" "$TMP_DIR" "mihomo-${ARCH}-${LATEST_TAG}" "mihomo*" || {
    log_error "错误：未能找到 mihomo 可执行文件。"
    exit 1
}

mv -f "$HOOK_EXTRACTED_BINARY" "$TARGET_BIN"
chmod +x "$TARGET_BIN"
printf '%s\n' "$LATEST_TAG" > "$VERSION_FILE"

log_success "安装完成！位置: ${TARGET_BIN}"
log_success "版本已更新为: $LATEST_TAG"
