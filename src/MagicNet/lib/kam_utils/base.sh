#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 基础工具模块 - 公开API
# =============================================================================

# 加载内部模块
_kam_utils_dir="$(dirname "${0}")"
[ -f "${_kam_utils_dir}/_base.sh" ] && . "${_kam_utils_dir}/_base.sh"

# 基础打印函数
pprint() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$1"
    else
        # 兼容非 Magisk 环境
        [ -z "$OUTFD" ] && echo "$1" || echo "ui_print $1\nui_print" >>"/proc/self/fd/$OUTFD"
    fi
}

# 带前缀的打印
msg() { pprint "> $1"; }
err() { pprint "⚠️ $1"; }
warn() { pprint "⚠️ $1"; }
info() { pprint "ℹ️ $1"; }

# 优雅的换行函数
newline() { 
    local count="${1:-1}"
    while [ $count -gt 0 ]; do 
        pprint ""
        count=$((count-1))
    done
}

# 打印多行
plns() { for line in "$@"; do pprint "$line"; done; }

# 安全删除
rmrf() { [ -e "$1" ] && rm -rf "$@" 2>/dev/null; }

# 复制并设置权限
cp_perm() {
    local src="$1" dest="$2" perm="${3:-0644}"
    [ -f "$src" ] && cp "$src" "$dest" && chmod "$perm" "$dest"
}

# 设置目录权限
set_perm_dir() { find "$@" -type d -exec chmod 0755 {} + 2>/dev/null; }

# 设置文件权限
set_perm_file() { find "$@" -type f -exec chmod "${1:-0644}" {} + 2>/dev/null; }

# 设置可执行权限
set_exec() { chmod a+x "$@" 2>/dev/null; }

# 设置 SELinux 上下文
set_selinux() { chcon -R u:object_r:system_file:s0 "$@" 2>/dev/null; }

# 运行并忽略输出
null() { "$@" >/dev/null 2>&1; }

# 运行并忽略错误
err() { "$@" 2>/dev/null; }

# 检查命令存在
cmd() { command -v "$1" >/dev/null 2>&1; }

# 获取脚本目录
dir() { dirname "$(readlink -f "$1")"; }

# 字符串比较
eq() {
    local str="$1"
    shift
    for target in "$@"; do [ "$target" = "$str" ] && return; done
    return 1
}

# 格式化日期
# 用法: fdate
fdate() {
    date +"%Y-%m-%d %H:%M:%S.%3N"
}

# 日志记录
# 用法: log "INFO|ERROR|WARNING|DEBUG" "消息"
log() {
    local level="$1"
    local message="$2"
    local logfile="${LOG_FILE:-}"
    
    # 定义颜色
    local normal="\033[0m"
    local red="\033[1;31m"
    local green="\033[1;32m"
    local yellow="\033[1;33m"
    local blue="\033[1;34m"
    
    # 根据级别选择颜色
    local color
    case $level in
        INFO) color="${blue}" ;;
        ERROR) color="${red}" ;;
        WARNING) color="${yellow}" ;;
        DEBUG) color="${green}" ;;
        *) color="${green}" ;;
    esac
    
    # 格式化消息
    local current_time
    current_time=$(fdate)
    local formatted_message="${current_time} [$level]: $message"
    
    # 输出到控制台或日志文件
    if [ -t 1 ]; then
        printf "${color}${formatted_message}${normal}\n"
    elif [ -n "$logfile" ]; then
        # 确保日志文件存在
        [ ! -f "$logfile" ] && touch "$logfile" && chmod 600 "$logfile"
        echo "${formatted_message}" >> "$logfile" 2>&1
    else
        echo "${formatted_message}"
    fi
}