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
# 用法: _termux_text_input "标题" "提示" [默认值]
_termux_text_input() {
    title="$1"
    prompt="$2"
    default="${3:-}"
    
    # 调试信息
    msg "[DEBUG] _termux_text_input 开始"
    msg "[DEBUG] 标题: $title"
    msg "[DEBUG] 提示: $prompt"
    msg "[DEBUG] 默认值: $default"
    
    # 检查命令是否可用
    if ! command -v termux-dialog >/dev/null 2>&1; then
        msg "⚠️ $(i18n "termux_dialog_unavailable" "termux-dialog 不可用，使用默认值")"
        echo "$default"
        return 1
    fi
    
    # 创建临时文件存储结果
    temp_file="/data/local/tmp/termux_input_$$"
    
    # 清理函数
    cleanup() {
        rm -f "$temp_file" 2>/dev/null || true
    }
    
    # 确保清理
    trap cleanup EXIT
    
    msg "[DEBUG] 执行 termux-dialog（后台模式）..."
    
    # 在后台执行，使用超时
    (
        # 设置超时
        if command -v timeout >/dev/null 2>&1; then
            timeout 10 termux-dialog text -t "$title" -i "$prompt" >"$temp_file" 2>&1
            exit_code=$?
        else
            # 如果没有 timeout 命令，直接执行
            termux-dialog text -t "$title" -i "$prompt" >"$temp_file" 2>&1
            exit_code=$?
        fi
        
        # 记录退出码
        echo "EXIT_CODE:$exit_code" >>"$temp_file"
    ) &
    
    # 获取后台进程 PID
    bg_pid=$!
    
    # 等待最多 15 秒
    wait_count=0
    max_wait=15
    
    while [ $wait_count -lt $max_wait ]; do
        # 检查临时文件是否存在且有内容
        if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
            # 读取结果
            result=$(cat "$temp_file")
            
            # 提取退出码
            exit_code=$(echo "$result" | grep -o "EXIT_CODE:[0-9-]*" | grep -o "[0-9-]*")
            
            # 移除退出码行
            result=$(echo "$result" | sed '/EXIT_CODE:/d')
            
            msg "[DEBUG] termux-dialog 退出码: $exit_code"
            msg "[DEBUG] termux-dialog 输出: $result"
            
            # 解析 JSON 结果
            if [ "$exit_code" = "0" ] && [ -n "$result" ]; then
                code=$(echo "$result" | grep -o '"code":[[:space:]]*[0-9-]*' | grep -o '[0-9-]*')
                text=$(echo "$result" | grep -o '"text":"[^"]*"' | sed 's/"text":"\(.*\)"/\1/')
                
                msg "[DEBUG] 解析结果 - code: $code, text: $text"
                
                if [ "$code" = "0" ] && [ -n "$text" ]; then
                    cleanup
                    echo "$text"
                    return 0
                fi
            fi
            
            # 如果解析失败，尝试从剪贴板获取
            if command -v termux-clipboard-get >/dev/null 2>&1; then
                msg "[DEBUG] 尝试从剪贴板获取..."
                clipboard_content=$(termux-clipboard-get 2>/dev/null)
                if [ -n "$clipboard_content" ] && [ "$clipboard_content" != "$default" ]; then
                    msg "[DEBUG] 从剪贴板获取到: $clipboard_content"
                    cleanup
                    echo "$clipboard_content"
                    return 0
                fi
            fi
            
            break
        fi
        
        # 检查后台进程是否还在运行
        if ! kill -0 $bg_pid 2>/dev/null; then
            # 进程已结束
            sleep 1
            break
        fi
        
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    # 如果后台进程还在运行，终止它
    if kill -0 $bg_pid 2>/dev/null; then
        msg "[DEBUG] 终止超时的进程..."
        kill $bg_pid 2>/dev/null || true
        sleep 1
        kill -9 $bg_pid 2>/dev/null || true
    fi
    
    # 清理
    cleanup
    
    # 提示用户手动输入
    msg ""
    msg "============================================"
    msg "$(i18n "input_failed")"
    msg "$(i18n "config_file_path"): $MODPATH/mihomo/config.yaml"
    msg "$(i18n "find_url_line")"
    msg "============================================"
    msg ""
    
    # 返回默认值
    msg "[DEBUG] 使用默认值"
    echo "$default"
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