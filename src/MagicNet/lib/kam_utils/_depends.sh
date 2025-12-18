# shellcheck shell=ash
# =============================================================================
# Depends - internal helpers for dependency checks (apps & modules)
# =============================================================================
#
# Provides low-level functions that installation scripts can use to verify:
#  - App installed (by package name)
#  - Module installed, and optional version constraints (>=, <=, >, <, =)
#
# This file is intended as an internal implementation (underscore-prefixed).
# Higher-level public wrappers (e.g., depends.sh) can call these helpers and
# implement soft/hard behavior + user-facing messages.
#
# Functions (core):
#  - _depends_app_installed <package>                -> returns 0 if installed
#  - _depends_module_dir <module_id_or_path>         -> echoes module dir, 0 if found
#  - _depends_get_module_version <module_dir>        -> echoes version, return 0 or 1
#  - _depends_version_compare <v1> <v2>              -> return 0 equal, 1 v1>v2, 2 v1<v2
#  - _depends_version_satisfies <cur> <op> <req>     -> return 0 if satisfies
#  - _depends_module_satisfies <module_id> <spec>    -> checks module + version spec
#
# Return code conventions for module checks:
#  0 = satisfied
#  1 = argument / internal error
#  2 = not installed
#  3 = installed but version not available (cannot verify)
#  4 = installed but version mismatch
#
# Notes:
#  - Version comparison is numeric on dot-separated segments (semver-ish).
#  - Module version is read from module.prop 'version=' (fallback to JSON 'version' if present).
# =============================================================================

# Internal logging helper (falls back to printf)
_depends__log() {
    msg="$1"
    if command -v _pure_print >/dev/null 2>&1; then
        _pure_print "$msg"
    else
        printf '%s\n' "$msg"
    fi
}

# -----------------------------
# App (package) existence check
# -----------------------------
# Usage: _depends_app_installed <package_name>
# Returns: 0 if installed, 1 otherwise
_depends_app_installed() {
    pkg="$1"
    [ -n "$pkg" ] || return 1

    # Prefer 'pm' if available
    if command -v pm >/dev/null 2>&1; then
        # pm path <pkg> returns success if installed
        if pm path "$pkg" >/dev/null 2>&1; then
            return 0
        fi
        # fallback: pm list packages
        if pm list packages "$pkg" 2>/dev/null | grep -q "package:${pkg}"; then
            return 0
        fi
    fi

    # Fallback: check typical data directories (may indicate installed app)
    if [ -d "/data/data/$pkg" ] || [ -d "/data/user/0/$pkg" ]; then
        return 0
    fi

    return 1
}

