#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

# 环境检查
require_command gh "github-cli not found!"
require_command tar "tar not found!"
require_command curl "curl not found!"

# 路径定义
VERSION_FILE="${KAM_MODULE_ROOT}/yq.version"
TARGET_DIR="${KAM_MODULE_ROOT}/system/bin"
# yq 的架构命名通常为 linux_arm64
ARCH="linux_arm64"

# 确保目录存在
mkdir -p "$TARGET_DIR"

# 1. 获取本地当前版本
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE")
else
    CURRENT_VERSION="none"
fi

log_info "本地 yq 版本: $CURRENT_VERSION"

# 2. 获取远程最新版本
log_info "正在检查 yq 远程最新版本..."
LATEST_TAG=$(gh release view --repo mikefarah/yq --json tagName --template '{{.tagName}}')

if [ -z "$LATEST_TAG" ]; then
    log_error "错误：无法获取 yq 远程版本号。"
    exit 1
fi

log_info "远程最新版本: $LATEST_TAG"

# 3. 比对版本
if [ "$CURRENT_VERSION" == "$LATEST_TAG" ]; then
    log_info "yq 当前已是最新版本，无需下载。"

    exit 0
fi

# 4. 变量定义
# yq 格式示例: yq_linux_arm64.tar.gz
FILENAME="yq_${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/mikefarah/yq/releases/download/${LATEST_TAG}/${FILENAME}"

log_info "下载链接: $DOWNLOAD_URL"
log_info "发现新版本，准备下载: $FILENAME"

# 5. 下载并安装
if curl -L -o "${KAM_MODULE_ROOT}/${FILENAME}" "$DOWNLOAD_URL"; then
    log_info "下载成功，正在解压..."

    # 6. 使用 tar 解压
    # -x: 解压, -z: gzip 格式, -f: 文件, -C: 指定目录
    # yq 的 tar.gz 包里通常包含一个名为 yq_linux_arm64 的文件
    if tar -xzf "${KAM_MODULE_ROOT}/${FILENAME}" -C "${KAM_MODULE_ROOT}"; then

        # 7. 移动并重命名
        # yq 压缩包解压出的文件名通常与 ARCH 变量相关
        TEMP_BIN="yq_${ARCH}"

        if [ -f "${KAM_MODULE_ROOT}/${TEMP_BIN}" ]; then
            mv -f "${KAM_MODULE_ROOT}/${TEMP_BIN}" "${TARGET_DIR}/yq"

            # 8. 赋予执行权限
            chmod +x "${TARGET_DIR}/yq"

            # 9. 更新版本文件
            echo "$LATEST_TAG" > "$VERSION_FILE"

            # 10. 清理残留文件 (tar.gz 不会像 gunzip 那样解压后自动删除)
            rm -f "${KAM_MODULE_ROOT}/${FILENAME}"

            log_success "yq 安装完成！位置: ${TARGET_DIR}/yq"
            log_success "版本已更新为: $LATEST_TAG"

            if [ -f "${KAM_MODULE_ROOT}/yq.1" ]; then
                rm -f "${KAM_MODULE_ROOT}/yq.1"
            fi
            if [ -f "${KAM_MODULE_ROOT}/install-man-page.sh" ]; then
                rm -f "${KAM_MODULE_ROOT}/install-man-page.sh"
            fi
        else
            log_error "错误：解压后未找到预期文件 ${TEMP_BIN}"
            exit 1
        fi
    else
        log_error "错误：解压失败。"
        exit 1
    fi
else
    log_error "错误：下载失败。"
    exit 1
fi
