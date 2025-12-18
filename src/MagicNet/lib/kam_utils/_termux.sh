#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# Termux API 模块 - 内部函数（完全重写）
# =============================================================================

# 检查并设置 Termux PATH
# 用法: _setup_termux_path
_setup_termux_path() {
    # 检查 PREFIX 环境变量
    if [ -z "${PREFIX:-}" ]; then
        # 尝试常见的 Termux 路径
        if [ -d "/data/data/com.termux/files/usr" ]; then
            export PREFIX="/data/data/com.termux/files/usr"
        elif [ -d "/data/user/0/com.termux/files/usr" ]; then
            export PREFIX="/data/user/0/com.termux/files/usr"
        else
            msg "❌ 无法找到 Termux 安装目录"
            return 1
        fi
    fi

    # 设置 PATH
    case ":$PATH:" in
        *":$PREFIX/bin:"*) ;;
        *) export PATH="$PREFIX/bin:$PATH" ;;
    esac

    # 刷新命令缓存
    hash -r 2>/dev/null || true

    return 0
}

# 检查 Termux 环境是否可用
# 用法: _check_termux_env
_check_termux_env() {
    # 检查基本目录
    if [ ! -d "${PREFIX:-/data/data/com.termux/files/usr}" ]; then
        return 1
    fi

    # 检查基本命令
    if ! command -v pkg >/dev/null 2>&1; then
        msg "⚠️ pkg 命令不可用，可能不在 Termux 环境中"
        return 1
    fi

    return 0
}

# 检查 termux-api 包是否安装
# 用法: _check_termux_api_package
_check_termux_api_package() {
    if command -v termux-dialog >/dev/null 2>&1; then
        return 0
    fi

    # 尝试使用 pkg 检查
    if command -v pkg >/dev/null 2>&1; then
        if pkg list-installed | grep -q "termux-api"; then
            msg "⚠️ termux-api 已安装但命令不可用"
            msg "  尝试重新加载..."
            hash -r 2>/dev/null || true
            command -v termux-dialog >/dev/null 2>&1 && return 0
        fi
    fi

    return 1
}

# 检查 Termux:API 应用是否运行
# 用法: _check_termux_api_app
_check_termux_api_app() {
    # 简单测试 API 是否响应
    if timeout 2 termux-battery-status >/dev/null 2>&1; then
        return 0
    fi

    # 检查应用进程
    if pgrep -f "com.termux.api" >/dev/null 2>&1; then
        msg "⚠️ Termux:API 应用在运行但无响应"
        return 1
    fi

    msg "⚠️ Termux:API 应用未运行"
    return 1
}

