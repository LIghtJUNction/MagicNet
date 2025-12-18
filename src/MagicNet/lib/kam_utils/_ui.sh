#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 用户交互模块 - 内部函数（非公开API）
# =============================================================================

# 获取按键事件（内部实现）
_get_key_impl() {
    getevent -qlc 1 2>/dev/null | awk '$2=="EV_KEY" && $4=="DOWN" {print $3; exit}'
}

# 等待任意按键（内部实现）
_wait_key_any_impl() {
    # 直接调用基础按键获取实现，返回第一个按下的按键（如果没有 getevent，可能为空）
    _get_key_impl
}

# 等待上下键（内部实现）
_wait_key_up_down_impl() {
    _wait_key_up_down_impl_key=""
    while :; do
        _wait_key_up_down_impl_key=$(_get_key_impl)
        case "$_wait_key_up_down_impl_key" in
            KEY_VOLUMEUP|KEY_VOLUMEDOWN)
                echo "$_wait_key_up_down_impl_key" | sed 's/KEY_VOLUME//' | tr '[:upper:]' '[:lower:]'
                return
                ;;
        esac
    done
}

# 等待上下键+电源键（内部实现）
_wait_key_up_down_power_impl() {
    _wait_key_up_down_power_impl_key=""
    while :; do
        _wait_key_up_down_power_impl_key=$(_get_key_impl)
        case "$_wait_key_up_down_power_impl_key" in
            KEY_VOLUMEUP|KEY_VOLUMEDOWN|KEY_POWER)
                case "$_wait_key_up_down_power_impl_key" in
                    KEY_VOLUMEUP) echo "up" ;;
                    KEY_VOLUMEDOWN) echo "down" ;;
                    KEY_POWER) echo "power" ;;
                esac
                return
                ;;
        esac
    done
}

# 等待上键（内部实现）
_wait_key_up_impl() {
    _wait_key_up_impl_key=""
    while :; do
        _wait_key_up_impl_key=$(_get_key_impl)
        [ "$_wait_key_up_impl_key" = "KEY_VOLUMEUP" ] && return
    done
}

# 等待下键（内部实现）
_wait_key_down_impl() {
    _wait_key_down_impl_key=""
    while :; do
        _wait_key_down_impl_key=$(_get_key_impl)
        [ "$_wait_key_down_impl_key" = "KEY_VOLUMEDOWN" ] && return
    done
}

# 等待电源键（内部实现）
_wait_key_power_impl() {
    _wait_key_power_impl_key=""
    while :; do
        _wait_key_power_impl_key=$(_get_key_impl)
        [ "$_wait_key_power_impl_key" = "KEY_POWER" ] && return
    done
}

# 显示音量键提示（内部实现）
_show_volume_key_hint() {
    msg "$(i18n "volume_key_hint")"
}

# 显示分割线（内部实现）
# 用法: _divider_impl [字符] [宽度]
_divider_impl() {
    char="${1:-=}"
    width="${2:-80}"

    # 获取终端宽度，如果获取失败则使用默认宽度
    terminal_width=$(stty size 2>/dev/null | cut -d' ' -f2 2>/dev/null)

    # 检查 terminal_width 是否为数字
    if [ -n "$terminal_width" ] && [ "$terminal_width" -eq "$terminal_width" ] 2>/dev/null; then
        # 如果指定宽度大于终端宽度，使用终端宽度
        if [ "$width" -gt "$terminal_width" ]; then
            width="$terminal_width"
        fi
    fi

    # 生成分割线
    divider=""
    i=0
    while [ "$i" -lt "$width" ]; do
        divider="${divider}${char}"
        i=$((i + 1))
    done

    _select_print_impl "$divider"
}

# 颜色测试（内部实现）

# 用法: _color_test_impl

