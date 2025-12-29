#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}

if [ "$MAGIC_SINGBOX" -eq 0 ]; then
    [ -f "$KAM_MODULE_ROOT/singbox.version" ] && rm -f "$KAM_MODULE_ROOT/singbox.version"
    [ -f "$KAM_MODULE_ROOT/.local/bin/sing-box" ] && rm -f "$KAM_MODULE_ROOT/.local/bin/sing-box"
    exit 0
fi

# 环境检查
require_command gh "github-cli not found!"
require_command curl "curl not found!"

# 可选依赖（仅在需要时检查并提示）
# tar/gunzip/unzip 仅在解压相应格式时需要，我们在遇到这些格式时再做提示/检查

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

# 获取远端资产的 sha256（优先使用 gh metadata，必要时回退到 API 解析）
get_remote_hash() {
    local asset="$1"
    local digest=""

    # 优先使用 gh release view --json assets --jq
    if command -v gh >/dev/null 2>&1; then
        digest=$(gh release view "$LATEST_TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name==\"$asset\") | .digest" 2>/dev/null || true)
        if [ -n "$digest" ] && [ "$digest" != "null" ]; then
            echo "${digest#sha256:}"
            return 0
        fi
    fi

    # 回退：使用 gh api 或直接从 GitHub API 获取 JSON，然后解析
    local api_json
    if command -v gh >/dev/null 2>&1; then
        api_json=$(gh api "repos/$REPO/releases/tags/$LATEST_TAG" 2>/dev/null || true)
    else
        api_json=$(curl -sS "https://api.github.com/repos/$REPO/releases/tags/$LATEST_TAG" || true)
    fi

    if [ -z "$api_json" ]; then
        echo ""
        return 1
    fi

    if command -v jq >/dev/null 2>&1; then
        echo "$api_json" | jq -r --arg NAME "$asset" '.assets[] | select(.name==$NAME) | .digest' 2>/dev/null | sed 's/^sha256://' || true
        return 0
    fi

    # grep + sed fallback
    local ln
    ln=$(echo "$api_json" | grep -n "\"name\"[[:space:]]*:[[:space:]]*\"$asset\"" | head -n1 | cut -d: -f1) || true
    if [ -z "$ln" ]; then
        echo ""
        return 2
    fi
    echo "$api_json" | tail -n +"$ln" | head -n 20 | grep -m1 '"digest"' | sed -E 's/.*"digest":[[:space:]]*"(sha256:)?([0-9a-fA-F]+)".*/\2/'
}

# 路径定义
VERSION_FILE="${KAM_MODULE_ROOT}/singbox.version"
TARGET_DIR="${KAM_MODULE_ROOT}/.local/bin"
REPO="SagerNet/sing-box"

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
LATEST_TAG=$(gh release view --repo "$REPO" --json tagName --template '{{.tagName}}' 2>/dev/null || true)

if [ -z "$LATEST_TAG" ]; then
    log_error "错误：无法获取远程版本号，请检查 gh 登录状态或网络。"
    exit 1
fi

log_info "远程最新版本: $LATEST_TAG"

# 3. 比对版本
if [ "$CURRENT_VERSION" = "$LATEST_TAG" ]; then
    log_info "当前已是最新版本，无需下载。"
    exit 0
fi

# 4. 获取发布资产列表并选择最合适的包（优先 android + arm64）
log_info "正在选择适合的发布包..."

ASSET_NAMES=$(gh release view "$LATEST_TAG" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)

# 如果上面失败，使用 gh api 进行回退解析
if [ -z "$ASSET_NAMES" ]; then
    api_json=$(gh api "repos/$REPO/releases/tags/$LATEST_TAG" 2>/dev/null || true)
    ASSET_NAMES=$(echo "$api_json" | grep -o '"name":[[:space:]]*"[^"]*"' | sed -E 's/"name":[[:space:]]*"([^"]*)"/\1/' || true)
fi

PREFERRED_ASSET=""

# 优先：精确匹配 sing-box-<tag>-android-arm64.tar.gz（首选）
expected_asset="sing-box-${TAG_STRIP}-android-arm64.tar.gz"
if echo "$ASSET_NAMES" | grep -xF "$expected_asset" >/dev/null 2>&1; then
    PREFERRED_ASSET="$expected_asset"
