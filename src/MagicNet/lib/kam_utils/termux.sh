#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# Termux API 模块 - 公开API（完全重写）
# =============================================================================

# 声明依赖
if command -v depends >/dev/null 2>&1; then
    depends "soft:termux" "soft:termux-api"
fi

# 加载内部模块
_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
if [ -f "${_kam_utils_dir}/_termux.sh" ]; then
    . "${_kam_utils_dir}/_termux.sh"
else
    msg "错误: 无法找到 _termux.sh: ${_kam_utils_dir}/_termux.sh" >&2
    return 1
fi

# 模块状态
_TERMUX_INIT=false

# 初始化函数（按需调用）
# 用法: _ensure_init
_ensure_init() {
    if [ "$_TERMUX_INIT" = "true" ]; then
        return 0
    fi
    
    # 总是尝试设置安全上下文
    if [ -f "${_kam_utils_dir}/_termux.sh" ]; then
        . "${_kam_utils_dir}/_termux.sh"
        _set_security_context
    fi
    
    # 尝试初始化，但不因失败而阻止执行
    _init_termux_api
    _TERMUX_INIT="true"
    return 0
}

# 文本输入
# 用法: termux_text_input "标题" "提示" [默认值]
termux_text_input() {
    _ensure_init || {
        echo "${3:-}"
        return 1
    }
    
    _termux_text_input "$@"
}

# 确认对话框
# 用法: termux_confirm "消息"
termux_confirm() {
    _ensure_init || return 1
    _termux_confirm "$@"
}

# 振动
# 用法: termux_vibrate [时长]
termux_vibrate() {
    _ensure_init || return 1
    _termux_vibrate "$@"
}

# Toast 提示
# 用法: termux_toast "内容"
termux_toast() {
    _ensure_init || return 1
    _termux_toast "$@"
}

# 通知
# 用法: termux_notification "标题" "内容" [ID]
termux_notification() {
    _ensure_init || return 1
    _termux_notification "$@"
}

# 检查 API 状态
# 用法: termux_check_status
termux_check_status() {
    msg "=== Termux API 状态 ==="
    msg "PREFIX: ${PREFIX:-未设置}"
    msg "PATH: $PATH"
    
    if command -v termux-dialog >/dev/null 2>&1; then
        msg "termux-dialog: ✓"
    else
        msg "termux-dialog: ✗"
    fi
    
    if command -v pkg >/dev/null 2>&1; then
        if pkg list-installed 2>/dev/null | grep -q "termux-api"; then
            msg "termux-api 包: ✓"
        else
            msg "termux-api 包: ✗"
        fi
    else
        msg "pkg 命令: ✗"
    fi
    
    if pgrep -f "com.termux.api" >/dev/null 2>&1; then
        msg "Termux:API 应用: ✓ (运行中)"
    else
        msg "Termux:API 应用: ✗ (未运行)"
    fi
    
    msg "===================="
}

# 快速测试
# 用法: termux_test
termux_test() {
    msg "测试 Termux API..."
    
    if _ensure_init; then
        msg "✅ 初始化成功"
        
        # 测试振动
        msg "测试振动..."
        termux_vibrate 200
        
        # 测试 Toast
        msg "测试 Toast..."
        termux_toast "Termux API 测试成功！"
        
        # 测试通知
        msg "测试通知..."
        termux_notification "测试" "Termux API 正常工作" 9999
        
        msg "✅ 所有测试完成"
    else
        msg "❌ 初始化失败"
    fi
}

# 调试 termux-dialog
# 用法: termux_debug_dialog
termux_debug_dialog() {
    msg "调试 termux-dialog..."
    
    if ! command -v termux-dialog >/dev/null 2>&1; then
        msg "❌ termux-dialog 命令不存在"
        return 1
    fi
    
    msg "执行: termux-dialog text -t '测试' -i '请输入内容'"
    result=$(termux-dialog text -t "测试" -i "请输入内容" 2>&1)
    
    msg "原始输出:"
    msg "$result"
    
    if [ -n "$result" ]; then
        code=$(echo "$result" | grep -o '"code":[[:space:]]*[0-9-]*' | grep -o '[0-9-]*')
        text=$(echo "$result" | grep -o '"text":"[^"]*"' | sed 's/"text":"\(.*\)"/\1/')
        
        msg "解析结果:"
        msg "  code: $code"
        msg "  text: $text"
        
        if [ "$code" = "0" ]; then
            msg "✅ 成功获取输入: $text"
        else
            msg "❌ 对话框失败或取消"
        fi
    fi
}