_color_test_impl() {

    _select_print_impl "颜色测试 - Color Test"

    _select_print_impl ""



    # 基础背景色测试

    _select_print_impl "基础背景色："

    printf '\033[40m  黑色  \033[0m\033[41m  红色  \033[0m\033[42m  绿色  \033[0m\033[43m  黄色  \033[0m\n' >&2

    printf '\033[44m  蓝色  \033[0m\033[45m  洋红  \033[0m\033[46m  青色  \033[0m\033[47m  白色  \033[0m\n' >&2

    _select_print_impl ""



    # 高亮背景色测试

    _select_print_impl "高亮背景色："

    printf '\033[100m  亮黑  \033[0m\033[101m  亮红  \033[0m\033[102m  亮绿  \033[0m\033[103m  亮黄  \033[0m\n' >&2

    printf '\033[104m  亮蓝  \033[0m\033[105m亮洋红 \033[0m\033[106m  亮青  \033[0m\033[107m  亮白  \033[0m\n' >&2

    _select_print_impl ""



    # 前景色测试

    _select_print_impl "前景色（文字颜色）："

    printf '\033[30m■黑色■\033[0m \033[31m■红色■\033[0m \033[32m■绿色■\033[0m \033[33m■黄色■\033[0m\n' >&2

    printf '\033[34m■蓝色■\033[0m \033[35m■洋红■\033[0m \033[36m■青色■\033[0m \033[37m■白色■\033[0m\n' >&2

    _select_print_impl ""



    # 高亮前景色测试

    _select_print_impl "高亮前景色："

    printf '\033[90m■亮黑■\033[0m \033[91m■亮红■\033[0m \033[92m■亮绿■\033[0m \033[93m■亮黄■\033[0m\n' >&2

    printf '\033[94m■亮蓝■\033[0m \033[95m■亮洋红■\033[0m \033[96m■亮青■\033[0m \033[97m■亮白■\033[0m\n' >&2

    _select_print_impl ""



    # 组合测试（前景色+背景色）

    _select_print_impl "组合测试（前景色+背景色）："

    printf '\033[37m\033[41m■白字红底■\033[0m \033[33m\033[44m■黄字蓝底■\033[0m \033[30m\033[46m■黑字青底■\033[0m\n' >&2

    printf '\033[97m\033[105m■亮白字亮洋红底■\033[0m \033[93m\033[102m■亮黄字亮绿底■\033[0m\n' >&2

    _select_print_impl ""



    # 如果在安装环境，提示可能不支持颜色

    if command -v ui_print >/dev/null 2>&1; then

        _select_print_impl "注意：在安装环境中可能不支持 ANSI 颜色代码"

    fi

}

# 通用打印函数（兼容安装环境和终端环境）
_select_print_impl() {
    # 首选内部的纯打印实现（如果存在），它会处理 ui_print、OUTFD 等安装环境细节
    if command -v _pure_print >/dev/null 2>&1; then
        _pure_print "$1"
        return 0
    fi

    # 回退到公开的 pprint（如果可用）
    if command -v pprint >/dev/null 2>&1; then
        pprint "$1"
        return 0
    fi

    # 如果存在安装环境的 ui_print，使用之
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$1"
        return 0
    fi

    # 如果设置了 OUTFD（某些安装器通过 /proc/self/fd/$OUTFD 接收 ui_print 指令），使用该通道
    if [ -n "${OUTFD:-}" ]; then
        # 写入两行：一行 ui_print <msg>，一行 ui_print 作为终止符（兼容部分安装器协议）
        printf '%s\n' "ui_print $1" >>"/proc/self/fd/$OUTFD" 2>/dev/null || printf '%s\n' "$1"
        printf '%s\n' "ui_print" >>"/proc/self/fd/$OUTFD" 2>/dev/null || true
        return 0
    fi

    # 回退到普通 echo（终端或无法识别的环境）
    printf '%s\n' "$1"
}

