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
MODDIR=${MODDIR:-${0%/*}}
# shellcheck source=_base.sh
kam_source_impl base || { echo "错误: 无法找到 _base.sh" >&2; return 1; }


# -------------------------
# 公共 wrapper（直接调用单下划线内部实现）
# -------------------------

pprint() { _pprint "$@"; }

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

# 模块管理
register_module()  { _register_module "$@"; }
get_module_desc()  { _get_module_desc "$@"; }
load_module()      { _load_module "$@"; }
get_kam_utils_dir() { _get_kam_utils_dir "$@"; }

# 交互式提示（如果内部实现未能加载，给出轻量提示）
if [ -t 1 ] && ! command -v _pprint >/dev/null 2>&1; then
    printf '%s\n' "Warning: failed to load kam_utils internal implementation (_base.sh not found or failed to load)"
fi
