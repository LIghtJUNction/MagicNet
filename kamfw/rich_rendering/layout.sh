# shellcheck shell=ash

__rich_terminal_width() {
    _rich_width=""
    if command -v tput >/dev/null 2>&1; then
        _rich_width=$(tput cols 2>/dev/null || true)
    fi
    if ! printf '%s' "${_rich_width:-}" | grep -Eq '^[0-9]+$'; then
        if command -v stty >/dev/null 2>&1; then
            _rich_width=$(stty size 2>/dev/null | awk '{print $2}')
        fi
    fi
    _rich_width="${_rich_width:-${COLUMNS:-80}}"
    case "${_rich_width}" in
    '' | *[!0-9]* | 0) _rich_width=80 ;;
    esac
    printf '%s' "$_rich_width"
    unset _rich_width
}

__rich_repeat() {
    _rich_char="${1:-─}"
    _rich_width="${2:-80}"
    case "${_rich_width}" in
    '' | *[!0-9]* | 0) _rich_width=80 ;;
    esac

    if command -v awk >/dev/null 2>&1; then
        # Android toybox awk measures UTF-8 strings in bytes. Repeating and
        # truncating by length() can therefore cut a box-drawing character in
        # half and emit invalid UTF-8. Count repetitions instead of bytes.
        awk -v ch="${_rich_char}" -v w="${_rich_width}" 'BEGIN {
            for (i = 0; i < w; i++) printf "%s", ch;
        }'
    else
        _rich_index=0
        while [ "$_rich_index" -lt "$_rich_width" ]; do
            printf '%s' "$_rich_char"
            _rich_index=$((_rich_index + 1))
        done
    fi

    unset _rich_char _rich_width _rich_index
}

__rich_pad_right() {
    _rich_text="${1:-}"
    _rich_width="${2:-0}"
    case "${_rich_width}" in
    '' | *[!0-9]*) _rich_width=0 ;;
    esac

    if command -v awk >/dev/null 2>&1; then
        awk -v s="${_rich_text}" -v w="${_rich_width}" 'BEGIN {
            printf "%s", s;
            for (i = length(s); i < w; i++) printf " ";
        }'
    else
        printf '%s' "$_rich_text"
    fi

    unset _rich_text _rich_width
}

__rich_style() {
    _rich_color="${1:-}"
    _rich_text="${2:-}"
    if is_tty 2>/dev/null; then
        printf '%b' "${_rich_color}${_rich_text}${COL_RST}"
    else
        printf '%s' "$_rich_text"
    fi
    unset _rich_color _rich_text
}

__rich_cyan() { __rich_style "$COL_CYN" "$1"; }
__rich_green() { __rich_style "$COL_GRN" "$1"; }
__rich_yellow() { __rich_style "$COL_YLW" "$1"; }
__rich_red() { __rich_style "$COL_RED" "$1"; }

# 内部函数：执行文件更新操作
_do_update_file() {
    # 复制已安装模块的文件并重命名
    _installed_file="$_installed_module_path/$_relative_path"
    _temp_file="$MODPATH/$_relative_path"

    # 重命名新文件
    mv "$_temp_file" "$_temp_file.update"
    # .update表示这个是新模块更新的文件
    # 为了避免覆盖用户修改的文件，这里重命名为.update
    # 然后会把已经安装好的模块的相关文件复制到临时文件夹
    # 这样就实现了安全更新
    # 如果已安装模块中存在该文件，复制过来
    if [ -f "$_installed_file" ]; then
        # 确保目标目录存在
        _temp_dir="${_temp_file%/*}"
        [ "$_temp_dir" != "$_temp_file" ] && mkdir -p "$_temp_dir"
        # 复制文件，保持权限
        cp -a "$_installed_file" "$_temp_file"
    fi

    unset _relative_path _module_id _installed_module_path
    unset _installed_file _temp_file _temp_dir
    return 0
}

# divider
# divider "#" 10
# divider "=" 20
divider() {
    _divider_char="${1:-▚}"

    _divider_terminal_width=$(__rich_terminal_width)
    _divider_width="${2:-${_divider_terminal_width}}"
    case "${_divider_width}" in
    '' | *[!0-9]* | 0) _divider_width=80 ;;
    esac

    _fill=$(__rich_repeat "$_divider_char" "$_divider_width")
    print "$(__rich_cyan "$_fill")"

    unset _fill _divider_terminal_width _divider_width _divider_char
}

newline() {
    # Print N blank lines (default: 1)
    _n="${1:-1}"

    # If argument is not a non-negative integer, fall back to 1
    case "$_n" in
    '' | *[!0-9]*)
        _n=1
        ;;
    esac

    while [ "$_n" -gt 0 ]; do
        printf '\n'
        _n=$((_n - 1))
    done
}