# 检查环境是否支持增量更新（一次性检测并缓存结果）
_incremental_update_check_impl() {
    # 已经检测过，直接返回
    if [ "${_UI_INC_CHECKED:-0}" = "1" ]; then
        return 0
    fi

    _UI_INC_CHECKED=1
    _UI_INC_SUPPORTED=0

    # 如果在安装环境（有 ui_print）或 stdout 不是一个 TTY，则不支持增量更新
    if command -v ui_print >/dev/null 2>&1 || [ ! -t 1 ]; then
        return 0
    fi

    # TERM 不应为空或为 dumb
    term="${TERM:-}"
    if [ -z "$term" ] || [ "$term" = "dumb" ]; then
        return 0
    fi

    # 优先使用 tput 检查光标上移与清行能力
    if command -v tput >/dev/null 2>&1; then
        if tput cuu1 >/dev/null 2>&1 && tput el >/dev/null 2>&1; then
            _UI_INC_SUPPORTED=1
            return 0
        else
            # tput 存在但不支持所需能力，则认为不支持增量更新
            return 0
        fi
    fi

    # 没有 tput，但 TERM 看起来正常，保守地认为支持（避免误判导致不必要的降级）
    _UI_INC_SUPPORTED=1
    return 0
}

# 清除若干行（内部实现）
# 用法: _clear_lines_impl <count>
# 在支持增量更新的交互终端时会进行光标移动清除。否则一次性发出警告并回退为普通输出。
_clear_lines_impl() {
    count="${1:-1}"

    # 先检测环境是否支持增量更新（并缓存结果）
    _incremental_update_check_impl

    # 若不支持增量更新，发出一次性警告并回退为普通输出（不清除行）
    if [ "${_UI_INC_SUPPORTED:-0}" != "1" ]; then
        if [ "${_UI_INC_WARNED:-0}" != "1" ]; then
            _UI_INC_WARNED=1
            _select_print_impl "$(i18n "incremental_not_supported")"
        fi
        return 0
    fi

    i=0
    while [ "$i" -lt "$count" ]; do
        # 上移一行并清除整行，然后回到行首
        printf '\033[1A\033[2K\r'
        i=$((i + 1))
    done
}

