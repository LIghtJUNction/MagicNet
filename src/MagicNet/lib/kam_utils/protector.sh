# shellcheck shell=ash
# 保护器模块：自动在检测到启动失败（boot-loop）时自动禁用模块
# =============================================================================
# Public wrapper for protector internal implementation.
#
# 提供：
#   protect_module <module_path> [max_attempts] [window_seconds] [grace_seconds] [reason]
#     - module_path: 要保护的模块目录（例如 /data/adb/modules/<module>）
#     - max_attempts: 在 window_seconds 窗口内的失败阈值（默认 3）
#     - window_seconds: 时间窗口（秒）（默认 600）
#     - grace_seconds: 启动完成等待宽限期（秒）（默认 30）
#     - reason: 可选的禁用原因字符串（会写入 disable 文件）
#
#   protector_status <module_path>
#     - 打印保护器当前在该模块下的状态和最近失败记录
#
# 如果作为脚本直接执行：
#   - `protector.sh protect <module_path> ...` 或直接 `protector.sh <module_path> ...` 会触发 protect 操作
#   - `protector.sh status <module_path>` 会打印状态
# =============================================================================

_kam_utils_dir="$(dirname "${0}")"
# shellcheck source=_protector.sh
[ -f "${_kam_utils_dir}/_protector.sh" ] && . "${_kam_utils_dir}/_protector.sh"

# Public API wrapper: try to auto-disable a module when boot failures happen.
# Returns:
#  0 - 未触发禁用（或已被手动禁用/状态正常）
#  1 - 参数错误或模块路径不可用
#  2 - 已创建 disable 文件（模块被自动禁用）
#  other codes - 错误
protect_module() {
    if [ -z "${_protector_auto_disable:-}" ]; then
        printf '%s\n' "protector: internal implementation not available" >&2
        return 1
    fi

    module_path="$1"
    if [ -z "$module_path" ]; then
        printf '%s\n' "Usage: protect_module <module_path> [max_attempts] [window_seconds] [grace_seconds] [reason]" >&2
        return 1
    fi

    # forward arguments to internal function
    _protector_auto_disable "$@"
    return $?
}

# 早期模式：供 post-fs-data.sh 调用（记录一次尝试并在阈值达成时立即禁用）
protect_module_early() {
    if [ -z "${_protector_record_attempt_and_maybe_disable:-}" ]; then
        printf '%s\n' "protector: internal early implementation not available" >&2
        return 1
    fi

    module_path="$1"
    if [ -z "$module_path" ]; then
        printf '%s\n' "Usage: protect_module_early <module_path> [max_attempts] [window_seconds] [reason]" >&2
        return 1
    fi

    # forward to internal early-mode recorder
    _protector_record_attempt_and_maybe_disable "$@"
    return $?
}

# 清除模块记录（在 boot-completed 时调用，用于标记本次启动成功，免去此前失败记录）
protector_clear() {
    if [ -z "${_protector_clear_state:-}" ]; then
        printf '%s\n' "protector: internal clear function not available" >&2
        return 1
    fi

    module_path="$1"
    if [ -z "$module_path" ]; then
        printf '%s\n' "Usage: protector_clear <module_path>" >&2
        return 1
    fi

    _protector_clear_state "$module_path"
    return $?
}

# Public status helper
protector_status() {
    if [ -z "${_protector_status:-}" ]; then
        printf '%s\n' "protector: internal status function not available" >&2
        return 1
    fi

    module_path="$1"
    if [ -z "$module_path" ]; then
        printf '%s\n' "Usage: protector_status <module_path>" >&2
        return 1
    fi

    _protector_status "$module_path"
    return $?
}

# If invoked directly, provide a tiny CLI
if [ "${1:-}" != "" ]; then
    case "$1" in
        protect|run)
            shift
            protect_module "$@"
            exit $?
            ;;
        early|protect_early)
            shift
            protect_module_early "$@"
            exit $?
            ;;
        clear|clear_state)
            shift
            protector_clear "$@"
            exit $?
            ;;
        status)
            shift
            protector_status "$@"
            exit $?
            ;;
        --help|-h)
            cat <<'USAGE'
Usage:
  protector.sh protect <module_path> [max_attempts] [window_seconds] [grace_seconds] [reason]
  protector.sh early <module_path> [max_attempts] [window_seconds] [reason]
  protector.sh clear <module_path>
  protector.sh status  <module_path>
  protector.sh <module_path> [max_attempts] [window_seconds] [grace_seconds] [reason]  # shorthand protect
USAGE
            exit 0
            ;;
        *)
            # default: assume it's a module path and run protect
            protect_module "$@"
            exit $?
            ;;
    esac
fi