# ---------------------------------------
# Locate module installation directory
# ---------------------------------------
# Usage: _depends_module_dir <module_id_or_absolute_path>
# Prints the path if found and returns 0. Returns 1 if not found.
_depends_module_dir() {
    mod="$1"
    [ -n "$mod" ] || return 1

    # If absolute path provided and exists, return it
    if [ -d "$mod" ]; then
        printf '%s' "$mod"
        return 0
    fi

    # Common Magisk locations to check
    for base in \
        /data/adb/modules \
        /data/adb/modules_update \
        /data/magisk/modules \
        /magisk/modules \
        /sdcard/Modules  # (fallback/back-compat)
    do
        if [ -d "${base}/${mod}" ]; then
            printf '%s' "${base}/${mod}"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------
# Extract module version from module dir
# ---------------------------------------
# Usage: _depends_get_module_version <module_dir>
# Prints version string if available, returns 0; else returns 1
_depends_get_module_version() {
    moddir="$1"
    [ -n "$moddir" ] || return 1

    # Try module.prop (format: version=1.2.3 or versionName=)
    if [ -f "${moddir}/module.prop" ]; then
        # Prefer 'version=' — fallback to 'versionName=' or 'versionCode='
        ver=$(sed -n -e 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*//Ip' -e 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*//Ip' -e 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*//Ip' "${moddir}/module.prop" | head -n1)
        if [ -n "$ver" ]; then
            # Trim whitespace
            ver=$(printf '%s' "$ver" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            printf '%s' "$ver"
            return 0
        fi
    fi


    return 1
}

# ---------------------------------------------------
# Version comparison helpers (numeric dot segments)
# ---------------------------------------------------
# _depends_version_compare <v1> <v2>
# returns:
#  0 if v1 == v2
#  1 if v1 > v2
#  2 if v1 < v2
_depends_version_compare() {
    v1="$1"
    v2="$2"

    # Normalize to initial numeric dot sequence (strip suffix like '-alpha')
    v1=$(printf '%s' "$v1" | sed -E 's/^([0-9]+(\.[0-9]+)*).*$/\1/')
    v2=$(printf '%s' "$v2" | sed -E 's/^([0-9]+(\.[0-9]+)*).*$/\1/')

    # iterate segments
    while :; do
        seg1=${v1%%.*}
        seg2=${v2%%.*}

        # Determine rest
        if [ "$v1" = "$seg1" ]; then v1_rest=""; else v1_rest=${v1#*.}; fi
        if [ "$v2" = "$seg2" ]; then v2_rest=""; else v2_rest=${v2#*.}; fi

        seg1=${seg1:-0}
        seg2=${seg2:-0}

        # Keep only digits (drop unexpected chars)
        case "$seg1" in ''|*[!0-9]*) seg1=0 ;; esac
        case "$seg2" in ''|*[!0-9]*) seg2=0 ;; esac

        if [ "$seg1" -gt "$seg2" ]; then return 1; fi
        if [ "$seg1" -lt "$seg2" ]; then return 2; fi

        # if both rests are empty, they are equal
        if [ -z "$v1_rest" ] && [ -z "$v2_rest" ]; then
            return 0
        fi

        v1="$v1_rest"
        v2="$v2_rest"
    done
}

# _depends_version_satisfies <cur_version> <operator> <required_version>
# operator: =, ==, >=, <=, >, <
_depends_version_satisfies() {
    cur="$1"
    op="$2"
    req="$3"

    [ -n "$cur" ] || return 1
    [ -n "$op" ] || op='='
    [ -n "$req" ] || return 1

    _depends_version_compare "$cur" "$req"
    cmp="$?"  # 0 equal, 1 cur>req, 2 cur<req

    case "$op" in
        "="|"==")
            [ "$cmp" -eq 0 ] && return 0 || return 4
            ;;
        ">")
            [ "$cmp" -eq 1 ] && return 0 || return 4
            ;;
        "<")
            [ "$cmp" -eq 2 ] && return 0 || return 4
            ;;
        ">=")
            case "$cmp" in 1|0) return 0 ;; *) return 4 ;; esac
            ;;
        "<=")
            case "$cmp" in 2|0) return 0 ;; *) return 4 ;; esac
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------
# Parse a version spec like '>=1.2.3' or '1.0.0' (defaults to '=')
# Echoes two fields separated by '|' : operator|version
# ---------------------------------------------------
_depends_parse_version_spec() {
    spec="$1"
    case "$spec" in
        '>=') op='>='; ver='' ;;
        '<=') op='<='; ver='' ;;
        '>'*) op='>'; ver="${spec#>}";;
        '<'*) op='<'; ver="${spec#<}";;
        '>=*') op='>='; ver="${spec#>=}";;
        '<=*') op='<='; ver="${spec#<=}";;
        '='*) op='='; ver="${spec#=}";;
        '==*') op='='; ver="${spec#==}";;
        *) op='='; ver="$spec";;
    esac
    printf '%s|%s' "$op" "$ver"
}

