# shellcheck shell=ash
panel() {
    _title="${1:-}"
    newline
    divider "━"
    [ -n "$_title" ] && printf '%b\n' "${COL_CYN}${_title}${COL_RST}"
    divider "─"
    unset _title
}

panel_end() {
    divider "━"
}

panel_row() {
    _label="${1:-}"
    _value="${2:-}"
    printf '%b\n' "${COL_CYN}${_label}${COL_RST}  ${_value}"
    unset _label _value
}

panel_note() {
    _content="${1:-}"
    printf '%b\n' "${COL_YLW}${_content}${COL_RST}"
    unset _content
}

panel_success() {
    _content="${1:-}"
    printf '%b\n' "${COL_GRN}${_content}${COL_RST}"
    unset _content
}

panel_warn() {
    _content="${1:-}"
    printf '%b\n' "${COL_YLW}${_content}${COL_RST}"
    unset _content
}

panel_error() {
    _content="${1:-}"
    printf '%b\n' "${COL_RED}${_content}${COL_RST}"
    unset _content
}

ask_can_redraw() {
    [ -t 1 ] && [ -n "${ANSI_CURSOR_UP:-}" ] && [ -n "${ANSI_CLEAR_LINE:-}" ]
}

ask_print_option() {
    _idx="$1"
    _text="$2"
    _selected="$3"
    _num=$((_idx + 1))
    if [ "$_selected" = "1" ]; then
        printf '  %s\n' "$(__rich_cyan "> ${_num}. ${_text}")"
    else
        printf '%b\n' "    ${_num}. ${_text}"
    fi
    unset _idx _text _selected _num
}

ask_print_selection() {
    _idx="$1"
    _text="$2"
    _num=$((_idx + 1))
    printf '  %s\n' "$(__rich_cyan "> ${_num}. ${_text}")"
    unset _idx _text _num
}

# ask - Interactive menu with volume key support
# Usage: ask "QUESTION" "opt1_text" "opt1_cmd" "opt2_text" "opt2_cmd" ... [default_index]
ask() {
    question="$1"
    shift || true

    # i18n for question text if it's a key
    if printf '%s' "$question" | grep -q '^[[:alpha:]_][[:alnum:]_]*$'; then
        question=$(i18n "$question")
    fi

    _opt_count=0
    default_selected=0

    # parse arguments: pairs of (text, command) + optional trailing default index
    while [ $# -gt 0 ]; do
        _txt="$1"
        shift || true

        if [ "$#" -eq 0 ]; then
            # single trailing arg -> treat as default index
            default_selected="$_txt"
            break
        fi

        _cmd="$1"
        shift || true

        # i18n for option text if it's a key
        if printf '%s' "$_txt" | grep -q '^[[:alpha:]_][[:alnum:]_]*$'; then
            _txt=$(i18n "$_txt")
        fi

        __tmp="$_txt"
        eval "opt_text_${_opt_count}=\"\$__tmp\""
        __tmp="$_cmd"
        eval "opt_cmd_${_opt_count}=\"\$__tmp\""
        _opt_count=$((_opt_count + 1))
    done

    # nothing to choose -> just show question
    if [ "$_opt_count" -eq 0 ]; then
        printf '%s\n' "$question"
        return
    fi

    # show localized guide for this interactive prompt (uses i18n)
    guide "$(i18n 'ASK_GUIDE_TITLE')" "$(i18n 'ASK_GUIDE_CONTENT')"

    # sanitize default_selected
    case "${default_selected:-0}" in
    '' | *[!0-9]*) default_selected=0 ;;
    esac
    if [ "$default_selected" -ge "$_opt_count" ]; then
        default_selected=0
    fi

    _sel="$default_selected"

    _can_redraw=0
    ask_can_redraw && _can_redraw=1

    # initial render
    printf '%s\n' "$question"
    _i=0
    while [ "$_i" -lt "$_opt_count" ]; do
        eval "_txt=\$opt_text_${_i}"
        if [ "$_i" -eq "$_sel" ]; then
            ask_print_option "$_i" "$_txt" 1
        else
            ask_print_option "$_i" "$_txt" 0
        fi
        _i=$((_i + 1))
    done

    newline

    # interactive loop: volume-down cycles, volume-up confirms
    while :; do
        _k=$(wait_key_up_down)
        case "$_k" in
        down)
            _sel=$(((_sel + 1) % _opt_count))
            if [ "$_can_redraw" = "1" ]; then
                # move cursor up only for options + trailing blank line (not the question)
                printf "${ANSI_CURSOR_UP}" "$((_opt_count + 1))"

                _i=0
                while [ "$_i" -lt "$_opt_count" ]; do
                    eval "_txt=\$opt_text_${_i}"
                    printf "\r${ANSI_CLEAR_LINE}"
                    if [ "$_i" -eq "$_sel" ]; then
                        ask_print_option "$_i" "$_txt" 1
                    else
                        ask_print_option "$_i" "$_txt" 0
                    fi
                    _i=$((_i + 1))
                done
                # clear trailing blank line and emit a fresh one
                printf "\r${ANSI_CLEAR_LINE}\n"
            else
                eval "_txt=\$opt_text_${_sel}"
                ask_print_selection "$_sel" "$_txt"
            fi
            ;;
        up)
            eval "_txt=\$opt_text_${_sel}"
            eval "_cmd=\$opt_cmd_${_sel}"
            printf '  %s\n' "$(__rich_green "$(i18n 'CONFIRM'): ${_txt}")"
            eval "$_cmd"
            break
            ;;
        esac
    done
    newline

    unset _can_redraw
    return

}

# confirm - Simple confirmation dialog with customizable default
# Usage: confirm "QUESTION_KEY" [default] && do_something
# default: 0 for yes, 1 for no (default: 1)
# Returns: 0 if yes, 1 if no
confirm() {
    _question="${1:-CONFIRM_ACTION}"
    _default="${2:-1}"

    # 使用ask函数实现确认对话框
    ask "$_question" \
        "YES" \
        'return 0' \
        "NO" \
        'return 1' \
        "$_default"

    unset _question _default
}

# confirm_update_file - 确认更新文件
# Usage: confirm_update_file <relative_path>
# 如果模块已安装，询问是否强制更新文件，默认选择否
# 选择否时，会复制已安装模块的文件并重命名为.update
