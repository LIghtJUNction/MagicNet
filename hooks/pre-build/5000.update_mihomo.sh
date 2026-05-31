#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

MAGIC_MIHOMO=${MAGIC_MIHOMO:-1}

if [ "$MAGIC_MIHOMO" -eq 0 ]; then
    [ -f "$KAM_MODULE_ROOT/mihomo.version" ] && rm -f "$KAM_MODULE_ROOT/mihomo.version"
    [ -f "$KAM_MODULE_ROOT/.local/bin/mihomo" ] && rm -f "$KAM_MODULE_ROOT/.local/bin/mihomo"
    exit 0
fi

# 环境检查
require_command gh "github-cli not found!"
require_command gunzip "gunzip not found!"
require_command curl "curl not found!"

# 计算文件 sha256（跨平台）
compute_sha256() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$f" | awk '{print $2}'
    else
        echo ""
    fi
}

get_remote_hash() {
    local asset="$1"
    local digest

    digest=$(gh release view "$LATEST_TAG" --repo MetaCubeX/mihomo --json assets --jq ".assets[] | select(.name==\"$asset\") | .digest" 2>/dev/null || true)
    if [ -n "$digest" ] && [ "$digest" != "null" ]; then
        echo "${digest#sha256:}"
        return 0
    fi

    gh api "repos/MetaCubeX/mihomo/releases/tags/$LATEST_TAG" 2>/dev/null |
        grep -A 20 "\"name\":[[:space:]]*\"$asset\"" |
        grep -m1 '"digest"' |
        sed -E 's/.*"digest":[[:space:]]*"(sha256:)?([0-9a-fA-F]+)".*/\2/' || true
}

# 路径定义
VERSION_FILE="${KAM_MODULE_ROOT}/mihomo.version"
TARGET_DIR="${KAM_MODULE_ROOT}/.local/bin"
ARCH="android-arm64-v8"

# 确保目录存在
mkdir -p "$TARGET_DIR"

# 1. 获取本地当前版本
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE")
else
    CURRENT_VERSION="none"
fi

log_info "本地版本: $CURRENT_VERSION"

# 2. 获取远程最新版本
log_info "正在检查远程最新版本..."
LATEST_TAG=$(gh release view --repo MetaCubeX/mihomo --json tagName --template '{{.tagName}}')

if [ -z "$LATEST_TAG" ]; then
    log_error "错误：无法获取远程版本号，请检查 gh 登录状态或网络。"
    exit 1
fi

log_info "远程最新版本: $LATEST_TAG"

# 3. 比对版本
if [ "$CURRENT_VERSION" == "$LATEST_TAG" ]; then
    log_info "当前已是最新版本，无需下载。"
    exit 0
fi

# 4. 变量修正 (注意文件名必须与下载后 gunzip 生成的文件名一致)
FILENAME="mihomo-${ARCH}-${LATEST_TAG}.gz"
TEMP_BIN="mihomo-${ARCH}-${LATEST_TAG}"

DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/${FILENAME}"
log_info "$DOWNLOAD_URL"
log_info "发现新版本，准备下载: $FILENAME"

# 5. 下载并安装
if curl -L -o "${KAM_MODULE_ROOT}/${FILENAME}" "$DOWNLOAD_URL"; then
    log_info "下载成功，正在处理文件..."

    REMOTE_HASH=$(get_remote_hash "$FILENAME" 2>/dev/null || true)
    if [ -n "$REMOTE_HASH" ]; then
        LOCAL_HASH=$(compute_sha256 "${KAM_MODULE_ROOT}/${FILENAME}" 2>/dev/null || true)
        if [ -z "$LOCAL_HASH" ]; then
            log_warn "无法计算本地文件 sha256，跳过校验"
        elif [ "$(echo "$LOCAL_HASH" | tr '[:upper:]' '[:lower:]')" != "$(echo "$REMOTE_HASH" | tr '[:upper:]' '[:lower:]')" ]; then
            rm -f "${KAM_MODULE_ROOT}/${FILENAME}" 2>/dev/null || true
            log_error "错误：下载文件 sha256 校验失败 (local=$LOCAL_HASH remote=$REMOTE_HASH)"
            exit 1
        else
            log_info "sha256 校验通过"
        fi
    else
        log_warn "未获取到远端 sha256，跳过校验"
    fi

    # 6. 解压 (gunzip 会生成 ${TEMP_BIN})
    if gunzip -f "${KAM_MODULE_ROOT}/${FILENAME}"; then

        # 7. 移动并重命名
        if mv -f "${KAM_MODULE_ROOT}/${TEMP_BIN}" "${TARGET_DIR}/mihomo"; then

            # 8. 赋予执行权限
            chmod +x "${TARGET_DIR}/mihomo"

            # 9. 更新版本文件
            echo "$LATEST_TAG" > "$VERSION_FILE"

            log_success "安装完成！位置: ${TARGET_DIR}/mihomo"
            log_success "版本已更新为: $LATEST_TAG"
        else
            log_error "错误：移动文件失败。"
            exit 1
        fi
    else
        log_error "错误：解压失败。"
        exit 1
    fi
else
    log_error "错误：下载失败，请检查网络。"
    exit 1
fi
