# shellcheck shell=ash
#
# __at_exit__.sh
#
# General-purpose at-exit helper for kamfw
#
# Features:
# - Provides APIs to register arbitrary handlers to run on shell EXIT:
#     - `at_exit_add <command_or_function_name>`    # add a handler (unique, newline-separated)
#     - `at_exit_remove <command_or_function_name>` # remove matching handlers
#     - `at_exit_list`                              # diagnostic: list handlers
#     - `at_exit_clear`                             # remove all handlers
#     - `at_exit_register_trap` / `at_exit_unregister_trap`
# - Includes a ready-to-use handler for installing files according to
#   install_exclude/install_include filters (kept for compatibility).
#   This handler is implemented as `__at_exit_install_from_filters` and can be
#   added explicitly via `at_exit_add '__at_exit_install_from_filters'` or by
#   calling `install_register_exit_hook` (preferred). It is NOT auto-added on load.
#
# Notes & Guidelines:
# - All user-visible strings use i18n keys via set_i18n / i18n / t().
# - External commands are checked with `command -v` before invocation when
#   they are critical.
# - Default policy: do NOT overwrite existing files in non-interactive contexts.
#

# Test / verification (suggested):
# 1. Source this helper and call `at_exit_add 'echo hi'` then exit the shell;
#    verify the handler ran.
# 2. During a simulated install (export MODPATH/KAM_MODULE_ROOT), add filters
#    and verify that `__at_exit_install_from_filters` installs matching files
#    when the shell exits (it is auto-added if MODPATH is present).
#
# New i18n keys added:
#   AT_EXIT_REGISTERED, AT_EXIT_NO_HANDLERS, AT_EXIT_RUN_START,
#   AT_EXIT_DONE, AT_EXIT_HANDLER_FAILED
#

# -----------------------------------------------------------------------------
# i18n: generic at-exit messages
# -----------------------------------------------------------------------------
set_i18n "AT_EXIT_REGISTERED" \
    "zh" "已注册 at-exit 钩子" \
    "en" "At-exit hook registered" \
    "ja" "終了時フックが登録されました" \
    "ko" "종료 훅이 등록되었습니다"

set_i18n "AT_EXIT_NO_HANDLERS" \
    "zh" "没有注册任何 at-exit 处理器" \
    "en" "No at-exit handlers registered" \
    "ja" "登録された終了時ハンドラはありません" \
    "ko" "등록된 종료 훅이 없습니다"

set_i18n "AT_EXIT_RUN_START" \
    "zh" "执行 at-exit 处理器..." \
    "en" "Running at-exit handlers..." \
    "ja" "終了時ハンドラを実行します..." \
    "ko" "종료 훅 실행 중..."

set_i18n "AT_EXIT_DONE" \
    "zh" "at-exit 处理完成" \
    "en" "At-exit handlers finished" \
    "ja" "終了時ハンドラの実行が完了しました" \
    "ko" "종료 훅 실행이 완료되었습니다"

set_i18n "AT_EXIT_HANDLER_FAILED" \
    "zh" "处理器失败: %s" \
    "en" "Handler failed: %s" \
    "ja" "ハンドラ失敗: %s" \
    "ko" "훅 실패: %s"

# -----------------------------------------------------------------------------
# Internal state
# -----------------------------------------------------------------------------
__at_exit_installed="" # non-empty after trap registration
__at_exit_running=""   # guard to prevent re-entry
__at_exit_handlers=""  # newline-separated list of handler commands/functions

# -----------------------------------------------------------------------------
# Logging helpers (use existing ui helpers when available; fallback to print)
# -----------------------------------------------------------------------------
__at_exit_log_info() {
    # i18n 失败不允许走 `|| echo` 输出旁路；直接使用 key 作为回退。
    # 这里的 2>/dev/null 仅用于抑制 i18n 内部非关键噪声，不影响控制流。
    msg="$(i18n "$1" 2>/dev/null)"
    [ -n "$msg" ] || msg="$1"
    if type info >/dev/null 2>&1; then
        info "$msg"
    else
        print "$msg"
    fi
}

__at_exit_log_success_t() {
    key="$1"
    arg="$2"
    # 禁止 `|| echo`；按顺序尝试：i18n+t -> i18n -> key
    _msg="$(i18n "$key" 2>/dev/null | t "$arg" 2>/dev/null)"
    if [ -z "$_msg" ]; then
        _msg="$(i18n "$key" 2>/dev/null)"
    fi
    [ -n "$_msg" ] || _msg="$key"

    if type success >/dev/null 2>&1; then
        success "$_msg"
    else
        print "$_msg"
    fi
}

