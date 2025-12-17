#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 用户交互模块 - 公开API
# =============================================================================

# 加载内部模块
_kam_utils_dir="$(dirname "${0}")"
[ -f "${_kam_utils_dir}/_ui.sh" ] && . "${_kam_utils_dir}/_ui.sh"

# 获取按键事件
get_key() {
    _get_key_impl
}

# 等待任意按键
wait_key_any() { 
    null get_key
}

# 等待上下键
wait_key_up_down() {
    _wait_key_up_down_impl
}

# 等待上下键+电源键
wait_key_up_down_power() {
    _wait_key_up_down_power_impl
}

# 等待上键
wait_key_up() {
    _wait_key_up_impl
}

# 等待下键
wait_key_down() {
    _wait_key_down_impl
}

# 等待电源键
wait_key_power() {
    _wait_key_power_impl
}

# 二选一交互
# 用法: ask "问题" "选项1文本" "选项2文本" "选项1命令" "选项2命令"
ask() {
    local question="$1" opt1_text="$2" opt2_text="$3" opt1_cmd="$4" opt2_cmd="$5"
    
    # 检查是否为 i18n 键值（不包含空格或特殊字符）
    if [[ "$question" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        question=$(i18n "$question")
    fi
    
    if [[ "$opt1_text" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        opt1_text=$(i18n "$opt1_text")
    fi
    
    if [[ "$opt2_text" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        opt2_text=$(i18n "$opt2_text")
    fi
    
    msg "$question"
    msg "👆:$opt1_text"
    msg "👇:$opt2_text"
    msg "$(i18n 'volume_key_hint')"
    
    # 等待按键
    local key
    key=$(wait_key_up_down_power)
    
    case "$key" in
        up)
            newline
            msg "$(i18n 'selected'): $opt1_text"
            eval "$opt1_cmd"
            ;;
        down)
            newline
            msg "$(i18n 'selected'): $opt2_text"
            eval "$opt2_cmd"
            ;;
        power)
            newline
            msg "$(i18n 'cancel')"
            ;;
    esac
    newline
}

# 确认对话框
# 用法: confirm "确定要删除吗？" && 命令
confirm() {
    local message="$1"
    local result
    result=$(choice "$message" "确定" "取消" --default=1)
    
    case "$result" in
        0) return 0 ;;  # 确定
        1|cancel) return 1 ;;  # 取消
    esac
}