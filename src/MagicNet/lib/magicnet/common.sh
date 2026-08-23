# shellcheck shell=ash
#
# MagicNet module runtime.
# This file owns MagicNet-specific lifecycle handlers and keeps entry scripts
# thin while using kamfw's phase dispatcher as the runtime boundary.

type magicnet_source_primitives >/dev/null 2>&1 || {
    if [ -n "${BASH_VERSION:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
        # BASH_SOURCE is guarded by the Bash-only branch above.
        # shellcheck disable=SC3054
        . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/primitives.sh"
    else
        . "${MODDIR}/lib/magicnet/primitives.sh"
    fi
}
magicnet_source_primitives
. "$(magicnet_lib_dir)/subscribe_bootstrap.sh"

import wait
import rich

PATH="${MODDIR}/bin:${MODDIR}/system/bin:${PATH:-}"
export PATH

magicnet_log() {
    info "$1"
}

magicnet_warn() {
    warn "$1"
}

magicnet_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

magicnet_module_disabled() {
    [ -f "${MODDIR}/disable" ] || [ -f "${MODDIR}/remove" ]
}

# Persisted *.conf files are data. Never source them into the privileged
# runtime shell; read one exact assignment and reject duplicates.
magicnet_conf_value() (
    _conf_file="$1"
    _conf_key="$2"
    [ -f "$_conf_file" ] || return 1
    awk -F= -v key="$_conf_key" '
        $1 == key { value = substr($0, index($0, "=") + 1); count++ }
        END { if (count == 1) print value; else exit 1 }
    ' "$_conf_file"
)

magicnet_transparent_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/transparent-mode.conf"
}

magicnet_transparent_mode() {
    printf '%s\n' "tun"
}

magicnet_transparent_set_mode() {
    case "${1:-tun}" in
        tun) _mode="tun" ;;
        *) return 1 ;;
    esac
    mkdir -p "${MODDIR}/.config/magicnet" || return 1
    _mode_file="$(magicnet_transparent_conf)" || {
        unset _mode
        return 1
    }
    _mode_tmp="${_mode_file}.tmp.$$"
    if ! (umask 077; printf 'MAGICNET_TRANSPARENT_MODE=%s\n' "$_mode" >"$_mode_tmp"); then
        rm -f "$_mode_tmp" 2>/dev/null || true
        unset _mode _mode_file _mode_tmp
        return 1
    fi
    if ! mv -f "$_mode_tmp" "$_mode_file"; then
        rm -f "$_mode_tmp" 2>/dev/null || true
        unset _mode _mode_file _mode_tmp
        return 1
    fi
    # Published module state is consumed by callers after sourcing.
    # shellcheck disable=SC2034
    MAGICNET_TRANSPARENT_MODE="$_mode"
    unset _mode _mode_file _mode_tmp
}

