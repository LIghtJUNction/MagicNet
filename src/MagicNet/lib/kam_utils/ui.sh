#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 用户交互模块 - 公开API
# =============================================================================

# 加载内部模块
# 使用全局变量 _KAM_UTILS_DIR（由 kam_load 设置）或 MODPATH
_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
# shellcheck source=_ui.sh
if [ -f "${_kam_utils_dir}/_ui.sh" ]; then
    . "${_kam_utils_dir}/_ui.sh"
else
    echo "错误: 无法找到 _ui.sh: ${_kam_utils_dir}/_ui.sh" >&2
    return 1
fi

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
# 用法: ask "问题" "选项1文本" "选项2文本" "选项1命令" "选项2命令" [默认选择0或1]
ask() {
    question="$1" opt1_text="$2" opt2_text="$3" opt1_cmd="$4" opt2_cmd="$5"
    default_selected="${6:-0}"

    # 检查是否为 i18n 键值（不包含空格或特殊字符）
    if printf '%s' "$question" | grep -q '^[[:alpha:]_][[:alnum:]_]*$'; then
        question=$(i18n "$question")
    fi

    if printf '%s' "$opt1_text" | grep -q '^[[:alpha:]_][[:alnum:]_]*$'; then
        opt1_text=$(i18n "$opt1_text")
    fi

    if printf '%s' "$opt2_text" | grep -q '^[[:alpha:]_][[:alnum:]_]*$'; then
        opt2_text=$(i18n "$opt2_text")
    fi

    # 当前选中的选项（0 = 选项1，1 = 选项2）
    _ask_selected="$default_selected"
    
    # 显示问题
    msg "$question"
    msg "$(i18n 'volume_key_hint')"
    newline
    
    # 循环等待用户选择
    while :; do
        # 显示选项（带选中标记）
        if [ "$_ask_selected" -eq 0 ]; then
            msg "[*] $opt1_text"
            msg "[ ] $opt2_text"
        else
            msg "[ ] $opt1_text"
            msg "[*] $opt2_text"
        fi
        
        # 等待按键
        _ask_key=$(wait_key_up_down)
        
        case "$_ask_key" in
            up)
                # 上键：切换选项
                if [ "$_ask_selected" -eq 0 ]; then
                    _ask_selected=1
                else
                    _ask_selected=0
                fi
                # 清除上次显示的选项（向上移动2行并清除）
                printf '\033[2A\033[K\033[1B\033[K\033[1A'
                ;;
            down)
                # 下键：确认当前选项
                newline
                if [ "$_ask_selected" -eq 0 ]; then
                    msg "$(i18n 'confirmed'): $opt1_text"
                    eval "$opt1_cmd"
                else
                    msg "$(i18n 'confirmed'): $opt2_text"
                    eval "$opt2_cmd"
                fi
                newline
                return
                ;;
        esac
    done
}



# 确认对话框
# 用法: confirm "确定要删除吗？" && 命令
confirm() {
    message="$1"
    _confirm_choice=1  # 默认取消
    
    # 使用 ask 函数实现确认对话框
    ask "$message" "confirm_yes" "confirm_no" \
        '_confirm_choice=0' \
        '_confirm_choice=1'
    
    return $_confirm_choice
}

# 多选项选择函数（API）
# 用法: multi_select "标题" "选项1" "选项2" "选项3" ...
# 返回: 选中的索引（从0开始）
multi_select() {
    # 重定向所有输出到 stderr，只让结果通过 stdout 返回
    _multi_select_impl "$@" >&2
    echo "$MULTI_SELECT_RESULT"
}

# 语言选择函数（API）
# 用法: select_language "语言1:locale1" "语言2:locale2" ...
select_language() {
    # 默认语言选项
    if [ $# -eq 0 ]; then
        set -- "中文:zh_CN.UTF-8" "English:en_US.UTF-8" "日本語:ja_JP.UTF-8" "한국어:ko_KR.UTF-8"
    fi
    
    # 提取语言名称
    lang_names=""
    for lang_pair in "$@"; do
        lang_name="${lang_pair%%:*}"
        lang_names="$lang_names $lang_name"
    done
    
    # 调用内部实现
    _multi_select_impl "选择语言 / Select Language" $lang_names
    choice="$MULTI_SELECT_RESULT"
    
    # 设置语言环境变量
    i=0
    for lang_pair in "$@"; do
        if [ "$i" -eq "$choice" ]; then
            lang_locale="${lang_pair#*:}"
            export LANG="$lang_locale"
            break
        fi
        i=$((i + 1))
    done
}

# 二进制提示函数
# 用法: binary_prompt "默认值" "提示1" "提示2" ...
# 返回: 最终的二进制值
binary_prompt() {
    _binary_prompt_impl "$@" >&2
    echo "$BINARY_PROMPT_RESULT"
}

# 分割线函数
# 用法: divider [字符] [宽度]
divider() {
    _divider_impl "$@"
}

# 颜色测试函数
# 用法: color_test
color_test() {
    _color_test_impl
}

# 文本输入框函数
# 用法: text_input "标题" "提示" [默认值]
text_input() {
    _text_input_impl "$@"
    echo "$TEXT_INPUT_RESULT"
}

# 国际化函数
set_i18n() {
    _set_i18n_impl "$@"
}

i18n() {
    _i18n_impl "$@"
}