# 美化的文本输入
# 用法: _termux_text_input "标题" "提示" [默认值] [超时(秒)]
# 返回: 成功时输出用户输入并返回 0；失败时输出默认值并返回非 0
_termux_text_input() {
    title="$1"
    prompt="$2"
    default="${3:-}"
    # 优先使用参数传入的超时，其次使用环境变量 _TERMUX_DIALOG_TIMEOUT，默认 60 秒
    dialog_timeout="${4:-${_TERMUX_DIALOG_TIMEOUT:-60}}"

    # 基本调试
    msg "[DEBUG] _termux_text_input 开始"
    msg "[DEBUG] 标题: $title"
    msg "[DEBUG] 提示: $prompt"
    msg "[DEBUG] 默认值: $default"
    msg "[DEBUG] 超时: $dialog_timeout"

    # 检查 termux-dialog 可用性
    if ! command -v termux-dialog >/dev/null 2>&1; then
        msg "⚠️ $(i18n "termux_dialog_unavailable" "termux-dialog 不可用，使用默认值")"
        printf '%s' "$default"
        return 1
    fi

    # 生成安全的临时文件（优先使用 mktemp）
    temp_dir="${TMPDIR:-/data/local/tmp}"
    if command -v mktemp >/dev/null 2>&1; then
        temp_file="$(mktemp "$temp_dir/termux_input.XXXXXXXX" 2>/dev/null || mktemp /tmp/termux_input.XXXXXXXX 2>/dev/null || printf '%s' "$temp_dir/termux_input_${$}_$RANDOM")"
    else
        temp_file="$temp_dir/termux_input_${$}_$RANDOM"
        : >"$temp_file" 2>/dev/null || true
    fi

    # 清理函数（退出时移除文件并恢复 trap）
    cleanup() {
        [ -n "$temp_file" ] && rm -f "$temp_file" 2>/dev/null || true
        trap - EXIT
    }
    trap cleanup EXIT

    msg "[DEBUG] 执行 termux-dialog（后台模式）..."

    # 在后台执行 dialog（优先使用 timeout）
    (
        if command -v timeout >/dev/null 2>&1; then
            timeout "$dialog_timeout" termux-dialog text -t "$title" -i "$prompt" >"$temp_file" 2>&1
            exit_code=$?
        else
            # 如果没有 timeout，手动后台并等待有限时间
            termux-dialog text -t "$title" -i "$prompt" >"$temp_file" 2>&1 &
            td_pid=$!
            wait_count_inner=0
            while [ "$wait_count_inner" -lt "$dialog_timeout" ]; do
                if ! kill -0 "$td_pid" 2>/dev/null; then
                    break
                fi
                sleep 1
                wait_count_inner=$((wait_count_inner + 1))
            done
            if kill -0 "$td_pid" 2>/dev/null; then
                kill "$td_pid" 2>/dev/null || true
                sleep 1
                kill -9 "$td_pid" 2>/dev/null || true
            fi
            wait "$td_pid" 2>/dev/null || true
            exit_code=$?
        fi

        # 将退出码写回文件（便于主循环解析）
        printf 'EXIT_CODE:%s\n' "$exit_code" >>"$temp_file" 2>/dev/null || true
    ) &

    # 记录后台 pid 并等待结果（略微比 dialog 超时多一段宽限）
    bg_pid=$!
    wait_count=0
    max_wait=$((dialog_timeout + 5))

    while [ "$wait_count" -lt "$max_wait" ]; do
        if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
            result="$(cat "$temp_file" 2>/dev/null || true)"

            # 提取并移除退出码
            exit_code="$(printf '%s' "$result" | grep -o 'EXIT_CODE:[0-9-]*' | grep -o '[0-9-]*' || true)"
            result="$(printf '%s' "$result" | sed '/EXIT_CODE:/d')"

            msg "[DEBUG] termux-dialog 退出码: $exit_code"
            msg "[DEBUG] termux-dialog 输出: $result"

            # 如果退出码为 0，尝试解析 JSON（尽量兼容简单情况）
            if [ "$exit_code" = "0" ] && [ -n "$result" ]; then
                code="$(printf '%s' "$result" | grep -o '\"code\":[[:space:]]*[0-9-]*' | grep -o '[0-9-]*' || true)"
                text="$(printf '%s' "$result" | sed -n 's/.*\"text\":\"\([^\"]*\)\".*/\1/p' || true)"
                # 简单反转义 \" 为 "
                text="$(printf '%s' "$text" | sed 's/\\"/\"/g' || true)"

                msg "[DEBUG] 解析结果 - code: $code, text: $text"

                if [ "$code" = "0" ] && [ -n "$text" ]; then
                    cleanup
                    printf '%s' "$text"
                    return 0
                fi
            fi

            # 如果 dialog 未能解析，尝试从剪贴板获取（更友好）
            if command -v termux-clipboard-get >/dev/null 2>&1; then
                msg "[DEBUG] 尝试从剪贴板获取..."
                clipboard_content="$(termux-clipboard-get 2>/dev/null || true)"
                if [ -n "$clipboard_content" ] && [ "$clipboard_content" != "$default" ]; then
                    msg "[DEBUG] 从剪贴板获取到: $clipboard_content"
                    cleanup
                    printf '%s' "$clipboard_content"
                    return 0
                fi
            fi

            break
        fi

        # 如果后台进程已经结束，早点退出等待循环
        if ! kill -0 "$bg_pid" 2>/dev/null; then
            sleep 1
            break
        fi

        sleep 1
        wait_count=$((wait_count + 1))
    done

    # 若后台仍然在运行，尝试优雅终止
    if kill -0 "$bg_pid" 2>/dev/null; then
        msg "[DEBUG] 终止超时的进程..."
        kill "$bg_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$bg_pid" 2>/dev/null || true
        wait "$bg_pid" 2>/dev/null || true
    fi

    # 清理并返回默认值
    cleanup
    msg "[DEBUG] 使用默认值"
    printf '%s' "$default"
    return 1
}

