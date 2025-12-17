#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 基础工具模块 - 公开 API（薄包装）
# -----------------------------------------------------------------------------
# 这个文件只负责对外暴露公共函数（无下划线），具体实现应放在 `_base.sh`
# 中并使用单下划线前缀（例如 `_pprint`、`_log`）。
# =============================================================================
#
# 注意：不要在本文件中放入大量实现逻辑，修改实现请放到 `_base.sh`。
#
# 载入内部实现（_base.sh）
_kam_utils_dir="$(dirname "${0}")"
# shellcheck source=_base.sh
[ -f "${_kam_utils_dir}/_base.sh" ] && . "${_kam_utils_dir}/_base.sh"

# -------------------------
# 公共 wrapper（直接调用单下划线内部实现）
# -------------------------

pprint() {
    # 直接调用内部实现 `_pprint`（优先）
    # 如果内部实现不存在或返回非 0，则回退到 ui_print / OUTFD / printf
    if command -v _pprint >/dev/null 2>&1; then
        _pprint "$@"
        return $?
    fi

    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$1"
        return 0
    fi

    if [ -z "$OUTFD" ]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "ui_print $1" >>"/proc/self/fd/$OUTFD"
        printf '%s\n' "ui_print" >>"/proc/self/fd/$OUTFD"
    fi
}

msg()         { _msg "$@"; }
err()         { _err "$@"; }
warn()        { _warn "$@"; }
info()        { _info "$@"; }

newline()     { _newline "$@"; }
plns()        { _plns "$@"; }

rmrf()        { _rmrf "$@"; }
cp_perm()     { _cp_perm "$@"; }

set_perm_dir()  { _set_perm_dir "$@"; }
set_perm_file() { _set_perm_file "$@"; }

set_exec()    { _set_exec "$@"; }
set_selinux() { _set_selinux "$@"; }

run_quiet()   { _run_quiet "$@"; }
ignore_err()  { _ignore_err "$@"; }

command_exists() { _command_exists "$@"; }

dir_of()      { _dir_of "$@"; }

one_of()      { _one_of "$@"; }

fdate()       { _fdate "$@"; }

log()         { _log "$@"; }

# 交互式提示（如果内部实现未能加载，给出轻量提示）
if [ -t 1 ] && ! command -v _pprint >/dev/null 2>&1; then
    printf '%s\n' "Warning: failed to load kam_utils internal implementation (_base.sh not found or failed to load)"
fi