# guide
guide() {
    _title="${1:-}"
    _content="${2:-}"
    print "$(__rich_yellow "$_title")"
    print "$(__rich_yellow "$_content")"
}

panel() {
    _panel_title="${1:-}"
    _panel_width="${PANEL_WIDTH:-$(__rich_terminal_width)}"
    case "${_panel_width}" in
    '' | *[!0-9]* | 0) _panel_width=80 ;;
    esac
    [ "$_panel_width" -lt 24 ] && _panel_width=24
    _panel_inner=$((_panel_width - 4))
    export __KAMFW_PANEL_WIDTH="$_panel_width"
    export __KAMFW_PANEL_INNER="$_panel_inner"

    newline
    print "$(__rich_cyan "┏$(__rich_repeat "━" $((_panel_width - 2)))┓")"
    if [ -n "$_panel_title" ]; then
        _panel_title_pad=$(__rich_pad_right "$_panel_title" "$_panel_inner")
        print "$(__rich_cyan "┃") $(__rich_cyan "$_panel_title_pad") $(__rich_cyan "┃")"
        print "$(__rich_cyan "┣$(__rich_repeat "━" $((_panel_width - 2)))┫")"
    fi

    unset _panel_title _panel_width _panel_inner _panel_title_pad
}

panel_end() {
    _panel_width="${__KAMFW_PANEL_WIDTH:-$(__rich_terminal_width)}"
    case "${_panel_width}" in
    '' | *[!0-9]* | 0) _panel_width=80 ;;
    esac
    [ "$_panel_width" -lt 24 ] && _panel_width=24
    print "$(__rich_cyan "┗$(__rich_repeat "━" $((_panel_width - 2)))┛")"
    unset __KAMFW_PANEL_WIDTH __KAMFW_PANEL_INNER _panel_width
}

panel_line() {
    _panel_text="${1:-}"
    if [ -n "${__KAMFW_PANEL_INNER:-}" ]; then
        _panel_inner="$__KAMFW_PANEL_INNER"
    else
        _panel_inner=$(( $(__rich_terminal_width) - 4 ))
    fi
    case "${_panel_inner}" in
    '' | *[!0-9]* | 0) _panel_inner=76 ;;
    esac
    _panel_pad=$(__rich_pad_right "$_panel_text" "$_panel_inner")
    print "$(__rich_cyan "┃") ${_panel_pad} $(__rich_cyan "┃")"
    unset _panel_text _panel_inner _panel_pad
}

panel_blank() {
    panel_line ""
}

panel_divider() {
    _panel_width="${__KAMFW_PANEL_WIDTH:-$(__rich_terminal_width)}"
    case "${_panel_width}" in
    '' | *[!0-9]* | 0) _panel_width=80 ;;
    esac
    [ "$_panel_width" -lt 24 ] && _panel_width=24
    print "$(__rich_cyan "┣$(__rich_repeat "─" $((_panel_width - 2)))┫")"
    unset _panel_width
}

panel_row() {
    _panel_label="${1:-}"
    _panel_value="${2:-}"
    _panel_label_width="${PANEL_LABEL_WIDTH:-18}"
    case "${_panel_label_width}" in
    '' | *[!0-9]* | 0) _panel_label_width=18 ;;
    esac
    _panel_label_pad=$(__rich_pad_right "$_panel_label" "$_panel_label_width")
    panel_line "$(__rich_cyan "$_panel_label_pad")  ${_panel_value}"
    unset _panel_label _panel_value _panel_label_width _panel_label_pad
}

panel_status() {
    _panel_kind="${1:-info}"
    _panel_content="${2:-}"
    case "$_panel_kind" in
    ok | success)
        _panel_mark="ok"
        _panel_mark=$(__rich_green "$_panel_mark")
        ;;
    warn | warning)
        _panel_mark="warn"
        _panel_mark=$(__rich_yellow "$_panel_mark")
        ;;
    error | fail | failed)
        _panel_mark="error"
        _panel_mark=$(__rich_red "$_panel_mark")
        ;;
    *)
        _panel_mark="note"
        _panel_mark=$(__rich_cyan "$_panel_mark")
        ;;
    esac
    panel_line "[${_panel_mark}] ${_panel_content}"
    unset _panel_kind _panel_content _panel_mark
}

panel_note() {
    panel_status info "$1"
}

panel_success() {
    panel_status success "$1"
}

panel_warn() {
    panel_status warn "$1"
}

panel_error() {
    panel_status error "$1"
}