magicnet_first_http_url() {
    [ -f "$1" ] || return 1
    awk '
        {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /^https:\/\/[^[:space:]@]+$/) {
                print line
                found = 1
                exit 0
            }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

magicnet_singbox_has_subscription() {
    [ -s "${MODDIR}/.config/sing-box/subscription.local" ] ||
        magicnet_first_http_url "${MODDIR}/.config/sing-box/subscription.url" >/dev/null 2>&1
}

magicnet_singbox_api_has_nodes() {
    magicnet_cmd_exists curl || return 1
    _api=$(curl -sS --max-time 5 http://127.0.0.1:9090/proxies 2>/dev/null ||
        curl -sS --max-time 5 http://127.0.0.1:9090/providers/proxies 2>/dev/null || true)
    [ -n "$_api" ] || {
        unset _api
        return 1
    }
    printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks|AnyTLS|TUIC|Socks|SOCKS|Selector|WireGuard)"'
    _rc=$?
    unset _api
    return "$_rc"
}

magicnet_singbox_standalone_config_ready() {
    _config="$(magicnet_singbox_config_file)"
    _marker="${MODDIR}/.config/sing-box/standalone-config"
    [ -f "$_marker" ] && [ -s "$_config" ] &&
        grep -Eq '"inbounds"[[:space:]]*:' "$_config" &&
        grep -Eq '"outbounds"[[:space:]]*:' "$_config"
    _rc=$?
    unset _config _marker
    return "$_rc"
}

magicnet_subscription_required_message() {
    printf '%s\n' "No subscription source is configured, so the kernel cannot start. Configure a URL or import a local subscription file."
}

magicnet_any_subscription_ready() {
    magicnet_singbox_standalone_config_ready || magicnet_singbox_has_subscription || magicnet_singbox_config_has_nodes
}

magicnet_mark_subscription_missing() {
    _message="$(magicnet_subscription_required_message)"
    magicnet_warn "$_message"
    mkdir -p "${MODDIR}/.state" 2>/dev/null || true
    printf '%s\n' "$_message" >"${MODDIR}/.state/startup-error" 2>/dev/null || true
    config set override.description "[MagicNet]: $_message" 2>/dev/null || true
    unset _message
}

magicnet_clear_startup_error() {
    rm -f "${MODDIR}/.state/startup-error" 2>/dev/null || true
}

magicnet_require_subscription_or_stop() {
    if magicnet_any_subscription_ready; then
        magicnet_clear_startup_error
        return 0
    fi
    magicnet_mark_subscription_missing
    return 1
}

magicnet_need_nodes_message() {
    magicnet_warn "No sing-box nodes were found. Configure a subscription URL or import a local subscription file."
    config set override.description "[MagicNet]: sing-box has no nodes; configure subscription" 2>/dev/null || true
}

magicnet_prepare_singbox_nodes_unlocked() {
    if [ "${MAGICNET_FORCE_SUB_REFRESH:-0}" != "1" ] && magicnet_cmd_exists sing-box; then
        import __singbox__
        if is_singbox_running >/dev/null 2>&1; then
            return 0
        fi
    fi
    if magicnet_singbox_standalone_config_ready; then
        magicnet_log "Using validated standalone sing-box config; subscription refresh skipped."
        return 0
    fi
    if [ "${MAGICNET_FORCE_SUB_REFRESH:-0}" != "1" ] && magicnet_singbox_config_has_nodes; then
        magicnet_log "Using cached sing-box config; subscription refresh skipped before startup."
        return 0
    fi

    if ! magicnet_singbox_has_subscription; then
        magicnet_need_nodes_message sing-box
        return 1
    fi

    . "${MODDIR}/lib/magicnet_singbox_subscribe.sh"
    if [ "${MAGICNET_FORCE_SUB_REFRESH:-0}" != "1" ]; then
        if magicnet_singbox_replay_cached_outbounds; then
            magicnet_log "Restored sing-box nodes from the local subscription cache."
            return 0
        fi
        magicnet_warn "No usable sing-box node cache was found; refreshing the subscription before startup."
    fi

    _attempt=1
    _attempts="${MAGICNET_SUB_STARTUP_ATTEMPTS:-4}"
    _delay="${MAGICNET_SUB_STARTUP_RETRY_DELAY:-15}"
    while [ "$_attempt" -le "$_attempts" ]; do
        if [ "$_attempt" -gt 1 ]; then
            magicnet_warn "Retrying sing-box subscription update before startup (${_attempt}/${_attempts})..."
        else
            magicnet_log "Updating sing-box subscription before startup..."
        fi
        if MAGICNET_SUB_REQUIRE_FRESH=1 magicnet_singbox_update_subscription; then
            unset _attempt _attempts _delay
            return 0
        fi
        [ "$_attempt" -ge "$_attempts" ] && break
        sleep "$_delay"
        _attempt=$((_attempt + 1))
    done

    magicnet_warn "sing-box subscription update failed and no usable cached nodes are available"
    _message="sing-box 没有可用的节点缓存，订阅更新也失败。请检查订阅链接或网络后重试。"
    mkdir -p "${MODDIR}/.state" 2>/dev/null || true
    printf '%s\n' "$_message" >"${MODDIR}/.state/startup-error" 2>/dev/null || true
    config set override.description "[MagicNet]: sing-box subscription update failed" 2>/dev/null || true
    unset _attempt _attempts _delay _message
    return 1
}

magicnet_with_sub_config_lock() {
    _old_lock_timeout="${MAGICNET_CONFIG_LOCK_TIMEOUT:-}"
    MAGICNET_CONFIG_LOCK_TIMEOUT="${MAGICNET_SUB_CONFIG_LOCK_TIMEOUT:-45}"
    magicnet_with_config_lock "$@"
    _sub_lock_rc=$?
    if [ -n "$_old_lock_timeout" ]; then
        MAGICNET_CONFIG_LOCK_TIMEOUT="$_old_lock_timeout"
    else
        unset MAGICNET_CONFIG_LOCK_TIMEOUT
    fi
    unset _old_lock_timeout
    return "$_sub_lock_rc"
}

magicnet_prepare_singbox_nodes() {
    magicnet_with_sub_config_lock magicnet_prepare_singbox_nodes_unlocked
}

magicnet_singbox_running_has_nodes() {
    magicnet_singbox_standalone_config_ready ||
        magicnet_singbox_config_has_nodes ||
        magicnet_singbox_api_has_nodes
}

magicnet_config_lock_dir() {
    printf '%s\n' "$MODDIR/.state/config.lock"
}

magicnet_config_lock_proc_start() {
    magicnet_proc_start "$1"
}

magicnet_config_lock_proc_live() {
    _owner_proc_pid="$1"
    _owner_proc_stat="/proc/$_owner_proc_pid/stat"
    if [ -r "$_owner_proc_stat" ]; then
        _owner_proc_state="$(sed -n 's/^.*) \([^ ]\) .*$/\1/p' \
            "$_owner_proc_stat" 2>/dev/null || true)"
        [ -n "$_owner_proc_state" ] && [ "$_owner_proc_state" != "Z" ] || {
            unset _owner_proc_pid _owner_proc_stat _owner_proc_state
            return 1
        }
    fi
    unset _owner_proc_pid _owner_proc_stat _owner_proc_state
    return 0
}

magicnet_config_lock_owner_matches() {
    _owner_check="$1"
    _owner_check_pid="$(printf '%s\n' "$_owner_check" | cut -d: -f1)"
    case "$_owner_check_pid" in
        '' | *[!0-9]*)
            unset _owner_check _owner_check_pid
            return 1
            ;;
    esac
    if [ "$_owner_check" = "$_owner_check_pid" ]; then
        if kill -0 "$_owner_check_pid" 2>/dev/null &&
            magicnet_config_lock_proc_live "$_owner_check_pid"; then
            _owner_check_rc=0
        else
            _owner_check_rc=1
        fi
        unset _owner_check _owner_check_pid
        return "$_owner_check_rc"
    fi
    _owner_check_start="$(printf '%s\n' "$_owner_check" | cut -d: -f2)"
    case "$_owner_check_start" in
        '' | *[!0-9]*)
            unset _owner_check _owner_check_pid _owner_check_start
            return 1
            ;;
    esac
    if ! kill -0 "$_owner_check_pid" 2>/dev/null ||
        ! magicnet_config_lock_proc_live "$_owner_check_pid"; then
        unset _owner_check _owner_check_pid _owner_check_start
        return 1
    fi
    _owner_check_live_start="$(magicnet_config_lock_proc_start "$_owner_check_pid")"
    [ -n "$_owner_check_live_start" ] &&
        [ "$_owner_check_live_start" = "$_owner_check_start" ]
    _owner_check_rc=$?
    unset _owner_check _owner_check_pid _owner_check_start \
        _owner_check_live_start
    return "$_owner_check_rc"
}