# 美化的确认对话框
# 用法: _termux_confirm "消息"
_termux_confirm() {
    message="$1"

    if ! command -v termux-dialog >/dev/null 2>&1; then
        return 1
    fi

    result=$(termux-dialog confirm -t "确认" -i "$message" 2>/dev/null)

    # 解析 JSON 结果
    if [ -n "$result" ]; then
        code=$(echo "$result" | grep -o '"code":[[:space:]]*[0-9-]*' | grep -o '[0-9-]*')
        text=$(echo "$result" | grep -o '"text":"[^"]*"' | sed 's/"text":"\(.*\)"/\1/')

        [ "$code" = "0" ] && [ "$text" = "yes" ]
    else
        return 1
    fi
}

# 振动
# 用法: _termux_vibrate [时长]
_termux_vibrate() {
    duration="${1:-500}"

    if command -v termux-vibrate >/dev/null 2>&1; then
        termux-vibrate -d "$duration" 2>/dev/null
    else
        msg "⚠️ termux-vibrate 命令不可用"
        return 1
    fi
}

# 电池状态（内部实现）
# 用法: _termux_battery_status
_termux_battery_status() {
    if command -v termux-battery-status >/dev/null 2>&1; then
        # 直接返回 termux-battery-status 的 JSON 输出（或原始文本）
        termux-battery-status "$@" 2>/dev/null
        return $?
    else
        msg "⚠️ termux-battery-status 命令不可用"
        return 1
    fi
}

# 剪贴板获取（内部实现）
# 用法: _termux_clipboard_get
_termux_clipboard_get() {
    if command -v termux-clipboard-get >/dev/null 2>&1; then
        termux-clipboard-get 2>/dev/null
        return $?
    else
        msg "⚠️ termux-clipboard-get 命令不可用"
        return 1
    fi
}

