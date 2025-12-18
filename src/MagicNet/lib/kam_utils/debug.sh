#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 调试模块 - 公开API
# =============================================================================

# 设置默认调试模式为关闭（如果未设置）
: "${KAM_DEBUG:=0}"

# 加载内部模块
# 使用全局变量 _KAM_UTILS_DIR（由 kam_load 设置）或 MODPATH
_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
# shellcheck source=_debug.sh
if [ -f "${_kam_utils_dir}/_debug.sh" ]; then
    . "${_kam_utils_dir}/_debug.sh"
else
    echo "错误: 无法找到 _debug.sh: ${_kam_utils_dir}/_debug.sh" >&2
    return 1
fi

# 开启调试模式
# 用法: debug_on
debug_on() {
    export KAM_DEBUG=1
    _kam_debug_log "$(i18n "debug_enabled" "调试模式已开启")" "DEBUG"
}

# 关闭调试模式
# 用法: debug_off
debug_off() {
    export KAM_DEBUG=0
    _kam_debug_log "$(i18n "debug_disabled" "调试模式已关闭")" "DEBUG"
}

# 切换调试模式
# 用法: debug_toggle
debug_toggle() {
    if [ "${KAM_DEBUG:-0}" = "1" ]; then
        debug_off
    else
        debug_on
    fi
}

# 检查调试状态
# 用法: debug_status
debug_status() {
    if _kam_debug_enabled; then
        echo "$(i18n "debug_status_on" "调试模式：开启 (KAM_DEBUG=1)")"
    else
        echo "$(i18n "debug_status_off" "调试模式：关闭 (KAM_DEBUG=0)")"
    fi
}

# 调试输出（公共接口）
# 用法: debug_log "消息" [标签]
debug_log() {
    _kam_debug_log "$@"
}

# 调试变量（公共接口）
# 用法: debug_var "变量名" [标签]
debug_var() {
    _kam_debug_var "$@"
}

# 调试块开始（公共接口）
# 用法: debug_block_start "块名称"
debug_block_start() {
    _kam_debug_block_start "$@"
}

# 调试块结束（公共接口）
# 用法: debug_block_end "块名称"
debug_block_end() {
    _kam_debug_block_end "$@"
}