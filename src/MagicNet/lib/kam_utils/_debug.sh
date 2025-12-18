#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 调试模块 - 内部函数（非公开API）
# =============================================================================

# 检查调试模式是否开启
_kam_debug_enabled() {
    [ "${KAM_DEBUG:-0}" = "1" ]
}

# 调试输出函数（仅在调试开启时输出）
# 用法: _kam_debug_log "消息" [标签]
_kam_debug_log() {
    _kam_debug_enabled || return 0
    
    msg="$1"
    tag="${2:-DEBUG}"
    
    # 输出到 stderr，带上时间戳和标签
    printf '[%s] [%s] %s\n' "$(date '+%H:%M:%S')" "$tag" "$msg" >&2
}

# 调试输出函数（带缩进）
# 用法: _kam_debug_indent "消息" 缩进级别 [标签]
_kam_debug_indent() {
    _kam_debug_enabled || return 0
    
    msg="$1"
    level="${2:-0}"
    tag="${3:-DEBUG}"
    
    # 生成缩进
    indent=""
    i=0
    while [ "$i" -lt "$level" ]; do
        indent="${indent}  "
        i=$((i + 1))
    done
    
    printf '[%s] [%s] %s%s\n' "$(date '+%H:%M:%S')" "$tag" "$indent" "$msg" >&2
}

# 调试变量值
# 用法: _kam_debug_var "变量名" [标签]
_kam_debug_var() {
    _kam_debug_enabled || return 0
    
    var_name="$1"
    tag="${2:-DEBUG}"
    
    eval "var_value=\${$var_name:-}"
    printf '[%s] [%s] %s = %s\n' "$(date '+%H:%M:%S')" "$tag" "$var_name" "$var_value" >&2
}

# 调试函数调用
# 用法: _kam_debug_call "函数名" [参数...]
_kam_debug_call() {
    _kam_debug_enabled || return 0
    
    func_name="$1"
    shift
    
    printf '[%s] [CALL] %s %s\n' "$(date '+%H:%M:%S')" "$func_name" "$*" >&2
}

# 调试函数返回
# 用法: _kam_debug_return "函数名" 返回值
_kam_debug_return() {
    _kam_debug_enabled || return 0
    
    func_name="$1"
    retval="$2"
    
    printf '[%s] [RETURN] %s = %s\n' "$(date '+%H:%M:%S')" "$func_name" "$retval" >&2
}

# 调试开始/结束标记
# 用法: _kam_debug_block "块名称"
_kam_debug_block_start() {
    _kam_debug_enabled || return 0
    printf '[%s] [BLOCK START] %s\n' "$(date '+%H:%M:%S')" "$1" >&2
}

_kam_debug_block_end() {
    _kam_debug_enabled || return 0
    printf '[%s] [BLOCK END] %s\n' "$(date '+%H:%M:%S')" "$1" >&2
}

# 调试错误
# 用法: _kam_debug_error "错误消息"
_kam_debug_error() {
    _kam_debug_enabled || return 0
    printf '[%s] [ERROR] %s\n' "$(date '+%H:%M:%S')" "$1" >&2
}

# 调试警告
# 用法: _kam_debug_warn "警告消息"
_kam_debug_warn() {
    _kam_debug_enabled || return 0
    printf '[%s] [WARN] %s\n' "$(date '+%H:%M:%S')" "$1" >&2
}