# 二进制提示内部实现（拓展版）
# 用法: _binary_prompt_impl "默认值" "提示1" "提示2" ...
_binary_prompt_impl() {
    default_value="$1"
    current_value="$default_value"
    current_pos=0
    length=${#current_value}

    # 构建提示数组
    shift
    hints="$@"
    hint_count=0
    for hint in "$@"; do
        hint_count=$((hint_count + 1))
    done

    # 显示使用指南
    _select_print_impl "$(_i18n_binary "usage_guide")"
    _select_print_impl "$(_i18n_binary "volume_up")"
    _select_print_impl "$(_i18n_binary "volume_down")"
    _select_print_impl "$(_i18n_binary "final_confirm")"
    _select_print_impl ""

    # 显示初始状态
    if ! command -v getevent >/dev/null 2>&1; then
        # 非交互环境，显示一次就返回
        # 显示提示行
        hint_display=""
        i=0
        while [ "$i" -lt "$length" ]; do
            if [ "$i" -lt "$hint_count" ]; then
                # 获取第 i+1 个参数
                j=0
                for hint in "$@"; do
                    if [ "$j" -eq "$i" ]; then
                        hint_display="${hint_display}${hint} "
                        break
                    fi
                    j=$((j + 1))
                done
            else
                hint_display="${hint_display}    "
            fi
            i=$((i + 1))
        done
        _select_print_impl "${hint_display}"

        # 显示二进制行
        display=""
        i=0
        while [ "$i" -lt "$length" ]; do
            char="${current_value:$i:1}"
            if [ "$char" = "1" ]; then
                char_display="✅"  # 启用
            else
                char_display="❌"  # 禁用
            fi

            if [ "$i" -eq 0 ]; then
                display="${display}>${char_display}"
            else
                display="${display} ${char_display}"
            fi
            i=$((i + 1))
        done
        _select_print_impl "$display"

        # 显示默认值行
        default_display="默认: $default_value"
        _select_print_impl "$default_display"

        _select_print_impl ""
        _select_print_impl "✗ getevent 不可用，使用默认值"
        BINARY_PROMPT_RESULT="$current_value"
        return
    fi

    # 主交互循环
    while :; do
        # 显示提示行
        hint_display=""
        i=0
        while [ "$i" -lt "$length" ]; do
            if [ "$i" -lt "$hint_count" ]; then
                # 获取第 i+1 个参数
                j=0
                for hint in "$@"; do
                    if [ "$j" -eq "$i" ]; then
                        hint_display="${hint_display}${hint} "
                        break
                    fi
                    j=$((j + 1))
                done
            else
                hint_display="${hint_display}    "
            fi
            i=$((i + 1))
        done
        _select_print_impl "${hint_display}"

        # 显示二进制行（确保对齐）
        display=""
        i=0
        while [ "$i" -lt "$length" ]; do
            char="${current_value:$i:1}"
            if [ "$char" = "1" ]; then
                char_display="✅"  # 启用
            else
                char_display="❌"  # 禁用
            fi

            if [ "$i" -eq "$current_pos" ]; then
                display="${display}>${char_display}"
            else
                display="${display}  ${char_display}"
            fi
            i=$((i + 1))
        done
        _select_print_impl "$display"

        # 显示默认值行
        default_display="默认: $default_value"
        _select_print_impl "$default_display"

        # 等待按键
        key=$(wait_key_up_down)

        case "$key" in
            up)
                # 修改当前位（不自动前进）
                current_char="${current_value:$current_pos:1}"
                if [ "$current_char" = "0" ]; then
                    new_char="1"
                else
                    new_char="0"
                fi

                # 构建新值
                if [ "$current_pos" -eq 0 ]; then
                    current_value="${new_char}${current_value:1}"
                elif [ "$current_pos" -eq $((length - 1)) ]; then
                    current_value="${current_value:0:$current_pos}${new_char}"
                else
                    current_value="${current_value:0:$current_pos}${new_char}${current_value:$((current_pos + 1))}"
                fi

                # 清除显示（3行）
                _clear_lines_impl 3
                ;;
            down)
                # 确认当前修改，进入下一轮或最终确认
                if [ "$current_pos" -lt $((length - 1)) ]; then
                    # 移动到下一位
                    current_pos=$((current_pos + 1))
                    # 清除显示（3行）
                    _clear_lines_impl 3
                else
                    # 所有位都已确认，进行最终确认
                    _select_print_impl ""
                    _select_print_impl "当前配置: $current_value"
                    _select_print_impl "确认保存吗？"

                    # 使用 ask 函数进行最终确认
                    _final_choice=0
                    ask "confirm_save" "confirm_yes" "confirm_no" \
                        '_final_choice=1' \
                        '_final_choice=0'

                    # 清除 ask 函数的显示（4行）
                    _clear_lines_impl 4

                    if [ "$_final_choice" -eq 1 ]; then
                        # 用户确认保存
                        _select_print_impl ""
                        _select_print_impl "已确认: $current_value"
                        BINARY_PROMPT_RESULT="$current_value"
                        return 0
                    else
                        # 用户选择重置
                        current_value="$default_value"
                        current_pos=0
                        # 清除显示（3行）
                        _clear_lines_impl 3
                    fi
                fi
                ;;
        esac
    done
}

# =============================================================================

# 国际化 (i18n) 支持

# =============================================================================

# 设置国际化文本
# 用法: _set_i18n_impl "key" "zh" "中文文本" "en" "English text" ...
_set_i18n_impl() {
    key="$1"
    shift

    while [ $# -ge 2 ]; do
        lang="$1"
        text="$2"
        shift 2

        # 使用 eval 动态设置变量
        var_name="_I18N_${key}_${lang}"
        # 转义特殊字符
        text_escaped="$(printf '%s' "$text" | sed "s/'/'\\\\''/g")"
        eval "${var_name}='${text_escaped}'"
    done
}

# 获取国际化文本
# 用法: _i18n_impl "key"
_i18n_impl() {
    key="$1"

    # 检测语言（优先级：LANG > 默认 en）
    lang="${LANG:-en}"
    case "$lang" in
        zh*|cn*|CN*) lang="zh" ;;
        ja*|JP*) lang="ja" ;;
        ko*|KR*) lang="ko" ;;
        *) lang="en" ;;
    esac

    # 尝试获取对应语言的文本
    var_name="_I18N_${key}_${lang}"
    eval "text=\${${var_name}:-}"

    # 如果没有找到，尝试英文
    if [ -z "$text" ] && [ "$lang" != "en" ]; then
        var_name="_I18N_${key}_en"
        eval "text=\${${var_name}:-}"
    fi

    # 如果还是没有，返回 key
    if [ -z "$text" ]; then
        text="$key"
    fi

    printf '%s' "$text"
}