else
    if [ -n "$ASSET_NAMES" ]; then
        PREFERRED_ASSET=$(echo "$ASSET_NAMES" | grep -i 'android-arm64' | head -n1 || true)
    fi
fi

# 回退：包含 android 且 包含 arm64/aarch64 的文件
if [ -z "$PREFERRED_ASSET" ] && [ -n "$ASSET_NAMES" ]; then
    while IFS= read -r a; do
        if echo "$a" | grep -qi 'android' && echo "$a" | grep -qiE 'arm64|aarch64|arm64-v8|arm64-v8a'; then
            PREFERRED_ASSET="$a"
            break
        fi
    done <<EOF
$ASSET_NAMES
EOF
fi

# 回退：任一包含 arm64/aarch64 的文件
if [ -z "$PREFERRED_ASSET" ] && [ -n "$ASSET_NAMES" ]; then
    while IFS= read -r a; do
        if echo "$a" | grep -qiE 'arm64|aarch64'; then
            PREFERRED_ASSET="$a"
            break
        fi
    done <<EOF
$ASSET_NAMES
EOF
fi

# 再回退：linux + arm64
if [ -z "$PREFERRED_ASSET" ] && [ -n "$ASSET_NAMES" ]; then
    while IFS= read -r a; do
        if echo "$a" | grep -qi 'linux' && echo "$a" | grep -qiE 'arm64|aarch64'; then
            PREFERRED_ASSET="$a"
            break
        fi
    done <<EOF
$ASSET_NAMES
EOF
fi

# 再回退：包含 sing-box 且 android
if [ -z "$PREFERRED_ASSET" ] && [ -n "$ASSET_NAMES" ]; then
    while IFS= read -r a; do
        if echo "$a" | grep -qi 'sing-box' && echo "$a" | grep -qi 'android'; then
            PREFERRED_ASSET="$a"
            break
        fi
    done <<EOF
$ASSET_NAMES
EOF
fi

# 最后回退：找到第一个包含 sing-box 的 asset
if [ -z "$PREFERRED_ASSET" ] && [ -n "$ASSET_NAMES" ]; then
    while IFS= read -r a; do
        if echo "$a" | grep -qi 'sing-box'; then
            PREFERRED_ASSET="$a"
            break
        fi
    done <<EOF
$ASSET_NAMES
EOF
fi

if [ -z "$PREFERRED_ASSET" ]; then
    log_error "错误：未能找到适用于本平台的 sing-box 发布包，请手动检查 $REPO 的 release。"
    exit 1
fi

log_info "选定发布包: $PREFERRED_ASSET"

# 5. 下载并安装（优先使用 gh release download）
DOWNLOAD_PATH="$KAM_MODULE_ROOT/$PREFERRED_ASSET"
log_info "准备下载: $PREFERRED_ASSET"

if command -v gh >/dev/null 2>&1; then
    if gh release download "$LATEST_TAG" --repo "$REPO" --pattern "$PREFERRED_ASSET" --dir "$KAM_MODULE_ROOT" --clobber >/dev/null 2>&1; then
        log_info "gh release 下载成功"
    else
        log_warn "gh release download 失败，尝试 curl 下载..."
        DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_TAG}/${PREFERRED_ASSET}"
        if ! curl -L -o "$DOWNLOAD_PATH" "$DOWNLOAD_URL"; then
            log_error "错误：下载失败，请检查网络或发布包名是否发生变化。"
            exit 1
        fi
    fi
else
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_TAG}/${PREFERRED_ASSET}"
    if ! curl -L -o "$DOWNLOAD_PATH" "$DOWNLOAD_URL"; then
        log_error "错误：下载失败，请检查网络或发布包名是否发生变化。"
        exit 1
    fi
fi

log_info "下载成功，正在验证 sha256（如果可用）并处理文件..."

