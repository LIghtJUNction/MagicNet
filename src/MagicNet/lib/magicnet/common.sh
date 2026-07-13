# shellcheck shell=ash
#
# MagicNet module runtime.
# This file owns MagicNet-specific lifecycle handlers and keeps entry scripts
# thin while using kamfw's phase dispatcher as the runtime boundary.

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

magicnet_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

magicnet_transparent_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/transparent-mode.conf"
}

magicnet_transparent_mode() {
    _mode="${MAGICNET_TRANSPARENT_MODE:-}"
    if [ -z "$_mode" ] && [ -f "$(magicnet_transparent_conf)" ]; then
        # shellcheck disable=SC1090
        . "$(magicnet_transparent_conf)" 2>/dev/null || true
        _mode="${MAGICNET_TRANSPARENT_MODE:-}"
    fi
    case "${_mode:-tun}" in
        proxy|external-tun|hybrid|tun) printf '%s\n' "${_mode:-tun}" ;;
        *) printf '%s\n' "tun" ;;
    esac
    unset _mode
}

magicnet_transparent_set_mode() {
    case "${1:-tun}" in
        proxy|external-tun|hybrid|tun) _mode="$1" ;;
        *) return 1 ;;
    esac
    mkdir -p "${MODDIR}/.config/magicnet" || return 1
    printf 'MAGICNET_TRANSPARENT_MODE=%s\n' "$_mode" >"$(magicnet_transparent_conf)"
    MAGICNET_TRANSPARENT_MODE="$_mode"
    unset _mode
}

magicnet_first_http_url() {
    [ -f "$1" ] || return 1
    awk '
        {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /^https?:\/\/[^[:space:]]+$/) {
                print line
                found = 1
                exit 0
            }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

magicnet_singbox_has_subscription() {
    magicnet_first_http_url "${MODDIR}/.config/sing-box/subscription.url" >/dev/null 2>&1
}

magicnet_singbox_config_has_nodes() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || {
        unset _config
        return 1
    }
    [ "$(command -v magicnet_singbox_ai_selectors_canonical 2>/dev/null)" ] ||
        . "${MODDIR}/lib/magicnet/singbox_subscribe/common.sh"
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks|wireguard|tuic|anytls)"' "$_config" &&
        magicnet_singbox_ai_selectors_canonical "$_config"
    _rc=$?
    unset _config
    return "$_rc"
}

magicnet_subscription_required_message() {
    printf '%s\n' "No subscription URL is configured, so the kernel cannot start. Run: cli setup <subscription-url> or cli sub set sing-box <subscription-url>."
}

magicnet_any_subscription_ready() {
    magicnet_singbox_has_subscription || magicnet_singbox_config_has_nodes
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
    magicnet_warn "No sing-box nodes were found. Run: cli setup <subscription-url> or cli sub set sing-box <subscription-url>."
    config set override.description "[MagicNet]: sing-box has no nodes; configure subscription" 2>/dev/null || true
}

magicnet_prepare_singbox_nodes_unlocked() {
    if [ "${MAGICNET_FORCE_SUB_REFRESH:-0}" != "1" ] && magicnet_cmd_exists sing-box; then
        import __singbox__
        if is_singbox_running >/dev/null 2>&1; then
            return 0
        fi
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

magicnet_prepare_singbox_nodes() {
    _old_lock_timeout="${MAGICNET_CONFIG_LOCK_TIMEOUT:-}"
    MAGICNET_CONFIG_LOCK_TIMEOUT="${MAGICNET_SUB_CONFIG_LOCK_TIMEOUT:-45}"
    magicnet_with_config_lock magicnet_prepare_singbox_nodes_unlocked
    _prepare_rc=$?
    if [ -n "$_old_lock_timeout" ]; then
        MAGICNET_CONFIG_LOCK_TIMEOUT="$_old_lock_timeout"
    else
        unset MAGICNET_CONFIG_LOCK_TIMEOUT
    fi
    unset _old_lock_timeout
    return "$_prepare_rc"
}

magicnet_singbox_running_has_nodes() {
    magicnet_singbox_config_has_nodes && return 0
    if command -v curl >/dev/null 2>&1; then
        _api=$(curl -sS --max-time 5 http://127.0.0.1:9090/proxies 2>/dev/null || true)
        if [ -n "$_api" ]; then
            printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks|Selector|WireGuard|TUIC|AnyTLS)"' && {
                unset _api
                return 0
            }
        fi
    fi
    magicnet_singbox_config_has_nodes
    _rc=$?
    unset _api
    return "$_rc"
}

magicnet_preferred_core() {
    _current_core_conf="${MODDIR}/.config/magicnet/current-core.conf"
    _requested_core="${MAGICNET_DEFAULT_CORE:-}"
    if [ "${MAGICNET_STRICT_CORE:-0}" = "1" ] && [ -n "$_requested_core" ]; then
        MAGICNET_DEFAULT_CORE="$_requested_core"
    elif [ -f "$_current_core_conf" ]; then
        . "$_current_core_conf"
    elif [ -f "${MODDIR}/.config/magicnet/core.conf" ]; then
        . "${MODDIR}/.config/magicnet/core.conf"
    fi

    case "${MAGICNET_DEFAULT_CORE:-auto}" in
        sing-box|singbox)
            printf '%s\n' "sing-box"
            unset _current_core_conf _requested_core
            return 0
            ;;
    esac

    printf '%s\n' "sing-box"
    unset _current_core_conf _requested_core
}

magicnet_config_lock_dir() {
    printf '%s\n' "${MODDIR}/.state/config.lock"
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
        _lock_pid="$(sed -n '1p' "${_lock_dir}/pid" 2>/dev/null)"
        if [ -n "$_lock_pid" ] && ! kill -0 "$_lock_pid" 2>/dev/null; then
            rm -rf "$_lock_dir" 2>/dev/null || true
            continue
        fi
        if [ -z "$_lock_pid" ]; then
            _lock_no_pid_wait=$((_lock_no_pid_wait + 1))
            if [ "$_lock_no_pid_wait" -ge "$_lock_no_pid_timeout" ]; then
                rm -rf "$_lock_dir" 2>/dev/null || true
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
    printf '%s\n' "$$" >"${_lock_dir}/pid"
    unset _lock_dir _lock_parent _lock_waited _lock_timeout _lock_no_pid_wait _lock_no_pid_timeout _lock_pid
}

magicnet_config_lock_release() {
    rm -rf "$(magicnet_config_lock_dir)" 2>/dev/null || true
}

magicnet_with_config_lock() {
    if [ "${MAGICNET_CONFIG_LOCK_HELD:-0}" = "1" ]; then
        "$@"
        return $?
    fi
    magicnet_config_lock_acquire || return 1
    MAGICNET_CONFIG_LOCK_HELD=1
    trap 'magicnet_config_lock_release' INT TERM HUP
    "$@"
    _lock_rc=$?
    trap - INT TERM HUP
    magicnet_config_lock_release
    MAGICNET_CONFIG_LOCK_HELD=0
    unset MAGICNET_CONFIG_LOCK_HELD
    return "$_lock_rc"
}