# 获取二进制提示的国际化文本
# 用法: _i18n_binary "key"
_i18n_binary() {
    key="$1"

    # 检测语言（优先级：LANG > 默认 en）
    lang="${LANG:-en}"
    case "$lang" in
        zh*|cn*|CN*) lang="zh" ;;
        ja*|JP*) lang="ja" ;;
        ko*|KR*) lang="ko" ;;
        *) lang="en" ;;
    esac

    # 尝试获取对应语言的文本
    case "$key" in
        "usage_guide")
            case "$lang" in
                zh) echo "📋 使用指南：" ;;
                ja) echo "📋 使用ガイド：" ;;
                ko) echo "📋 사용 가이드：" ;;
                *) echo "📋 Usage Guide:" ;;
            esac
            ;;
        "volume_up")
            case "$lang" in
                zh) echo "👆 音量上键：修改当前选项（0→1 或 1→0）" ;;
                ja) echo "👆 音量↑：現在のオプションを切り替え（0→1 または 1→0）" ;;
                ko) echo "👆 볼륨↑：현재 옵션 전환（0→1 또는 1→0）" ;;
                *) echo "👆 Volume Up: Toggle current option (0→1 or 1→0)" ;;
            esac
            ;;
        "volume_down")
            case "$lang" in
                zh) echo "👇 音量下键：确认当前修改并移到下一项" ;;
                ja) echo "👇 音量↓：現在の変更を確認して次へ" ;;
                ko) echo "👇 볼륨↓：현재 변경을 확인하고 다음으로" ;;
                *) echo "👇 Volume Down: Confirm current change and move to next" ;;
            esac
            ;;
        "final_confirm")
            case "$lang" in
                zh) echo "✅ 全部确认后：询问最终保存，可重置重新配置" ;;
                ja) echo "✅ 全確認後：最終保存を確認、リセットして再設定可能" ;;
                ko) echo "✅ 전체 확인 후：최종 저장 확인, 재설정을 위해 초기화 가능" ;;
                *) echo "✅ After all confirmed: Ask for final save, can reset to reconfigure" ;;
            esac
            ;;
        *)
            echo "$key"
            ;;
    esac
}

# 预设一些常用的 i18n 文本
_set_i18n_impl "volume_key_hint" \
    "zh" "音量👆切换选项，音量👇确认" \
    "en" "Vol👆 to switch, Vol👇 to confirm" \
    "ja" "音量👆切替、音量👇確認" \
    "ko" "볼륨👆 전환, 볼륨👇 확인"

_set_i18n_impl "current_option" \
    "zh" "当前选项" \
    "en" "Current" \
    "ja" "現在" \
    "ko" "현재"

_set_i18n_impl "confirmed" \
    "zh" "已确认" \
    "en" "Confirmed" \
    "ja" "確認済み" \
    "ko" "확인됨"

_set_i18n_impl "select_language" \
    "zh" "选择语言 / Select Language" \
    "en" "选择语言 / Select Language" \
    "ja" "选择语言 / Select Language" \
    "ko" "选择语言 / Select Language"

_set_i18n_impl "lang_zh" \
    "zh" "中文" \
    "en" "中文 (Chinese)" \
    "ja" "中文 (中国語)" \
    "ko" "중문 (Chinese)"

_set_i18n_impl "lang_en" \
    "zh" "English (英语)" \
    "en" "English" \
    "ja" "English (英語)" \
    "ko" "English (영어)"

_set_i18n_impl "lang_ja" \
    "zh" "日本語 (日语)" \
    "en" "日本語 (Japanese)" \
    "ja" "日本語" \
    "ko" "일본어 (Japanese)"

_set_i18n_impl "lang_ko" \
    "zh" "한국어 (韩语)" \
    "en" "한국어 (Korean)" \
    "ja" "한국어 (韓国語)" \
    "ko" "한국어"

