# shellcheck shell=ash
##########################################################################################
# KAM Framework - Internationalization (i18n) Module
# Optimized for multi-line text and ash environment (2025 Revised)
##########################################################################################
# 设置国际化文本
# 用法: set_i18n "KEY" "zh" "文本内容" "en" "Text Content" ...
_kamfw_i18n_key_is_safe() {
    case "${1:-}" in
    "" | [!A-Za-z_]* | *[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
    esac
}

_kamfw_i18n_lang_is_safe() {
    case "${1:-}" in
    "" | [!A-Za-z]* | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
    esac
}

_kamfw_i18n_pairs_are_safe() {
    [ $(( $# % 2 )) -eq 0 ] || return 1
    while [ $# -ge 2 ]; do
        _kamfw_i18n_lang_is_safe "$1" || return 1
        shift 2
    done
}

set_i18n() {
    [ $# -ge 1 ] || return 1
    _s_key="$1"
    shift
    if ! _kamfw_i18n_key_is_safe "$_s_key" || ! _kamfw_i18n_pairs_are_safe "$@"; then
        unset _s_key
        return 1
    fi
    while [ $# -ge 2 ]; do
        _s_lang="$1"
        _s_text="$2"
        shift 2
        # 处理语言代码中的特殊字符 (如 zh-CN -> zh_CN)
        case "$_s_lang" in
        *-*) _s_safe_lang=$(printf '%s' "$_s_lang" | tr '-' '_') ;;
        *) _s_safe_lang=$_s_lang ;;
        esac
        if ! _kamfw_i18n_key_is_safe "$_s_safe_lang"; then
            unset _s_key _s_lang _s_text _s_safe_lang
            return 1
        fi
        _s_var_name="_I18N_${_s_key}_${_s_safe_lang}"
        # 直接导出变量，允许包含换行符
        export "$_s_var_name"="$_s_text"
    done
    unset _s_key _s_lang _s_text _s_safe_lang _s_var_name
}
# 获取并打印国际化文本
# 用法: i18n "WELCOME_MSG"
i18n() {
    _i1_key="${1:-}"
    if ! _kamfw_i18n_key_is_safe "$_i1_key"; then
        unset _i1_key
        return 1
    fi

    # 获取当前语言优先级: KAM_UI_LANGUAGE > KAM_LANG (legacy) > 系统属性 > 默认 en
    _i1_lang="${KAM_UI_LANGUAGE:-${KAM_LANG:-$(getprop persist.sys.locale 2>/dev/null | cut -d'-' -f1)}}"
    _i1_lang="${_i1_lang:-en}"

    # 如果使用了 legacy KAM_LANG 并且启用了调试（KAM_DEBUG_I18N=1），则打印弃用提示
    if [ -z "${KAM_UI_LANGUAGE:-}" ] && [ -n "${KAM_LANG:-}" ] && [ "${KAM_DEBUG_I18N:-}" = "1" ]; then
        print "Warning: KAM_LANG is deprecated; please use KAM_UI_LANGUAGE"
    fi

    case "$_i1_lang" in
    zh* | cn* | CN*) _i1_lang="zh" ;;
    ja* | JP*) _i1_lang="ja" ;;
    ko* | KR*) _i1_lang="ko" ;;
    *) _i1_lang="en" ;;
    esac
    case "$_i1_lang" in
    zh | ja | ko | en) ;;
    *)
        unset _i1_key _i1_lang
        return 1
        ;;
    esac

    _i1_var_name="_I18N_${_i1_key}_${_i1_lang}"

    # 使用 eval 直接读取变量，以支持多行内容
    eval "_i1_text=\${${_i1_var_name}:-}"

    # 自动回退机制：如果目标语言为空且不是英文，尝试读取英文
    if [ -z "$_i1_text" ] && [ "$_i1_lang" != "en" ]; then
        _i1_var_name="_I18N_${_i1_key}_en"
        eval "_i1_text=\${${_i1_var_name}:-}"
    fi

    # 如果依然为空，则返回 Key 名本身
    if [ -z "$_i1_text" ]; then
        print "$_i1_key"
    else
        # 展开转义序列（如 \n）再使用 print 输出，保持输出函数一致性
        _i1_out=$(printf '%b' "$_i1_text")
        print "$_i1_out"
    fi

    unset _i1_key _i1_lang _i1_var_name _i1_text
}

