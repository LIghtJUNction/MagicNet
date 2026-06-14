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

magicnet_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

magicnet_transparent_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/transparent-mode.conf"
}

magicnet_transparent_mode() {
    _conf="$(magicnet_transparent_conf)"
    if [ -f "$_conf" ]; then
        . "$_conf"
    fi
    case "${MAGICNET_TRANSPARENT_MODE:-tun}" in
        tproxy) printf '%s\n' "tproxy" ;;
        *) printf '%s\n' "tun" ;;
    esac
    unset _conf
}

magicnet_transparent_set_mode() {
    case "${1:-tun}" in
        tun|tproxy) ;;
        *) return 1 ;;
    esac
    mkdir -p "${MODDIR}/.config/magicnet" || return 1
    printf 'MAGICNET_TRANSPARENT_MODE=%s\n' "$1" >"$(magicnet_transparent_conf)"
}

magicnet_hotspot_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/hotspot.conf"
}

magicnet_hotspot_forward_enabled() {
    _conf="$(magicnet_hotspot_conf)"
    if [ -f "$_conf" ]; then
        . "$_conf"
    fi
    [ "${MAGIC_HOTSPOT_FORWARD:-1}" != "0" ]
    _enabled=$?
    unset _conf
    return "$_enabled"
}

magicnet_hotspot_set_forward() {
    case "${1:-proxy}" in
        proxy) _value=1 ;;
        direct) _value=0 ;;
        *) return 1 ;;
    esac
    mkdir -p "${MODDIR}/.config/magicnet" || return 1
    printf 'MAGIC_HOTSPOT_FORWARD=%s\n' "$_value" >"$(magicnet_hotspot_conf)"
    unset _value
}

magicnet_vpn_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/vpn.conf"
}

magicnet_vpn_coexist_enabled() {
    _conf="$(magicnet_vpn_conf)"
    if [ -f "$_conf" ]; then
        . "$_conf"
    fi
    [ "${MAGIC_VPN_COEXIST:-1}" != "0" ]
    _enabled=$?
    unset _conf
    return "$_enabled"
}

magicnet_vpn_set_coexist() {
    case "${1:-on}" in
        on|enable|enabled|1|true) _value=1 ;;
        off|disable|disabled|0|false) _value=0 ;;
        *) return 1 ;;
    esac
    mkdir -p "${MODDIR}/.config/magicnet" || return 1
    printf 'MAGIC_VPN_COEXIST=%s\n' "$_value" >"$(magicnet_vpn_conf)"
    unset _value
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

magicnet_mihomo_has_subscription() {
    magicnet_first_http_url "${MODDIR}/.config/mihomo/subscription.url" >/dev/null 2>&1 && return 0
    [ -f "${MODDIR}/.config/mihomo/config.yaml" ] || return 1
    awk '
        /^[^[:space:]][^:]*:/ {
            in_providers = ($0 ~ /^proxy-providers:[[:space:]]*/)
            next
        }
        in_providers && /^[[:space:]]+url:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]*url:[[:space:]]*/, "", line)
            gsub(/^["'\'']|["'\'']$/, "", line)
            if (line ~ /^https?:\/\/[^[:space:]]+$/) {
                found = 1
                exit
            }
        }
        END { exit found ? 0 : 1 }
    ' "${MODDIR}/.config/mihomo/config.yaml" >/dev/null 2>&1
}

magicnet_subscription_required_message() {
    printf '%s\n' "未配置订阅链接，无法启动内核。请先运行: cli setup <订阅链接>，或分别运行 cli sub set sing-box <订阅链接> / cli sub set mihomo premium_a <订阅链接>。"
}

