# shellcheck shell=ash
# 依赖控制模块：支持软依赖/硬依赖
# =============================================================================
# Public wrapper for dependency checks (apps / modules)
#
# 提供函数（供安装脚本直接调用）：
#   require_app <package> [--soft] [--message "提示信息"]
#     - 默认为硬依赖（缺失时退出 1）
#     - 加上 --soft 则只打印警告并返回非零，不退出
#
#   require_module <module_id_or_path> [version_spec] [--soft] [--message "提示信息"]
#     - version_spec 示例：">=1.2.3", "<2.0", "1.2.3"（默认解释为 >=）
#     - 若未提供 version_spec，仅检查模块存在性
#
#   check_app <package>                -> 返回 0/1（是否安装）
#   check_module <module> [spec]      -> 返回 0（满足）/2（未安装）/3（版本不可用）/4（版本不匹配）
#
# CLI 示例：
#   protector.sh require_app com.example.app --soft --message "Optional dependency"
#   protector.sh require_module mymod '>=1.2.0' --message "Please update moudle"
# =============================================================================

MODDIR=${MODDIR:-${0%/*}}
# shellcheck source=_depends.sh
kam_source_impl depends || { echo "错误: 无法加载内部实现: _depends.sh" >&2; return 1; }

_depends__warn() {
    msg="$1"
    if command -v log_warn >/dev/null 2>&1; then
        log_warn "$msg"
    else
        printf 'WARN: %s\n' "$msg" >&2
    fi
}

# 版本要求检查
require_version() {
    _require_version_impl "$@"
}

_depends__error() {
    msg="$1"
    if command -v log_error >/dev/null 2>&1; then
        log_error "$msg"
    else
        printf 'ERROR: %s\n' "$msg" >&2
    fi
}

# -------------------------
# App checks
# -------------------------
# check_app <package>
# Return: 0 if installed, 1 if not installed (or cannot determine)
check_app() {
    pkg="$1"
    _depends_app_installed "$pkg"
    rc=$?
    # _depends_app_installed returns 0 installed, 1 not installed, 2 cannot determine
    if [ "$rc" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# require_app <package> [--soft] [--message "msg"]
# - default behavior: hard require -> exit 1 on missing
require_app() {
    pkg="$1"
    shift || true
    soft=0
    message=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --soft|-s) soft=1; shift ;;
            -m|--message) message="$2"; shift 2 ;;
            *) if [ -z "$message" ]; then message="$1"; else message="$message $1"; fi; shift ;;
        esac
    done

    if [ -z "$pkg" ]; then
        _depends__error "require_app: package name required"
        return 1
    fi

    _depends_app_installed "$pkg"
    ok=$?
    if [ "$ok" -eq 0 ]; then
        return 0
    fi

    # not installed or cannot determine
    if [ -n "$message" ]; then
        msg="$message"
    else
        msg="Required app not found: $pkg"
    fi

    if [ "$soft" -eq 1 ]; then
        _depends__warn "$msg"
        return 2
    else
        _depends__error "$msg"
        exit 1
    fi
}

# -------------------------
# Module checks
# -------------------------
# check_module <module_id_or_path> [version_spec]
# Return codes:
#  0 = satisfied
#  2 = not installed
#  4 = installed but version mismatch (including missing versionCode)
#  1 = error / invalid args
check_module() {
    moduleref="$1"
    spec="$2"

    if [ -z "$moduleref" ]; then
        _depends__error "check_module: module id/path required"
        return 1
    fi

    _depends_module_satisfies "$moduleref" "$spec"
    return $?
}

# require_module <module_id_or_path> [version_spec] [--soft] [--message "msg"]
# - default hard dependency -> exit 1 if not satisfied
# - with --soft -> only warn and return non-zero (2/3/4)
require_module() {
    moduleref="$1"
    shift || true
    spec=""
    soft=0
    message=""

    # Parse optional version_spec if it looks like a version/operator
    if [ $# -gt 0 ]; then
        case "$1" in
            '>='*|'<='*|'=='*|'='*|'>'*|'<'*|[0-9]*)
                # If the token starts with a digit, treat bare version like '1.2.3' as '>=1.2.3'
                case "$1" in
                    [0-9]*)
                        spec=">=$1"
                        ;;
                    *)
                        spec="$1"
                        ;;
                esac
                shift
                ;;
        esac
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --soft|-s) soft=1; shift ;;
            -m|--message) message="$2"; shift 2 ;;
            *) if [ -z "$message" ]; then message="$1"; else message="$message $1"; fi; shift ;;
        esac
    done

    if [ -z "$moduleref" ]; then
        _depends__error "require_module: module id/path required"
        return 1
    fi

    rc=0
    _depends_module_satisfies "$moduleref" "$spec"
    rc=$?

    if [ "$rc" -eq 0 ]; then
        return 0
    fi

    # prepare message if not provided
    if [ -n "$message" ]; then
        msg="$message"
    else
        case "$rc" in
            2) msg="Required module not installed: $moduleref" ;;
            4)
                moddir="$(_depends_find_module_path "$moduleref")"
                curver="$(_depends_get_module_version "$moddir" 2>/dev/null || true)"
                msg="Module $moduleref does not meet required versionCode ${spec:-(required)} (installed: ${curver:-unknown}; path: ${moddir:-unknown})"
                ;;
            *) msg="Module dependency not satisfied: $moduleref (code $rc)" ;;
        esac
    fi

    if [ "$soft" -eq 1 ]; then
        _depends__warn "$msg"
        return $rc
    else
        _depends__error "$msg"
        exit 1
    fi
}

# -------------------------
# Simple CLI for convenience
# -------------------------
# 只有当脚本被直接执行时才处理 CLI 参数（检查 $0 是否包含脚本名）
case "$(basename "$0" 2>/dev/null)" in
    depends.sh)
        if [ "${1:-}" != "" ]; then
            cmd="$1"
            shift
            case "$cmd" in
        check_app)
            check_app "$@"; exit $?
            ;;
        require_app)
            require_app "$@"; exit $?
            ;;
        check_module)
            check_module "$@"; exit $?
            ;;
        require_module)
            require_module "$@"; exit $?
            ;;
        protect_help|help|-h|--help)
            cat <<'USAGE'
Usage:
  depends.sh check_app <package>
  depends.sh require_app <package> [--soft] [--message "msg"]
  depends.sh check_module <module_id_or_path> [version_spec]
  depends.sh require_module <module_id_or_path> [version_spec] [--soft] [--message "msg"]

Notes:
  - version_spec examples (versionCode): ">=123", "<200", "150" (interpreted as >=150)
  - require_* by default will abort (exit 1) on hard missing; add --soft to only warn
USAGE
            exit 0
            ;;
        *)
            printf 'Unknown command: %s\n' "$cmd" >&2
            exit 2
            ;;
            esac
        fi
        ;;
esac

# EOF