# Validate and apply through the same parser so both phases accept exactly the
# same table format. The validation phase never exports translations.
_kamfw_i18n_table_pass() {
    _licp_file="$1"
    _licp_mode="$2"
    case "$_licp_mode" in
    validate | apply) ;;
    *) return 1 ;;
    esac

    _licp_langs=""
    while IFS= read -r _licp_line || [ -n "$_licp_line" ]; do
        case "$_licp_line" in
        \#* | "") continue ;;
        esac

        # 解析表头 KEY|zh|en...
        if [ -z "$_licp_langs" ]; then
            case "$_licp_line" in
            KEY\|*)
                _licp_hdr="${_licp_line#KEY|}"
                case "$_licp_hdr" in
                "" | \|* | *\| | *\|\|*)
                    unset _licp_file _licp_mode _licp_line _licp_hdr _licp_langs
                    return 1
                    ;;
                esac
                _licp_langs=$(printf '%s' "$_licp_hdr" | tr '|' ' ')
                for _licp_lang in $_licp_langs; do
                    if ! _kamfw_i18n_lang_is_safe "$_licp_lang"; then
                        unset _licp_file _licp_mode _licp_line _licp_hdr _licp_langs _licp_lang
                        return 1
                    fi
                done
                continue
                ;;
            esac
            _licp_langs="zh en ja ko"
        fi

        _licp_expected_fields=1
        for _licp_lang in $_licp_langs; do
            _licp_expected_fields=$((_licp_expected_fields + 1))
        done
        _licp_actual_fields=1
        _licp_rest="$_licp_line"
        while :; do
            case "$_licp_rest" in
            *\|*)
                _licp_actual_fields=$((_licp_actual_fields + 1))
                _licp_rest="${_licp_rest#*|}"
                ;;
            *) break ;;
            esac
        done
        if [ "$_licp_actual_fields" -ne "$_licp_expected_fields" ]; then
            unset _licp_file _licp_mode _licp_line _licp_hdr _licp_langs _licp_lang
            unset _licp_expected_fields _licp_actual_fields _licp_rest
            return 1
        fi

        _licp_key=$(printf '%s' "$_licp_line" | cut -d'|' -f1)
        if ! _kamfw_i18n_key_is_safe "$_licp_key"; then
            unset _licp_file _licp_mode _licp_line _licp_hdr _licp_langs _licp_key _licp_lang
            return 1
        fi

        _licp_field_idx=2
        for _licp_lang in $_licp_langs; do
            _licp_val=$(printf '%s' "$_licp_line" | cut -d'|' -f"$_licp_field_idx")
            if [ "$_licp_mode" = apply ] &&
                ! set_i18n "$_licp_key" "$_licp_lang" "$_licp_val"; then
                unset _licp_file _licp_mode _licp_line _licp_hdr _licp_langs
                unset _licp_key _licp_val _licp_field_idx _licp_lang
                return 1
            fi
            _licp_field_idx=$((_licp_field_idx + 1))
        done
    done <"$_licp_file"

    unset _licp_file _licp_mode _licp_line _licp_hdr _licp_langs
    unset _licp_key _licp_val _licp_field_idx _licp_lang
    unset _licp_expected_fields _licp_actual_fields _licp_rest
}

# 从文件加载 I18N 数据
load_i18n() {
    _lic_file="${1:-}"
    [ -f "$_lic_file" ] || return 1

    if ! _kamfw_i18n_table_pass "$_lic_file" validate; then
        unset _lic_file
        return 1
    fi
    if ! _kamfw_i18n_table_pass "$_lic_file" apply; then
        unset _lic_file
        return 1
    fi

    unset _lic_file
}

# 导出当前 I18N 数据到文件
dump_i18n() {
    _dic_file="$1"
    [ -n "$_dic_file" ] || return 1

    _dic_langs=$(env | grep '^_I18N_' | sed -n 's/^_I18N_.*_\([^=]*\)=.*/\1/p' | sort -u)
    [ -z "$_dic_langs" ] && _dic_langs="zh en ja ko"

    # 打印表头
    _hdr="KEY"
    for _lang in $_dic_langs; do _hdr="${_hdr}|${_lang}"; done
    printf '%s\n' "$_hdr" >"$_dic_file"

    _dic_keys=$(env | grep '^_I18N_' | sed -n 's/^_I18N_\(.*\)_\([^=]*\)=.*/\1/p' | sort -u)

    for _dic_k in $_dic_keys; do
        _out="${_dic_k}"
        for _lang in $_dic_langs; do
            _var="_I18N_${_dic_k}_${_lang}"
            eval "_val=\$${_var}"
            # 导出时将真实换行符转义为 \n 字符串以便单行存储
            _val=$(printf '%s' "$_val" | sed ':a;N;$!ba;s/\n/\\n/g')
            _out="${_out}|${_val}"
        done
        printf '%s\n' "$_out" >>"$_dic_file"
    done

    unset _dic_file _dic_langs _hdr _dic_keys _dic_k _lang _var _val _out
}

# Template function for string substitution
# Usage: echo "Hello $_1" | t "World"
t() {
    # If no piped stdin, fall back to printing the first argument (if any)
    if [ -t 0 ]; then
        if [ $# -gt 0 ]; then
            print "$1"
        fi
        return 0
    fi

    # Read entire piped input
    _template=$(cat -)

    _idx=1
    while [ $# -gt 0 ]; do
        _arg="$1"
        # Escape characters that may interfere with sed replacement
        _esc=$(printf '%s' "$_arg" | sed -e 's/\\/\\\\/g' -e 's/&/\\\&/g' -e 's/|/\\|/g')
        # Replace occurrences of $_<index> with the escaped argument
        _template=$(printf '%s' "$_template" | sed "s|\\\$_${_idx}|${_esc}|g")
        shift
        _idx=$((_idx + 1))
    done

    print "$_template"
    unset _template _idx _arg _esc
}

import i18ns