__at_exit_log_warn_t() {
    key="$1"
    arg="$2"
    # 禁止 `|| echo`；按顺序尝试：i18n+t -> i18n -> key
    _msg="$(i18n "$key" 2>/dev/null | t "$arg" 2>/dev/null)"
    if [ -z "$_msg" ]; then
        _msg="$(i18n "$key" 2>/dev/null)"
    fi
    [ -n "$_msg" ] || _msg="$key"

    if type warn >/dev/null 2>&1; then
        warn "$_msg"
    else
        print "$_msg"
    fi
}

# -----------------------------------------------------------------------------
# Handler list management
# -----------------------------------------------------------------------------
# Add handler(s) (unique). Handlers are arbitrary shell commands or function names.
at_exit_add() {
    [ $# -eq 0 ] && return 0
    for cmd in "$@"; do
        # Deduplicate against existing list
        eval 'cur=${__at_exit_handlers}'
        OLDIFS=$IFS
        IFS='
'
        _found=0
        for l in $cur; do
            if [ "$l" = "$cmd" ]; then
                _found=1
                break
            fi
        done
        IFS=$OLDIFS
        if [ "$_found" -eq 0 ]; then
            if [ -z "${cur:-}" ]; then
                __at_exit_handlers="$cmd"
            else
                __at_exit_handlers="$cur
$cmd"
            fi
        fi
    done
    return 0
}

# Remove handler(s) by exact match
at_exit_remove() {
    [ $# -eq 0 ] && return 0
    OLDIFS=$IFS
    IFS='
'
    _new=""
    for l in ${__at_exit_handlers:-}; do
        _skip=0
        for rm in "$@"; do
            if [ "$l" = "$rm" ]; then
                _skip=1
                break
            fi
        done
        [ "$_skip" -eq 1 ] && continue
        if [ -z "${_new:-}" ]; then
            _new="$l"
        else
            _new="$_new
$l"
        fi
    done
    IFS=$OLDIFS
    __at_exit_handlers="${_new:-}"
    return 0
}

# List handlers (diagnostic)
at_exit_list() {
    [ -z "${__at_exit_handlers:-}" ] && {
        _no_handlers_msg="$(i18n 'AT_EXIT_NO_HANDLERS' 2>/dev/null)"
        [ -n "$_no_handlers_msg" ] || _no_handlers_msg="No at-exit handlers registered"
        print "$_no_handlers_msg"
        return 0
    }
    OLDIFS=$IFS
    IFS='
'
    for l in $__at_exit_handlers; do
        print "$l"
    done
    IFS=$OLDIFS
    return 0
}

# Clear all handlers
at_exit_clear() {
    unset __at_exit_handlers
    return 0
}

# -----------------------------------------------------------------------------
# Run registered handlers (executed in the trap context)
# -----------------------------------------------------------------------------
__at_exit_run_handlers() {
    [ -z "${__at_exit_handlers:-}" ] && return 0

    __at_exit_log_info "AT_EXIT_RUN_START"

    OLDIFS=$IFS
    IFS='
'
    for h in $__at_exit_handlers; do
        [ -z "$h" ] && continue
        # Execute handler in the current shell (so critical failures like `abort`
        # behave consistently). If a handler needs isolation, it may run its own subshell.
        if ! eval "$h"; then
            __at_exit_log_warn_t "AT_EXIT_HANDLER_FAILED" "$h"
        fi
    done
    IFS=$OLDIFS

    __at_exit_log_info "AT_EXIT_DONE"
    return 0
}

# -----------------------------------------------------------------------------
# Master EXIT handler
# -----------------------------------------------------------------------------
__at_exit_master_handler() {
    [ -n "${__at_exit_running:-}" ] && return 0
    __at_exit_running=1

    # If no handlers are registered, return without work.
    if [ -z "${__at_exit_handlers:-}" ]; then
        __at_exit_log_info "AT_EXIT_NO_HANDLERS"
        unset __at_exit_running
        return 0
    fi

    # Run each registered handler
    # 非关键路径：at-exit handler 链的执行本身不应中断退出流程，但失败必须可见。
    if ! __at_exit_run_handlers; then
        warn "WARN: __at_exit_run_handlers failed unexpectedly"
    fi

    unset __at_exit_running
    return 0
}

# -----------------------------------------------------------------------------
# Trap registration / unregistration
# -----------------------------------------------------------------------------
at_exit_register_trap() {
    [ -n "${__at_exit_installed:-}" ] && return 0

    trap "__at_exit_master_handler" EXIT
    __at_exit_installed=1

    # Informative message in interactive sessions
    [ -t 1 ] && __at_exit_log_info "AT_EXIT_REGISTERED"
    return 0
}

at_exit_unregister_trap() {
    [ -z "${__at_exit_installed:-}" ] && return 0

    if ! trap - EXIT 2>/dev/null; then
        warn "WARN: failed to clear EXIT trap"
    fi
    unset __at_exit_installed
    return 0
}

# End of file