# 剪贴板设置（内部实现）
# 用法: _termux_clipboard_set <文本>
_termux_clipboard_set() {
    if command -v termux-clipboard-set >/dev/null 2>&1; then
        if [ $# -gt 0 ]; then
            printf '%s' "$*" | termux-clipboard-set 2>/dev/null
        else
            # 没有参数时直接调用（一些实现可能从 stdin 读取）
            termux-clipboard-set 2>/dev/null
        fi
        return $?
    else
        msg "⚠️ termux-clipboard-set 命令不可用"
        return 1
    fi
}

# Toast 提示
# 用法: _termux_toast "内容"
_termux_toast() {
    content="$1"

    if command -v termux-toast >/dev/null 2>&1; then
        termux-toast "$content" 2>/dev/null
    fi
}

# 通知
# 用法: _termux_notification "标题" "内容" [ID]
_termux_notification() {
    title="$1"
    content="$2"
    id="${3:-1000}"

    if command -v termux-notification >/dev/null 2>&1; then
        termux-notification --title "$title" --content "$content" --id "$id" 2>/dev/null
    fi
}

# 设置安全上下文
# 用法: _set_security_context
_set_security_context() {
    msg "[DEBUG] 设置安全上下文..."

    # Termux:API 的 socket 路径
    termux_socket_dir="/data/data/com.termux/files/usr/tmp"
    local_socket_dir="/data/local/tmp"

    # 创建 Termux socket 目录
    if [ ! -d "$termux_socket_dir" ]; then
        mkdir -p "$termux_socket_dir" 2>/dev/null || true
    fi

    # 创建本地 socket 目录
    if [ ! -d "$local_socket_dir" ]; then
        mkdir -p "$local_socket_dir" 2>/dev/null || true
    fi

    # 设置 Termux socket 目录权限
    if [ -d "$termux_socket_dir" ]; then
        chmod 777 "$termux_socket_dir" 2>/dev/null || true
        # 设置 SELinux 上下文
        if command -v chcon >/dev/null 2>&1; then
            chcon u:object_r:app_data_file:s0:c512,c768 "$termux_socket_dir" 2>/dev/null || true
            msg "[DEBUG] 已设置 Termux socket 目录安全上下文"
        fi
    fi

    # 设置本地 socket 目录权限
    if [ -d "$local_socket_dir" ]; then
        chmod 777 "$local_socket_dir" 2>/dev/null || true
        # 设置 SELinux 上下文
        if command -v chcon >/dev/null 2>&1; then
            chcon u:object_r:app_data_file:s0 "$local_socket_dir" 2>/dev/null || true
            msg "[DEBUG] 已设置本地 socket 目录安全上下文"
        fi
    fi

    # 创建 Termux:API 专用的 socket 文件（如果不存在）
    api_socket="/data/local/tmp/termux-api.sock"
    if [ ! -S "$api_socket" ]; then
        # 创建一个空的文件作为占位符
        touch "$api_socket" 2>/dev/null || true
        if [ -f "$api_socket" ]; then
            chmod 777 "$api_socket" 2>/dev/null || true
            # 设置特殊的 socket 类型
            if command -v chcon >/dev/null 2>&1; then
                chcon u:object_r:termux_api_socket:s0 "$api_socket" 2>/dev/null || \
                chcon u:object_r:app_data_file:s0 "$api_socket" 2>/dev/null || true
                msg "[DEBUG] 已设置 API socket 安全上下文"
            fi
        fi
    fi

    # 在 root 环境下，尝试设置 termux-dialog 的安全上下文
    if command -v chcon >/dev/null 2>&1; then
        # 尝试找到 termux-dialog 可执行文件
        termux_dialog_path=$(command -v termux-dialog 2>/dev/null)
        if [ -n "$termux_dialog_path" ] && [ -f "$termux_dialog_path" ]; then
            chcon u:object_r:exec_file:s0 "$termux_dialog_path" 2>/dev/null || true
            msg "[DEBUG] 已设置 termux-dialog 安全上下文: $termux_dialog_path"
        fi
    fi

    # 尝试启动 Termux:API 服务（如果可用）
    if command -v am >/dev/null 2>&1; then
        am startservice --user 0 com.termux.api/.TermuxApiService 2>/dev/null || true
        msg "[DEBUG] 尝试启动 Termux:API 服务"
    fi

    msg "[DEBUG] 安全上下文设置完成"
    return 0
}

# 初始化 Termux API
# 用法: _init_termux_api
_init_termux_api() {
    msg "[DEBUG] 初始化 Termux API 开始..."

    # 设置路径
    if ! _setup_termux_path; then
        msg "[DEBUG] 设置 Termux PATH 失败"
        return 1
    fi
    msg "[DEBUG] Termux PATH 设置完成"

    # 检查环境
    if ! _check_termux_env; then
        msg "[DEBUG] Termux 环境检查失败"
        return 1
    fi
    msg "[DEBUG] Termux 环境检查通过"

    # 检查 API 包
    if ! _check_termux_api_package; then
        msg "❌ termux-api 包未安装"
        msg "  请运行: pkg install termux-api"
        msg "  并从 F-Droid 安装 Termux:API 应用"
        return 1
    fi
    msg "[DEBUG] termux-api 包检查通过"

    # 不检查应用状态，避免阻塞
    msg "[DEBUG] 跳过应用状态检查，避免阻塞"

    msg "✅ Termux API 初始化完成"
    return 0
}