magicnet_config_lock_reclaim() {
    _reclaim_expected="$1"
    _reclaim_dir="$(magicnet_config_lock_dir)"
    _reclaim_current="$(sed -n '1p' "$_reclaim_dir/pid" 2>/dev/null || true)"
    [ "$_reclaim_current" = "$_reclaim_expected" ] || {
        unset _reclaim_expected _reclaim_dir _reclaim_current
        return 1
    }
    # Re-check ownership immediately before removing the marker, then use
    # rmdir instead of recursive deletion.  A concurrent new owner can make
    # rmdir fail, but cannot have its marker recursively removed by us.
    rm -f "$_reclaim_dir/pid" 2>/dev/null || {
        unset _reclaim_expected _reclaim_dir _reclaim_current
        return 1
    }
    rmdir "$_reclaim_dir" 2>/dev/null
    _reclaim_rc=$?
    unset _reclaim_expected _reclaim_dir _reclaim_current
    return "$_reclaim_rc"
}

magicnet_config_lock_acquire() {
    [ "${MAGICNET_CONFIG_LOCK_HELD:-0}" = "1" ] && return 0
    _lock_dir="$(magicnet_config_lock_dir)"
    _lock_parent="${_lock_dir%/*}"
    _lock_waited=0
    _lock_timeout="${MAGICNET_CONFIG_LOCK_TIMEOUT:-20}"
    _lock_no_pid_wait=0
    _lock_no_pid_timeout="${MAGICNET_CONFIG_LOCK_NO_PID_TIMEOUT:-3}"
    mkdir -p "$_lock_parent"
    while ! mkdir "$_lock_dir" 2>/dev/null; do
        _lock_pid="$(sed -n '1p' "$_lock_dir/pid" 2>/dev/null || true)"
        if [ -n "$_lock_pid" ] && ! magicnet_config_lock_owner_matches "$_lock_pid"; then
            magicnet_config_lock_reclaim "$_lock_pid" && continue
        fi
        if [ -z "$_lock_pid" ]; then
            _lock_no_pid_wait=$((_lock_no_pid_wait + 1))
            if [ "$_lock_no_pid_wait" -ge "$_lock_no_pid_timeout" ]; then
                magicnet_config_lock_reclaim "$_lock_pid" || true
                _lock_no_pid_wait=0
                continue
            fi
        else
            _lock_no_pid_wait=0
        fi
        if [ "$_lock_waited" -ge "$_lock_timeout" ]; then
            magicnet_warn "Timed out waiting for config lock: $_lock_dir"
            unset _lock_dir _lock_parent _lock_waited _lock_timeout _lock_no_pid_wait _lock_no_pid_timeout _lock_pid
            return 1
        fi
        sleep 1
        _lock_waited=$((_lock_waited + 1))
    done
    _lock_start="$(magicnet_config_lock_proc_start "$$")"
    if [ -n "$_lock_start" ]; then
        if ! printf '%s:%s\n' "$$" "$_lock_start" >"$_lock_dir/pid"; then
            rm -f "$_lock_dir/pid" 2>/dev/null || true
            rmdir "$_lock_dir" 2>/dev/null || true
            unset _lock_dir _lock_parent _lock_waited _lock_timeout _lock_no_pid_wait _lock_no_pid_timeout _lock_pid _lock_start
            return 1
        fi
    else
        # Keep compatibility with environments without /proc start times;
        # the legacy PID form remains fail-closed for a live process.
        if ! printf '%s\n' "$$" >"$_lock_dir/pid"; then
            rm -f "$_lock_dir/pid" 2>/dev/null || true
            rmdir "$_lock_dir" 2>/dev/null || true
            unset _lock_dir _lock_parent _lock_waited _lock_timeout _lock_no_pid_wait _lock_no_pid_timeout _lock_pid _lock_start
            return 1
        fi
    fi
    unset _lock_dir _lock_parent _lock_waited _lock_timeout _lock_no_pid_wait _lock_no_pid_timeout _lock_pid _lock_start
}