_set_i18n_impl "selected" \
    "zh" "已选择" \
    "en" "Selected" \
    "ja" "選択済み" \
    "ko" "선택됨"

_set_i18n_impl "cancel" \
    "zh" "已取消" \
    "en" "Cancelled" \
    "ja" "キャンセル" \
    "ko" "취소됨"

_set_i18n_impl "confirm_yes" \
    "zh" "确定" \
    "en" "Yes" \
    "ja" "はい" \
    "ko" "예"

_set_i18n_impl "confirm_no" \
    "zh" "取消" \
    "en" "No" \
    "ja" "いいえ" \
    "ko" "아니오"

_set_i18n_impl "confirm_save" \
    "zh" "确认保存配置？" \
    "en" "Confirm save configuration?" \
    "ja" "設定を保存しますか？" \
    "ko" "설정을 저장하시겠습니까?"

# 二进制提示 i18n
_set_i18n_impl "usage_guide" \
    "zh" "📋 使用指南：" \
    "en" "📋 Usage Guide:" \
    "ja" "📋 使用ガイド：" \
    "ko" "📋 사용 가이드："

_set_i18n_impl "volume_up" \
    "zh" "👆 音量上键：修改当前选项（0→1 或 1→0）" \
    "en" "👆 Volume Up: Toggle current option (0→1 or 1→0)" \
    "ja" "👆 音量↑：現在のオプションを切り替え（0→1 または 1→0）" \
    "ko" "👆 볼륨↑：현재 옵션 전환（0→1 또는 1→0）"

_set_i18n_impl "volume_down" \
    "zh" "👇 音量下键：确认当前修改并移到下一项" \
    "en" "👇 Volume Down: Confirm current change and move to next" \
    "ja" "👇 音量↓：現在の変更を確認して次へ" \
    "ko" "👇 볼륨↓：현재 변경을 확인하고 다음으로"

_set_i18n_impl "final_confirm" \
    "zh" "✅ 全部确认后：询问最终保存，可重置重新配置" \
    "en" "✅ After all confirmed: Ask for final save, can reset to reconfigure" \
    "ja" "✅ 全確認後：最終保存を確認、リセットして再設定可能" \
    "ko" "✅ 전체 확인 후：최종 저장 확인, 재설정을 위해 초기화 가능"

_set_i18n_impl "incremental_not_supported" \
    "zh" "⚠️ 当前终端不支持增量更新，回退到普通输出" \
    "en" "⚠️ Terminal does not support incremental updates; falling back to plain printing" \
    "ja" "⚠️ 現在の端末はインクリメンタル更新をサポートしていません。標準出力にフォールバックします" \
    "ko" "⚠️ 현재 터미널은 증분 업데이트를 지원하지 않습니다. 일반 출력으로 대체합니다"

# 多选项选择内部实现
# 用法: _multi_select_impl "标题" "选项1" "选项2" ...
_multi_select_impl() {
    title="$1"
    shift

    _select_idx=0

    _select_print_impl "$title"
    _select_print_impl "音量👆切换选项，音量👇确认"
    _select_print_impl ""

    if command -v getevent >/dev/null 2>&1; then
        while :; do
            # 显示选项
            i=0
            for opt in "$@"; do
                if [ "$i" -eq "$_select_idx" ]; then
                    _select_print_impl "[*] $opt"
                else
                    _select_print_impl "[ ] $opt"
                fi
                i=$((i + 1))
            done

            # 等待按键
            key=$(wait_key_up_down)

            if [ "$key" = "up" ]; then
                _select_idx=$((_select_idx + 1))
                if [ "$_select_idx" -ge "$#" ]; then
                    _select_idx=0
                fi
                # 清除显示
                _clear_lines_impl "$#"
            else
                # 确认选择
                i=0
                for opt in "$@"; do
                    if [ "$i" -eq "$_select_idx" ]; then
                        _select_print_impl ""
                        _select_print_impl "已确认: $opt"
                        break
                    fi
                    i=$((i + 1))
                done
                MULTI_SELECT_RESULT="$_select_idx"
                return
            fi
        done
    else
        # getevent 不可用，仍然显示选项然后返回默认值
        i=0
        for opt in "$@"; do
            if [ "$i" -eq 0 ]; then
                _select_print_impl "[*] $opt"
            else
                _select_print_impl "[ ] $opt"
            fi
            i=$((i + 1))
        done
        _select_print_impl ""
        _select_print_impl "✗ getevent 不可用，使用默认选项"
        MULTI_SELECT_RESULT="0"
    fi
}