# ---------------------------------------------------
# Check module presence and version spec
# ---------------------------------------------------
# Usage: _depends_module_satisfies <module_id_or_path> <version_spec_optional>
# Returns:
#  0 = satisfied
#  2 = not installed
#  3 = installed but version unavailable
#  4 = installed but version mismatch
#  1 = error/invalid args
_depends_module_satisfies() {
    moduleref="$1"
    spec="$2"

    [ -n "$moduleref" ] || return 1

    # find module dir
    if module_dir="$(_depends_module_dir "$moduleref")"; then
        :
    else
        return 2
    fi

    # if no spec provided, installation presence is enough
    [ -z "$spec" ] && return 0

    # parse spec
    parsed="$(_depends_parse_version_spec "$spec")"
    op=$(printf '%s' "$parsed" | awk -F'|' '{print $1}')
    req_ver=$(printf '%s' "$parsed" | awk -F'|' '{print $2}')

    if [ -z "$req_ver" ]; then
        # invalid requirement
        return 1
    fi

    if cur_ver="$(_depends_get_module_version "$module_dir")"; then
        :
    else
        return 3
    fi

    _depends_version_satisfies "$cur_ver" "$op" "$req_ver"
    rc="$?"
    return "$rc"
}

# ---------------------------------------------------
# Convenience: format a helpful message for failures
# ---------------------------------------------------
# Usage: _depends_msg_unmet <type> <identifier> <spec> <custom_message>
#   type: app|module
# Example:
#   _depends_msg_unmet module com.example.foo '>=1.2.0' 'Please install foo v>=1.2'
_depends_msg_unmet() {
    typ="$1"; id="$2"; spec="$3"; msg="$4"
    if [ -n "$msg" ]; then
        _depends__log "$msg"
        return 0
    fi
    case "$typ" in
        app) _depends__log "Required app not found: $id" ;;
        module) _depends__log "Required module not satisfied: $id (require: $spec)" ;;
        *) _depends__log "Dependency not satisfied: $id (type: $typ)" ;;
    esac
    return 0
}