magicnet_config_lock_release() {
    _lock_dir="$(magicnet_config_lock_dir)"
    _lock_owner="$(sed -n '1p' "$_lock_dir/pid" 2>/dev/null || true)"
    _lock_start="$(magicnet_config_lock_proc_start "$$")"
    if [ -n "$_lock_start" ]; then
        _lock_self="$$:$_lock_start"
    else
        _lock_self="$$"
    fi
    # A signal trap from an old owner must never remove a lock that another
    # process has already acquired after the old owner died.  Remove our
    # marker first and use rmdir so a newly-created non-empty lock directory
    # cannot be recursively deleted by the stale trap.
    if [ "$_lock_owner" = "$_lock_self" ]; then
        rm -f "$_lock_dir/pid" 2>/dev/null || true
        rmdir "$_lock_dir" 2>/dev/null || true
    fi
    unset _lock_dir _lock_owner _lock_start _lock_self
}

magicnet_with_config_lock() {
    if [ "${MAGICNET_CONFIG_LOCK_HELD:-0}" = "1" ]; then
        "$@"
        return $?
    fi
    magicnet_config_lock_acquire || return 1
    MAGICNET_CONFIG_LOCK_HELD=1
    # Do not replace caller-owned signal handlers here.  Subscription updates
    # install a transaction rollback handler before entering this critical
    # section; replacing and then clearing it made an interrupted activation
    # leave both journals and locks behind.  An uncatchable process death is
    # still safe because lock ownership is PID/start-time bound and the next
    # caller can reclaim it.
    "$@"
    _lock_rc=$?
    magicnet_config_lock_release
    MAGICNET_CONFIG_LOCK_HELD=0
    unset MAGICNET_CONFIG_LOCK_HELD
    return "$_lock_rc"
}

magicnet_recover_interrupted_subscription() (
    [ -d "${MODDIR}/.state/sing-box/subscription-transaction" ] || return 0
    _started=$(date +%s 2>/dev/null || printf '%s' 0)
    magicnet_log "Interrupted subscription transaction detected; recovery is starting."
    if ! command -v magicnet_singbox_transaction_reconcile >/dev/null 2>&1; then
        . "${MODDIR}/lib/magicnet_singbox_subscribe.sh" || return 1
    fi
    if magicnet_singbox_update_lock_active; then
        magicnet_log "Interrupted subscription journal is owned by a live updater; recovery deferred."
        return 0
    fi

    _rc=0
    magicnet_with_sub_config_lock magicnet_singbox_recover_interrupted_locked || _rc=$?
    _finished=$(date +%s 2>/dev/null || printf '%s' 0)
    _elapsed=$((_finished - _started))
    if [ "$_rc" -eq 0 ]; then
        magicnet_log "Interrupted subscription recovery completed in ${_elapsed}s."
    else
        magicnet_warn "Interrupted subscription recovery failed after ${_elapsed}s"
    fi
    return "$_rc"
)