# 文本输入框内部实现
# 用法: _text_input_impl "标题" "提示" [默认值]
_text_input_impl() {
    title="$1"
    prompt="$2"
    default_value="$3"
    current_text="${default_value:-}"
    cursor_pos=0

    # 显示标题和提示
    _select_print_impl "$title"
    _select_print_impl "$prompt"
    _select_print_impl ""

    # 如果有 getevent，使用交互式输入
    if command -v getevent >/dev/null 2>&1; then
        while :; do
            # 显示输入框
            _select_print_impl "┌────────────────────────────────────────┐"

            # 构建显示行（带光标）
            display_text="│ ${current_text}"
            display_len=${#display_text}

            # 添加光标
            if [ "$cursor_pos" -eq ${#current_text} ]; then
                display_text="${display_text}_"
            else
                # 在指定位置插入光标
                prefix="${current_text:0:$cursor_pos}"
                suffix="${current_text:$cursor_pos}"
                display_text="│ ${prefix}_${suffix}"
            fi

            # 填充到固定宽度
            while [ ${#display_text} -lt 39 ]; do
                display_text="${display_text} "
            done
            display_text="${display_text}│"

            _select_print_impl "$display_text"
            _select_print_impl "└────────────────────────────────────────┘"
            _select_print_impl ""
            _select_print_impl "$(_i18n_text_input "controls")"

            # 等待按键
            key=$(_get_key_impl)

            case "$key" in
                KEY_VOLUMEUP)
                    # 删除前一个字符
                    if [ "$cursor_pos" -gt 0 ]; then
                        prefix="${current_text:0:$((cursor_pos - 1))}"
                        suffix="${current_text:$cursor_pos}"
                        current_text="${prefix}${suffix}"
                        cursor_pos=$((cursor_pos - 1))
                    fi
                    ;;
                KEY_VOLUMEDOWN)
                    # 输入预设字符或确认
                    if [ ${#current_text} -gt 0 ]; then
                        TEXT_INPUT_RESULT="$current_text"
                        _select_print_impl ""
                        _select_print_impl "$(_i18n_text_input "confirmed"): $current_text"
                        return
                    else
                        # 添加默认字符
                        current_text="${current_text}a"
                        cursor_pos=$((cursor_pos + 1))
                    fi
                    ;;
                KEY_POWER)
                    # 确认输入
                    TEXT_INPUT_RESULT="$current_text"
                    _select_print_impl ""
                    _select_print_impl "$(_i18n_text_input "confirmed"): $current_text"
                    return
                    ;;
                # 数字键 0-9
                KEY_0|KEY_1|KEY_2|KEY_3|KEY_4|KEY_5|KEY_6|KEY_7|KEY_8|KEY_9)
                    char="${key#KEY_}"
                    prefix="${current_text:0:$cursor_pos}"
                    suffix="${current_text:$cursor_pos}"
                    current_text="${prefix}${char}${suffix}"
                    cursor_pos=$((cursor_pos + 1))
                    ;;
                # 字母键 A-Z
                KEY_A|KEY_B|KEY_C|KEY_D|KEY_E|KEY_F|KEY_G|KEY_H|KEY_I|KEY_J|KEY_K|KEY_L|KEY_M|\
                KEY_N|KEY_O|KEY_P|KEY_Q|KEY_R|KEY_S|KEY_T|KEY_U|KEY_V|KEY_W|KEY_X|KEY_Y|KEY_Z)
                    char="${key#KEY_}"
                    # 转换为小写
                    prefix="${current_text:0:$cursor_pos}"
                    suffix="${current_text:$cursor_pos}"
                    current_text="${prefix}${char}${suffix}"
                    cursor_pos=$((cursor_pos + 1))
                    ;;
                # 特殊字符
                KEY_DOT|KEY_PERIOD)
                    prefix="${current_text:0:$cursor_pos}"
                    suffix="${current_text:$cursor_pos}"
                    current_text="${prefix}.${suffix}"
                    cursor_pos=$((cursor_pos + 1))
                    ;;
                KEY_SLASH)
                    prefix="${current_text:0:$cursor_pos}"
                    suffix="${current_text:$cursor_pos}"
                    current_text="${prefix}/${suffix}"
                    cursor_pos=$((cursor_pos + 1))
                    ;;
                KEY_MINUS)
                    prefix="${current_text:0:$cursor_pos}"
                    suffix="${current_text:$cursor_pos}"
                    current_text="${prefix}-${suffix}"
                    cursor_pos=$((cursor_pos + 1))
                    ;;
                KEY_UNDERSCORE)
                    prefix="${current_text:0:$cursor_pos}"
                    suffix="${current_text:$cursor_pos}"
                    current_text="${prefix}_${suffix}"
                    cursor_pos=$((cursor_pos + 1))
                    ;;
            esac

            # 清除显示（6行）
            _clear_lines_impl 6
        done
    else
        # 非交互环境，使用 read
        _select_print_impl "$(_i18n_text_input "enter_url"):"
        if [ -n "$default_value" ]; then
            _select_print_impl "$(_i18n_text_input "default"): $default_value"
        fi
        _select_print_impl ""

        # 使用环境变量或 read 命令
        if [ -n "${SUBSCRIPTION_URL:-}" ]; then
            TEXT_INPUT_RESULT="$SUBSCRIPTION_URL"
            _select_print_impl "$(_i18n_text_input "using_env"): $TEXT_INPUT_RESULT"
        else
            # 简单的回退方案
            TEXT_INPUT_RESULT="${default_value:-https://example.com/api}"
            _select_print_impl "$(_i18n_text_input "using_default"): $TEXT_INPUT_RESULT"
        fi
    fi
}

