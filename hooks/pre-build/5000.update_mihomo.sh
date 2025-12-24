#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

# 环境检查
require_command gh "github-cli not found!"
require_command gunzip "gunzip not found!"
require_command curl "curl not found!"

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
log_info $DOWNLOAD_URL
log_info "发现新版本，准备下载: $FILENAME"

# 5. 下载并安装
if curl -L -o "${KAM_MODULE_ROOT}/${FILENAME}" "$DOWNLOAD_URL"; then
    log_info "下载成功，正在处理文件..."

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