# 获取并校验远端 sha256（如果可用）
REMOTE_HASH=$(get_remote_hash "$PREFERRED_ASSET" 2>/dev/null || true)
if [ -n "$REMOTE_HASH" ]; then
    LOCAL_HASH=$(compute_sha256 "$DOWNLOAD_PATH" 2>/dev/null || true)
    if [ -z "$LOCAL_HASH" ]; then
        log_warn "无法计算本地文件 sha256，跳过校验"
    else
        LOCAL_HASH_LOWER=$(echo "$LOCAL_HASH" | tr '[:upper:]' '[:lower:]')
        REMOTE_HASH_LOWER=$(echo "$REMOTE_HASH" | tr '[:upper:]' '[:lower:]')
        if [ "$LOCAL_HASH_LOWER" != "$REMOTE_HASH_LOWER" ]; then
            log_error "错误：下载文件 sha256 校验失败 (local=$LOCAL_HASH remote=$REMOTE_HASH)"
            rm -f "$DOWNLOAD_PATH" 2>/dev/null || true
            exit 1
        else
            log_info "sha256 校验通过"
        fi
    fi
else
    log_warn "未获取到远端 sha256，跳过校验"
fi

# 6. 解压到临时目录并查找二进制
TMP_DIR=$(mktemp -d "${KAM_MODULE_ROOT}/.tmp.singbox.XXXXXX" 2>/dev/null || mktemp -d)
cleanup() {
    # 删除临时目录与下载的归档（如果存在）
    rm -rf "$TMP_DIR" "$DOWNLOAD_PATH" 2>/dev/null || true
}
trap cleanup EXIT

BIN_CANDIDATE=""

case "$DOWNLOAD_PATH" in
    *.tar.gz|*.tgz)
        require_command tar "tar not found!"
        if tar -xzf "$DOWNLOAD_PATH" -C "$TMP_DIR"; then
            BIN_CANDIDATE=$(find "$TMP_DIR" -type f -iname "sing-box" -print -quit || true)
            if [ -z "$BIN_CANDIDATE" ]; then
                BIN_CANDIDATE=$(find "$TMP_DIR" -type f -iname "*sing*box*" -print -quit || true)
            fi
        else
            log_error "错误：解压 tarball 失败。"
            exit 1
        fi
        ;;
    *.gz)
        require_command gunzip "gunzip not found!"
        cp "$DOWNLOAD_PATH" "$TMP_DIR/" || true
        if gunzip -f "$TMP_DIR/$(basename "$DOWNLOAD_PATH")"; then
            BIN_CANDIDATE="$TMP_DIR/$(basename "${DOWNLOAD_PATH%.gz}")"
        else
            log_error "错误：gunzip 解压失败。"
            exit 1
        fi
        ;;
    *.zip)
        require_command unzip "unzip not found!"
        if unzip -o "$DOWNLOAD_PATH" -d "$TMP_DIR" >/dev/null 2>&1; then
            BIN_CANDIDATE=$(find "$TMP_DIR" -type f -iname "sing-box" -print -quit || true)
            if [ -z "$BIN_CANDIDATE" ]; then
                BIN_CANDIDATE=$(find "$TMP_DIR" -type f -iname "*sing*box*" -print -quit || true)
            fi
        else
            log_error "错误：unzip 解压失败。"
            exit 1
        fi
        ;;
    *)
        # 假设直接下载的是可执行文件，复制到临时目录再处理
        cp "$DOWNLOAD_PATH" "$TMP_DIR/" || { log_error "错误：复制文件失败。"; exit 1; }
        BIN_CANDIDATE="$TMP_DIR/$(basename "$DOWNLOAD_PATH")"
        ;;
esac

if [ -z "$BIN_CANDIDATE" ] || [ ! -f "$BIN_CANDIDATE" ]; then
    log_error "错误：未能找到 sing-box 可执行文件。"
    exit 1
fi

log_info "找到二进制: $BIN_CANDIDATE"

# 7. 移动并重命名
if mv -f "$BIN_CANDIDATE" "${TARGET_DIR}/sing-box"; then
    chmod +x "${TARGET_DIR}/sing-box"

    # 清理：下载的归档以及临时目录由 trap cleanup 处理
    rm -f "$DOWNLOAD_PATH" 2>/dev/null || true

    # 写入版本文件
    echo "$LATEST_TAG" > "$VERSION_FILE"

    log_success "安装完成！位置: ${TARGET_DIR}/sing-box"
    log_success "版本已更新为: $LATEST_TAG"
else
    log_error "错误：移动文件失败。"
    exit 1
fi