# 文本输入的国际化文本
# 用法: _i18n_text_input "key"
_i18n_text_input() {
    key="$1"

    # 检测语言
    lang="${LANG:-en}"
    case "$lang" in
        zh*|cn*|CN*) lang="zh" ;;
        ja*|JP*) lang="ja" ;;
        ko*|KR*) lang="ko" ;;
        *) lang="en" ;;
    esac

    case "$key" in
        "controls")
            case "$lang" in
                zh) echo "音量上:删除 | 音量下:添加/确认 | 电源键:确认" ;;
                ja) echo "音量↑:削除 | 音量↓:追加/確認 | 電源:確認" ;;
                ko) echo "볼륨↑:삭제 | 볼륨↓:추가/확인 | 전원:확인" ;;
                *) echo "Vol↑:Delete | Vol↓:Add/Confirm | Power:Confirm" ;;
            esac
            ;;
        "confirmed")
            case "$lang" in
                zh) echo "已确认" ;;
                ja) echo "確認済み" ;;
                ko) echo "확인됨" ;;
                *) echo "Confirmed" ;;
            esac
            ;;
        "enter_url")
            case "$lang" in
                zh) echo "请输入订阅链接" ;;
                ja) echo "サブスクリプションURLを入力" ;;
                ko) echo "구독 URL을 입력하세요" ;;
                *) echo "Enter subscription URL" ;;
            esac
            ;;
        "default")
            case "$lang" in
                zh) echo "默认值" ;;
                ja) echo "デフォルト" ;;
                ko) echo "기본값" ;;
                *) echo "Default" ;;
            esac
            ;;
        "using_env")
            case "$lang" in
                zh) echo "使用环境变量" ;;
                ja) echo "環境変数を使用" ;;
                ko) echo "환경 변수 사용" ;;
                *) echo "Using environment variable" ;;
            esac
            ;;
        "using_default")
            case "$lang" in
                zh) echo "使用默认值" ;;
                ja) echo "デフォルトを使用" ;;
                ko) echo "기본값 사용" ;;
                *) echo "Using default value" ;;
            esac
            ;;
        *)
            echo "$key"
            ;;
    esac
}
