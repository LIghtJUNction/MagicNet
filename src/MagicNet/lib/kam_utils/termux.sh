#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# Termux API 模块 - 公开API（完全重写）
# 说明：本文件为 thin wrapper，所有实现放在 _termux.sh；缺失内部实现会 fail-fast（返回非 0）。
# =============================================================================

# 声明依赖
if command -v depends >/dev/null 2>&1; then
    depends "soft:termux" "soft:termux-api"
fi

# 加载内部模块（严格模式：缺少内部实现即 fail-fast）
_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
# shellcheck source=_termux.sh
kam_source_impl termux || { echo "错误: 无法加载内部实现: ${_kam_utils_dir}/_termux.sh" >&2; return 1; }

# 模块状态
_TERMUX_INIT=false

# 初始化函数（按需调用）
# 用法: _ensure_init
_ensure_init() {
    if [ "$_TERMUX_INIT" = "true" ]; then
        return 0
    fi

    # 尝试设置安全上下文（尽力，不要阻塞）
    _set_security_context >/dev/null 2>&1 || true

    # 初始化 Termux API；若失败则返回非 0（fail-fast）
    if _init_termux_api; then
        _TERMUX_INIT="true"
        return 0
    fi

    return 1
}

# 文本输入
# 用法: termux_text_input "标题" "提示" [默认值]
# 返回: 若成功，标准输出为输入文本且返回 0；若失败，输出默认值并返回非 0
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

# 是否可用的小工具（初始化并检查 Termux:API 状态）
# 用法: termux_available
termux_available() {
    _ensure_init >/dev/null 2>&1 || return 1
    return 0
}

# 获取电池状态（调用内部实现并返回 termux-battery-status 的输出）
# 用法: termux_battery_status
termux_battery_status() {
    _ensure_init || return 1
    _termux_battery_status "$@"
}

# 剪贴板操作（获取）
# 用法: termux_clipboard_get
termux_clipboard_get() {
    _ensure_init || return 1
    _termux_clipboard_get "$@"
}

# 剪贴板操作（设置）
# 用法: termux_clipboard_set <text>
termux_clipboard_set() {
    _ensure_init || return 1
    _termux_clipboard_set "$@"
}

# 检查 API 状态
# 用法: termux_check_status
termux_check_status() {
    # 尝试设置 Termux PATH（非致命）
    _setup_termux_path >/dev/null 2>&1 || true
    msg "=== Termux API 状态 ==="
    msg "PREFIX: ${PREFIX:-未设置}"
    msg "PATH: $PATH"

    if command -v termux-dialog >/dev/null 2>&1; then
        msg "termux-dialog: ✓"
    else
        msg "termux-dialog: ✗ (未找到)"
    fi

    # 检查 termux-api 包是否安装/可用（使用内部检查以获得更可靠的信息）
    if command -v pkg >/dev/null 2>&1; then
        if _check_termux_api_package >/dev/null 2>&1; then
            msg "termux-api 包: ✓ (可用)"
        else
            msg "termux-api 包: ✗ (未安装或不可用)"
        fi
    else
        msg "pkg 命令: ✗"
    fi

    # 检查 Termux:API 应用是否响应（使用内部实现，可检测不可响应的情况）
    if _check_termux_api_app >/dev/null 2>&1; then
        msg "Termux:API 应用: ✓ (响应正常)"
    else
        msg "Termux:API 应用: ✗ (未响应或未运行)"
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

    msg "执行: termux-dialog text -t '测试' -i '请输入内容' （使用内部封装）"
    # 使用内部封装获取输入，避免直接解析原始 termux-dialog 输出并享受超时/剪贴板回退等机制
    result="$(_termux_text_input '测试' '请输入内容' '' 120 2>/dev/null)"
    rc=$?

    msg "原始解析结果 (stdout): $result"
    if [ "$rc" -eq 0 ]; then
        msg "✅ 成功获取输入: $result"
        return 0
    else
        msg "❌ 对话框失败或取消（返回码: $rc）"
        return $rc
    fi
}
