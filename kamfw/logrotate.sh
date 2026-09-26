# shellcheck shell=ash
#
# kamfw log rotation helper
#
# Explicit API only. Importing this file does not rotate files or start workers.

set_i18n "LOGROTATE_FILE_REQUIRED" \
    "zh" "logrotate: 日志文件不能为空" \
    "en" "logrotate: log file is required" \
    "ja" "logrotate: ログファイルが必要です" \
    "ko" "logrotate: 로그 파일이 필요합니다"

set_i18n "LOGROTATE_SIZE_INVALID" \
    "zh" "logrotate: 轮转大小必须是正整数，可带 k/m/g 后缀" \
    "en" "logrotate: rotate size must be a positive integer, optionally with k/m/g suffix" \
    "ja" "logrotate: ローテーションサイズは正の整数で、任意で k/m/g 接尾辞を指定できます" \
    "ko" "logrotate: 순환 크기는 양의 정수여야 하며 k/m/g 접미사를 사용할 수 있습니다"

set_i18n "LOGROTATE_KEEP_INVALID" \
    "zh" "logrotate: 保留份数必须是非负整数" \
    "en" "logrotate: keep count must be a non-negative integer" \
    "ja" "logrotate: 保持数は 0 以上の整数である必要があります" \
    "ko" "logrotate: 보관 개수는 0 이상의 정수여야 합니다"

set_i18n "LOGROTATE_USAGE" \
    "zh" "用法: logrotate [-s size] [-k keep] <file>" \
    "en" "Usage: logrotate [-s size] [-k keep] <file>" \
    "ja" "使用法: logrotate [-s size] [-k keep] <file>" \
    "ko" "사용법: logrotate [-s size] [-k keep] <file>"

logrotate_size_bytes() {
    _lr_size="$1"
    case "$_lr_size" in
    *[kK])
        _lr_num="${_lr_size%[kK]}"
        _lr_mul=1024
        ;;
    *[mM])
        _lr_num="${_lr_size%[mM]}"
        _lr_mul=1048576
        ;;
    *[gG])
        _lr_num="${_lr_size%[gG]}"
        _lr_mul=1073741824
        ;;
    *)
        _lr_num="$_lr_size"
        _lr_mul=1
        ;;
    esac

    case "$_lr_num" in
    '' | *[!0-9]* | 0)
        unset _lr_size _lr_num _lr_mul
        return 1
        ;;
    esac

    print "$((_lr_num * _lr_mul))"
    unset _lr_size _lr_num _lr_mul
    return 0
}

logrotate_valid_keep() {
    case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
    esac
}

logrotate_file_size() {
    _lr_file="$1"
    [ -f "$_lr_file" ] || {
        print 0
        unset _lr_file
        return 0
    }
    _lr_size="$(wc -c <"$_lr_file" 2>/dev/null || print 0)"
    case "$_lr_size" in
    '' | *[!0-9]*) _lr_size=0 ;;
    esac
    print "$_lr_size"
    unset _lr_file _lr_size
}

logrotate_needed() {
    _lr_file="$1"
    _lr_size_spec="$2"
    [ -z "$_lr_file" ] && return 1
    _lr_max_bytes="$(logrotate_size_bytes "$_lr_size_spec")" || {
        unset _lr_file _lr_size_spec _lr_max_bytes
        return 1
    }
    _lr_cur_bytes="$(logrotate_file_size "$_lr_file")"
    [ "$_lr_cur_bytes" -ge "$_lr_max_bytes" ]
    _lr_rc=$?
    unset _lr_file _lr_size_spec _lr_max_bytes _lr_cur_bytes
    return "$_lr_rc"
}

logrotate_file() {
    _lr_file=""
    _lr_size_spec="${KAM_LOG_ROTATE_SIZE:-}"
    _lr_keep="${KAM_LOG_ROTATE_KEEP:-1}"

    while [ $# -gt 0 ]; do
        case "$1" in
        -s | --size | --rotate-size)
            [ $# -lt 2 ] && {
                error "$(i18n LOGROTATE_USAGE)"
                unset _lr_file _lr_size_spec _lr_keep
                return 2
            }
            _lr_size_spec="$2"
            shift 2
            ;;
        -k | --keep | --rotate-keep)
            [ $# -lt 2 ] && {
                error "$(i18n LOGROTATE_USAGE)"
                unset _lr_file _lr_size_spec _lr_keep
                return 2
            }
            _lr_keep="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            error "$(i18n LOGROTATE_USAGE)"
            unset _lr_file _lr_size_spec _lr_keep
            return 2
            ;;
        *)
            _lr_file="$1"
            shift
            break
            ;;
        esac
    done

    [ -z "$_lr_file" ] && [ $# -gt 0 ] && _lr_file="$1"
    if [ -z "$_lr_file" ]; then
        error "$(i18n LOGROTATE_FILE_REQUIRED)"
        unset _lr_file _lr_size_spec _lr_keep
        return 2
    fi

    _lr_max_bytes="$(logrotate_size_bytes "$_lr_size_spec")" || {
        error "$(i18n LOGROTATE_SIZE_INVALID)"
        unset _lr_file _lr_size_spec _lr_keep _lr_max_bytes
        return 2
    }

    if ! logrotate_valid_keep "$_lr_keep"; then
        error "$(i18n LOGROTATE_KEEP_INVALID)"
        unset _lr_file _lr_size_spec _lr_keep _lr_max_bytes
        return 2
    fi

    _lr_cur_bytes="$(logrotate_file_size "$_lr_file")"
    if [ "$_lr_cur_bytes" -lt "$_lr_max_bytes" ]; then
        unset _lr_file _lr_size_spec _lr_keep _lr_max_bytes _lr_cur_bytes
        return 0
    fi

    if [ "$_lr_keep" -eq 0 ]; then
        : >"$_lr_file" 2>/dev/null || return 1
        unset _lr_file _lr_size_spec _lr_keep _lr_max_bytes _lr_cur_bytes
        return 0
    fi

    _lr_i="$_lr_keep"
    rm -f "${_lr_file}.${_lr_keep}" 2>/dev/null || true
    while [ "$_lr_i" -gt 1 ]; do
        _lr_prev=$((_lr_i - 1))
        if [ -e "${_lr_file}.${_lr_prev}" ]; then
            mv "${_lr_file}.${_lr_prev}" "${_lr_file}.${_lr_i}" 2>/dev/null || true
        fi
        _lr_i="$_lr_prev"
    done

    mv "$_lr_file" "${_lr_file}.1" 2>/dev/null || return 1
    : >"$_lr_file" 2>/dev/null || return 1
    unset _lr_file _lr_size_spec _lr_keep _lr_max_bytes _lr_cur_bytes _lr_i _lr_prev
    return 0
}

logrotate() {
    case "${1:-}" in
    -h | --help | help)
        print "$(i18n LOGROTATE_USAGE)"
        return 0
        ;;
    esac
    logrotate_file "$@"
}