magicnet_any_subscription_ready() {
    magicnet_singbox_has_subscription || magicnet_mihomo_has_subscription
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

magicnet_stop_watchdog_for_subscription_error() {
    magicnet_watchdog_stop >/dev/null 2>&1 || true
}

magicnet_require_subscription_or_stop() {
    if magicnet_any_subscription_ready; then
        magicnet_clear_startup_error
        return 0
    fi
    magicnet_mark_subscription_missing
    magicnet_stop_watchdog_for_subscription_error
    return 1
}

magicnet_mihomo_provider_table() {
    _config="${MODDIR}/.config/mihomo/config.yaml"
    [ -f "$_config" ] || return 1
    awk '
        function flush_provider() {
            if (name != "" && url ~ /^https?:\/\/[^[:space:]]+$/) {
                print name "\t" url "\t" path
            }
            name = ""
            url = ""
            path = ""
        }
        /^[^[:space:]][^:]*:/ {
            flush_provider()
            in_providers = ($0 ~ /^proxy-providers:[[:space:]]*/)
            next
        }
        in_providers && /^  [^[:space:]][^:]*:[[:space:]]*$/ {
            flush_provider()
            name = $0
            sub(/^[[:space:]]*/, "", name)
            sub(/:[[:space:]]*$/, "", name)
            next
        }
        in_providers && name != "" && /^    url:[[:space:]]*/ {
            url = $0
            sub(/^[[:space:]]*url:[[:space:]]*/, "", url)
            gsub(/^["'\'']|["'\'']$/, "", url)
            next
        }
        in_providers && name != "" && /^    path:[[:space:]]*/ {
            path = $0
            sub(/^[[:space:]]*path:[[:space:]]*/, "", path)
            gsub(/^["'\'']|["'\'']$/, "", path)
            next
        }
        END {
            flush_provider()
        }
    ' "$_config"
    unset _config
}

magicnet_need_nodes_message() {
    case "${1:-}" in
        mihomo)
            magicnet_warn "未读取到 mihomo 节点，已停止 mihomo。请先运行: cli setup <订阅链接> 或 cli sub set mihomo premium_a <订阅链接>"
            config set override.description "[MagicNet]: mihomo has no nodes; configure subscription" 2>/dev/null || true
            ;;
        *)
            magicnet_warn "未读取到 sing-box 节点，已停止 sing-box。请先运行: cli setup <订阅链接> 或 cli sub set sing-box <订阅链接>"
            config set override.description "[MagicNet]: sing-box has no nodes; configure subscription" 2>/dev/null || true
            ;;
    esac
}

magicnet_prepare_singbox_nodes_unlocked() {
    if ! magicnet_singbox_has_subscription; then
        magicnet_need_nodes_message sing-box
        return 1
    fi
    if [ "${MAGICNET_FORCE_SUB_REFRESH:-0}" != "1" ] && magicnet_cmd_exists sing-box; then
        import __singbox__
        if is_singbox_running >/dev/null 2>&1; then
            return 0
        fi
    fi

    . "${MODDIR}/lib/magicnet_singbox_subscribe.sh"
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

    magicnet_warn "sing-box subscription update failed; refusing to start with existing cached nodes"
    _message="sing-box 订阅更新失败，已拒绝使用旧节点启动。请检查订阅链接或网络后重试。"
    mkdir -p "${MODDIR}/.state" 2>/dev/null || true
    printf '%s\n' "$_message" >"${MODDIR}/.state/startup-error" 2>/dev/null || true
    config set override.description "[MagicNet]: sing-box subscription update failed" 2>/dev/null || true
    unset _attempt _attempts _delay _message
    return 1
}

magicnet_prepare_singbox_nodes() {
    _old_lock_timeout="${MAGICNET_CONFIG_LOCK_TIMEOUT:-}"
    MAGICNET_CONFIG_LOCK_TIMEOUT="${MAGICNET_SUB_CONFIG_LOCK_TIMEOUT:-180}"
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
    if command -v curl >/dev/null 2>&1; then
        _api=$(curl -sS --max-time 5 http://127.0.0.1:9090/proxies 2>/dev/null || true)
        if [ -n "$_api" ]; then
            printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks|Selector|WireGuard|TUIC|AnyTLS)"' && {
                unset _api
                return 0
            }
        fi
    fi
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] && grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks|wireguard|tuic|anytls)"' "$_config"
    _rc=$?
    unset _api _config
    return "$_rc"
}

magicnet_prepare_mihomo_nodes_unlocked() {
    if ! magicnet_mihomo_has_subscription; then
        magicnet_need_nodes_message mihomo
        return 1
    fi
    if [ "${MAGICNET_FORCE_SUB_REFRESH:-0}" != "1" ] && magicnet_cmd_exists mihomo; then
        import __mihomo__
        if is_mihomo_running >/dev/null 2>&1; then
            return 0
        fi
    fi

    _config="${MODDIR}/.config/mihomo/config.yaml"
    _workdir="${MODDIR}/.config/mihomo"
    mkdir -p "${_workdir}/proxies" 2>/dev/null || true
    if [ "$(magicnet_mihomo_provider_table | wc -l | tr -d ' ')" -le 0 ]; then
        _first_mihomo_url=$(magicnet_first_http_url "${MODDIR}/.config/mihomo/subscription.url" 2>/dev/null || true)
        if [ -n "$_first_mihomo_url" ] && [ -x "${MODDIR}/cli" ]; then
            "${MODDIR}/cli" sub set mihomo premium_a "$_first_mihomo_url" >/dev/null 2>&1 || true
        fi
    fi

    _provider_count=$(magicnet_mihomo_provider_table | wc -l | tr -d ' ')
    if [ "${_provider_count:-0}" -le 0 ]; then
        magicnet_need_nodes_message mihomo
        unset _config _workdir _first_mihomo_url _provider_count
        return 1
    fi

    # Let mihomo fetch and validate http proxy-providers itself. Some providers
    # return different payloads based on User-Agent, so prefetching with curl/wget
    # can reject a subscription that mihomo can load correctly.
    magicnet_log "mihomo provider config is present; provider download is delegated to mihomo."
    unset _config _workdir _first_mihomo_url _provider_count
    return 0
}

