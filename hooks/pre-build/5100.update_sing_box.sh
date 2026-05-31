#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"

MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}
VERSION_FILE="${KAM_MODULE_ROOT}/singbox.version"
TARGET_DIR="${KAM_MODULE_ROOT}/.local/bin"
TARGET_BIN="${TARGET_DIR}/sing-box"
REPO="SagerNet/sing-box"

select_sing_box_asset() {
    local asset_names="$1"
    local tag_strip="$2"
    local expected_asset="sing-box-${tag_strip}-android-arm64.tar.gz"
    local asset

    if printf '%s\n' "$asset_names" | grep -xF "$expected_asset" >/dev/null 2>&1; then
        printf '%s\n' "$expected_asset"
        return 0
    fi

    asset=$(hook_select_asset "$asset_names" 'android-arm64' || true)
    if [ -n "$asset" ]; then
        printf '%s\n' "$asset"
        return 0
    fi

    hook_select_asset \
        "$asset_names" \
        'android.*(arm64|aarch64|arm64-v8|arm64-v8a)' \
        '(arm64|aarch64)' \
        'linux.*(arm64|aarch64)' \
        'sing-box.*android' \
        'sing-box' || true
}

if [ "$MAGIC_SINGBOX" -eq 0 ]; then
    rm -f "$VERSION_FILE" "$TARGET_BIN"
    exit 0
fi

require_command gh "github-cli not found!"
require_command curl "curl not found!"

mkdir -p "$TARGET_DIR"

CURRENT_VERSION=$(hook_current_version "$VERSION_FILE")
log_info "本地版本: $CURRENT_VERSION"

log_info "正在检查远程最新版本..."
LATEST_TAG=$(github_latest_tag "$REPO")
[ -n "$LATEST_TAG" ] || { log_error "错误：无法获取远程版本号，请检查 gh 登录状态或网络。"; exit 1; }
log_info "远程最新版本: $LATEST_TAG"

if [ "$CURRENT_VERSION" = "$LATEST_TAG" ]; then
    log_info "当前已是最新版本，无需下载。"
    exit 0
fi

log_info "正在选择适合的发布包..."
ASSET_NAMES=$(github_asset_names "$REPO" "$LATEST_TAG" || true)
PREFERRED_ASSET=$(select_sing_box_asset "$ASSET_NAMES" "${LATEST_TAG#v}")

if [ -z "$PREFERRED_ASSET" ]; then
    log_error "错误：未能找到适用于本平台的 sing-box 发布包，请手动检查 $REPO 的 release。"
    exit 1
fi

log_info "选定发布包: $PREFERRED_ASSET"

TMP_DIR=$(hook_make_temp_dir)
DOWNLOAD_PATH=""
cleanup() {
    rm -rf "$TMP_DIR" "$DOWNLOAD_PATH" 2>/dev/null || true
}
trap cleanup EXIT

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${PREFERRED_ASSET}"
DOWNLOAD_PATH=$(github_download_asset "$REPO" "$LATEST_TAG" "$PREFERRED_ASSET" "$KAM_MODULE_ROOT" "$DOWNLOAD_URL") || {
    log_error "错误：下载失败，请检查网络或发布包名是否发生变化。"
    exit 1
}

github_verify_asset_digest "$REPO" "$LATEST_TAG" "$PREFERRED_ASSET" "$DOWNLOAD_PATH" || exit 1
hook_extract_binary "$DOWNLOAD_PATH" "$TMP_DIR" "sing-box" "*sing*box*" || {
    log_error "错误：未能找到 sing-box 可执行文件。"
    exit 1
}

log_info "找到二进制: $HOOK_EXTRACTED_BINARY"
mv -f "$HOOK_EXTRACTED_BINARY" "$TARGET_BIN"
chmod +x "$TARGET_BIN"
printf '%s\n' "$LATEST_TAG" > "$VERSION_FILE"

log_success "安装完成！位置: ${TARGET_BIN}"
log_success "版本已更新为: $LATEST_TAG"
