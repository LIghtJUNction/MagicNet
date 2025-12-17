#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 基础工具模块 - 内部函数（私有实现，单下划线命名）
# -----------------------------------------------------------------------------
# 说明：
#  - 此文件包含私有实现，命名采用单下划线前缀（例如 `_pprint`, `_log`）。
#  - `base.sh` 作为对外入口，应仅定义无下划线的 wrapper 并调用这些私有函数。
# =============================================================================
#
# 注意：不要在此公开无下划线的函数名（那是 `base.sh` 的职责）。
#
# 最底层打印（兼容 Magisk ui_print 与 OUTFD）
_pure_print() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$1"
    else
        if [ -z "$OUTFD" ]; then
            printf '%s\n' "$1"
        else
            # 向 OUTFD 写入两行：一行实际消息，一行空的 ui_print 终止符
            printf '%s\n' "ui_print $1" >>"/proc/self/fd/$OUTFD"
            printf '%s\n' "ui_print" >>"/proc/self/fd/$OUTFD"
        fi
    fi
}

# ========== 私有实现（单下划线） ==========

_pprint() { _pure_print "$1"; }

_msg()  { _pprint "> $1"; }
_err()  { _pprint "⚠️ $1"; }
_warn() { _pprint "⚠️ $1"; }
_info() { _pprint "ℹ️ $1"; }

_newline() {
    count="${1:-1}"
    while [ "$count" -gt 0 ]; do
        _pprint ""
        count=$((count - 1))
    done
}

_plns() { for line in "$@"; do _pprint "$line"; done; }

_rmrf() { [ -e "$1" ] && rm -rf "$@" 2>/dev/null; }

_cp_perm() {
    src="$1" dest="$2" perm="${3:-0644}"
    [ -f "$src" ] && cp "$src" "$dest" && chmod "$perm" "$dest"
}

_set_perm_dir()  { find "$@" -type d -exec chmod 0755 {} + 2>/dev/null; }
_set_perm_file() { find "$@" -type f -exec chmod "${1:-0644}" {} + 2>/dev/null; }
_set_exec()      { chmod a+x "$@" 2>/dev/null; }
_set_selinux()   { chcon -R u:object_r:system_file:s0 "$@" 2>/dev/null; }

_run_quiet()  { "$@" >/dev/null 2>&1; }
_ignore_err() { "$@" 2>/dev/null; }

_command_exists() { command -v "$1" >/dev/null 2>&1; }

_dir_of() { dirname "$(readlink -f "$1")"; }

_one_of() {
    str="$1"
    shift
    for target in "$@"; do [ "$target" = "$str" ] && return; done
    return 1
}

_fdate() {
    # 尝试毫秒精度；如果系统不支持 %3N，调用会按系统 date 行为退化
    date +"%Y-%m-%d %H:%M:%S.%3N"
}

_log() {
    level="$1"
    message="$2"
    logfile="${LOG_FILE:-}"

    _log_normal="\033[0m"
    _log_red="\033[1;31m"
    _log_green="\033[1;32m"
    _log_yellow="\033[1;33m"
    _log_blue="\033[1;34m"

    case "$level" in
        INFO)    _log_color="${_log_blue}" ;;
        ERROR)   _log_color="${_log_red}" ;;
        WARNING) _log_color="${_log_yellow}" ;;
        DEBUG)   _log_color="${_log_green}" ;;
        *)       _log_color="${_log_green}" ;;
    esac

    _log_current_time=$(_fdate)
    _log_formatted_message="${_log_current_time} [$level]: $message"

    if [ -t 1 ]; then
        printf '%b\n' "${_log_color}${_log_formatted_message}${_log_normal}"
    elif [ -n "$logfile" ]; then
        [ ! -f "$logfile" ] && touch "$logfile" && chmod 600 "$logfile"
        printf '%s\n' "${_log_formatted_message}" >> "$logfile" 2>&1
    else
        printf '%s\n' "${_log_formatted_message}"
    fi
}

# ========== 模块/注册逻辑（内部） ==========

_get_kam_utils_dir() {
    script_dir="${KAM_UTILS_DIR:-}"
    [ -n "$script_dir" ] && echo "$script_dir" && return

    if [ -n "$KAM_UTILS_PATH" ]; then
        echo "${KAM_UTILS_PATH%/*}/kam_utils"
        return
    fi

    echo "$(dirname "$0")/kam_utils"
}

_load_module() {
    module="$1"
    dir="$(_get_kam_utils_dir)"
    module_file="${dir}/${module}.sh"

    [ -f "$module_file" ] || { _err "模块不存在: ${module}"; return 1; }

    . "$module_file" || { _err "加载模块失败: ${module}"; return 1; }

    eval "KAM_LOADED_${module}=1"
}

# 模块注册表
KAM_MODULES=""

# 注册模块。用法: register_module "module" "描述"
register_module() {
    module="$1"
    desc="$2"

    safe_module="$(printf '%s' "$module" | sed 's/[^a-zA-Z0-9_]/_/g')"
    desc_escaped="$(printf '%s' "$desc" | sed 's/\\/\\\\/g; s/\"/\\\"/g')"

    eval "KAM_MODULE_DESC_${safe_module}=\"${desc_escaped}\""
    KAM_MODULES="${KAM_MODULES} ${module}"
}

get_module_desc() {
    module="$1"
    safe_module="$(printf '%s' "$module" | sed 's/[^a-zA-Z0-9_]/_/g')"
    eval "printf '%s\n' \"\${KAM_MODULE_DESC_${safe_module}:-}\""
}

_discover_custom_modules() {
    dir="${KAM_UTILS_DIR:-}"
    if [ -z "$dir" ]; then
        dir="$(dirname "$0")"
        [ "$dir" = "." ] && dir="$(pwd)"
    fi

    for module_file in "${dir}"/*.sh; do
        [ -f "$module_file" ] || continue
        name="$(basename "$module_file" .sh)"

        # 跳过内部文件（以 '_' 开头）
        case "$name" in
            _*) continue ;;
        esac

        desc=""
        if [ -r "$module_file" ]; then
            desc=$(head -n 10 "$module_file" | grep -E "^#.*模块.*：" | head -n1 | sed 's/^#[[:space:]]*//')
            [ -z "$desc" ] && desc="自定义模块：${name}"
        fi

        register_module "$name" "$desc"
    done
}

# 加载时自动发现模块（保持向后兼容）
_discover_custom_modules
