#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 基础工具模块 - 内部函数（非公开API）
# =============================================================================

# 基础打印函数（内部使用）
_pure_print() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$1"
    else
        # 兼容非 Magisk 环境
        [ -z "$OUTFD" ] && echo "$1" || echo "ui_print $1\nui_print" >>"/proc/self/fd/$OUTFD"
    fi
}

# 运行并忽略输出
_null() { "$@" >/dev/null 2>&1; }

# 运行并忽略错误
_err() { "$@" 2>/dev/null; }

# 检查命令存在
_cmd() { command -v "$1" >/dev/null 2>&1; }

# 获取脚本目录
_dir() { dirname "$(readlink -f "$1")"; }

# 字符串比较
_eq() {
    local str="$1"
    shift
    for target in "$@"; do [ "$target" = "$str" ] && return; done
    return 1
}

# 获取 kam_utils 目录（内部使用）
_get_kam_utils_dir() {
    # 尝试多种方式获取脚本目录
    local script_dir="${KAM_UTILS_DIR:-}"
    [ -n "$script_dir" ] && echo "$script_dir" && return
    
    # 如果 kam-utils.sh 被加载，使用其路径
    if [ -n "$KAM_UTILS_PATH" ]; then
        echo "${KAM_UTILS_PATH%/*}/kam_utils"
        return
    fi
    
    # 最后尝试当前目录
    echo "$(dirname "$0")/kam_utils"
}

# 加载指定模块（内部使用）
_load_module() {
    local module="$1"
    local kam_utils_dir
    kam_utils_dir=$(_get_kam_utils_dir)
    
    local module_file="${kam_utils_dir}/${module}.sh"
    [ -f "$module_file" ] || { err "模块不存在: $module"; return 1; }
    
    # 加载模块
    . "$module_file" || { err "加载模块失败: $module"; return 1; }
    
    # 标记模块已加载
    eval "KAM_LOADED_${module}=1"
}