magicnet_prepare_mihomo_nodes() {
    _old_lock_timeout="${MAGICNET_CONFIG_LOCK_TIMEOUT:-}"
    MAGICNET_CONFIG_LOCK_TIMEOUT="${MAGICNET_SUB_CONFIG_LOCK_TIMEOUT:-180}"
    magicnet_with_config_lock magicnet_prepare_mihomo_nodes_unlocked
    _prepare_rc=$?
    if [ -n "$_old_lock_timeout" ]; then
        MAGICNET_CONFIG_LOCK_TIMEOUT="$_old_lock_timeout"
    else
        unset MAGICNET_CONFIG_LOCK_TIMEOUT
    fi
    unset _old_lock_timeout
    return "$_prepare_rc"
}

magicnet_mihomo_running_has_nodes() {
    _workdir="${MODDIR}/.config/mihomo"
    for _provider_file in "${_workdir}"/proxies/*.yaml; do
        [ -f "$_provider_file" ] || continue
        grep -Eq '^proxies:[[:space:]]*$' "$_provider_file" && {
            unset _workdir _provider_file
            return 0
        }
    done

    if ! command -v curl >/dev/null 2>&1; then
        unset _workdir _provider_file
        return 0
    fi

    _tries=0
    while [ "$_tries" -lt "${MAGICNET_MIHOMO_NODE_WAIT_TRIES:-10}" ]; do
        _provider_api=$(curl -sS --max-time 3 http://127.0.0.1:9090/providers/proxies 2>/dev/null || true)
        if [ -n "$_provider_api" ]; then
            printf '%s' "$_provider_api" | grep -Eq '"proxies":[[:space:]]*\[[[:space:]]*\{' && {
                unset _workdir _provider_file _tries _provider_api _proxy_api
                return 0
            }
        fi

        _proxy_api=$(curl -sS --max-time 3 http://127.0.0.1:9090/proxies 2>/dev/null || true)
        if [ -n "$_proxy_api" ]; then
            printf '%s' "$_proxy_api" | grep -Eq '"(all|proxies)"[[:space:]]*:[[:space:]]*\[[^]]*"[^"]+"' && {
                unset _workdir _provider_file _tries _provider_api _proxy_api
                return 0
            }
        fi

        _tries=$((_tries + 1))
        sleep 2
    done

    unset _workdir _provider_file _tries _provider_api _proxy_api
    return 1
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
        mihomo|clash)
            printf '%s\n' "mihomo"
            unset _current_core_conf _requested_core
            return 0
            ;;
    esac

    if magicnet_singbox_has_subscription && ! magicnet_mihomo_has_subscription; then
        printf '%s\n' "sing-box"
    elif magicnet_mihomo_has_subscription && ! magicnet_singbox_has_subscription; then
        printf '%s\n' "mihomo"
    else
        printf '%s\n' "${MAGICNET_AUTO_DEFAULT_CORE:-sing-box}"
    fi
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
    mkdir -p "$_lock_parent"
    while ! mkdir "$_lock_dir" 2>/dev/null; do
        _lock_pid="$(sed -n '1p' "${_lock_dir}/pid" 2>/dev/null)"
        if [ -n "$_lock_pid" ] && ! kill -0 "$_lock_pid" 2>/dev/null; then
            rm -rf "$_lock_dir" 2>/dev/null || true
            continue
        fi
        if [ "$_lock_waited" -ge "$_lock_timeout" ]; then
            magicnet_warn "Timed out waiting for config lock: $_lock_dir"
            unset _lock_dir _lock_parent _lock_waited _lock_timeout _lock_pid
            return 1
        fi
        sleep 1
        _lock_waited=$((_lock_waited + 1))
    done
    printf '%s\n' "$$" >"${_lock_dir}/pid"
    unset _lock_dir _lock_parent _lock_waited _lock_timeout _lock_pid
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
    "$@"
    _lock_rc=$?
    magicnet_config_lock_release
    MAGICNET_CONFIG_LOCK_HELD=0
    unset MAGICNET_CONFIG_LOCK_HELD
    return "$_lock_rc"
}