# ---------------------------------------------------
# require_version - 检查 Root 管理器版本
# ---------------------------------------------------
# 用法: require_version "magisk:>=28000" "ksu:>=11986" --mode=abort --message="msg"
# 支持的格式:
#   magisk:>=28000  - Magisk 版本 >= 28000
#   ksu:>=11986     - KernelSU 版本 >= 11986
#   apatch:>=10000  - APatch 版本 >= 10000
_require_version_impl() {
    mode="warn"
    custom_msg=""
    requirements=""
    
    # 解析参数
    for arg in "$@"; do
        case "$arg" in
            --mode=*)
                mode="${arg#--mode=}"
                ;;
            --message=*)
                custom_msg="${arg#--message=}"
                ;;
            *)
                requirements="$requirements $arg"
                ;;
        esac
    done
    
    # 检测当前 Root 类型
    root_type=""
    root_ver=0
    
    # 加载调试模块（如果可用）
    if [ -f "${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}/_debug.sh" ]; then
        . "${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}/_debug.sh"
        _kam_debug_block_start "require_version"
        _kam_debug_log "参数: $*"
        _kam_debug_var "mode"
        _kam_debug_var "custom_msg"
        _kam_debug_var "requirements"
        _kam_debug_log "=== 环境变量检查 ==="
        _kam_debug_var "KSU"
        _kam_debug_var "KSU_VER"
        _kam_debug_var "KSU_VER_CODE"
        _kam_debug_var "KSU_KERNEL_VER_CODE"
        _kam_debug_var "MAGISK_VER"
        _kam_debug_var "MAGISK_VER_CODE"
        _kam_debug_var "MAGISK"
        _kam_debug_var "APATCH"
        _kam_debug_var "APATCH_VER"
        _kam_debug_var "APATCH_VER_CODE"
    fi
    
    if [ -n "${KSU:-}" ] || [ -n "${KSU_VER_CODE:-}" ]; then
        root_type="ksu"
        root_ver="${KSU_VER_CODE:-0}"
        _kam_debug_enabled && _kam_debug_log "检测到: KernelSU (版本代码: $root_ver)"
    elif [ -n "${APATCH:-}" ] || [ -n "${APATCH_VER_CODE:-}" ]; then
        root_type="apatch"
        root_ver="${APATCH_VER_CODE:-0}"
        _kam_debug_enabled && _kam_debug_log "检测到: APatch (版本代码: $root_ver)"
    elif [ -n "${MAGISK_VER_CODE:-}" ]; then
        root_type="magisk"
        root_ver="${MAGISK_VER_CODE:-0}"
        _kam_debug_enabled && _kam_debug_log "检测到: Magisk (版本代码: $root_ver)"
    else
        _kam_debug_enabled && _kam_debug_log "未检测到任何 Root 管理器"
        _kam_debug_enabled && _kam_debug_block_end "require_version"
        # 没有检测到 Root 管理器，可能是普通环境
        if [ "$mode" = "abort" ]; then
            _depends__log "错误: 未检测到 Root 管理器（Magisk/KernelSU/APatch）"
            _depends__log "请在 Root 环境中运行此安装程序"
            exit 1
        else
            _depends__log "警告: 未检测到 Root 管理器，跳过版本检查"
            return 1
        fi
    fi
    
    # 检查每个要求
    _kam_debug_enabled && _kam_debug_log "=== 版本要求检查 ==="
    for req in $requirements; do
        req_type="${req%%:*}"
        req_spec="${req#*:}"
        
        _kam_debug_enabled && _kam_debug_log "检查需求: $req"
        _kam_debug_enabled && _kam_debug_indent "类型: $req_type" 1
        _kam_debug_enabled && _kam_debug_indent "规格: $req_spec" 1
        
        # 跳过不匹配的类型
        if [ "$req_type" != "$root_type" ]; then
            _kam_debug_enabled && _kam_debug_indent "类型不匹配，跳过 (当前: $root_type)" 1
            continue
        fi
        
        # 解析版本要求
        op="${req_spec%%[0-9]*}"
        ver="${req_spec#$op}"
        
        # 默认操作符为 >=
        [ -z "$op" ] && op=">="
        
        _kam_debug_enabled && _kam_debug_indent "解析: 操作符='$op', 版本='$ver'" 1
        
        # 比较版本
        case "$op" in
            ">=")
                _kam_debug_enabled && _kam_debug_indent "检查: $root_ver >= $ver ?" 1
                if [ "$root_ver" -lt "$ver" ]; then
                    [ -n "$custom_msg" ] && _depends__log "$custom_msg" || \
                        _depends__log "  -> 版本不满足: 需要 $req_type 版本 >= $ver，当前版本: $root_ver"
                    _kam_debug_enabled && _kam_debug_block_end "require_version"
                    [ "$mode" = "abort" ] && exit 1
                    return 1
                else
                    _kam_debug_enabled && _kam_debug_indent "版本满足: $root_ver >= $ver" 1
                fi
                ;;
            ">")
                _kam_debug_enabled && _kam_debug_indent "检查: $root_ver > $ver ?" 1
                if [ "$root_ver" -le "$ver" ]; then
                    [ -n "$custom_msg" ] && _depends__log "$custom_msg" || \
                        _depends__log "  -> 版本不满足: 需要 $req_type 版本 > $ver，当前版本: $root_ver"
                    _kam_debug_enabled && _kam_debug_block_end "require_version"
                    [ "$mode" = "abort" ] && exit 1
                    return 1
                else
                    _kam_debug_enabled && _kam_debug_indent "版本满足: $root_ver > $ver" 1
                fi
                ;;
            "="|"==")
                _kam_debug_enabled && _kam_debug_indent "检查: $root_ver == $ver ?" 1
                if [ "$root_ver" -ne "$ver" ]; then
                    [ -n "$custom_msg" ] && _depends__log "$custom_msg" || \
                        _depends__log "  -> 版本不满足: 需要 $req_type 版本 = $ver，当前版本: $root_ver"
                    _kam_debug_enabled && _kam_debug_block_end "require_version"
                    [ "$mode" = "abort" ] && exit 1
                    return 1
                else
                    _kam_debug_enabled && _kam_debug_indent "版本满足: $root_ver == $ver" 1
                fi
                ;;
        esac
    done
    
    _kam_debug_enabled && _kam_debug_log "所有版本要求检查通过"
    _kam_debug_enabled && _kam_debug_block_end "require_version"
    return 0
}

# ---------------------------------------------------
# End of _depends.sh
# ---------------------------------------------------
