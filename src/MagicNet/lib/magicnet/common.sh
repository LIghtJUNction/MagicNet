# shellcheck shell=ash
#
# MagicNet module runtime.
# This file owns MagicNet-specific lifecycle handlers and keeps entry scripts
# thin while using kamfw's phase dispatcher as the runtime boundary.

import wait
import rich

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
        /^[[:space:]]*url:[[:space:]]*/ {
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

magicnet_preferred_core() {
    case "${MAGICNET_DEFAULT_CORE:-auto}" in
        sing-box|singbox) printf '%s\n' "sing-box"; return 0 ;;
        mihomo|clash) printf '%s\n' "mihomo"; return 0 ;;
    esac

    if magicnet_singbox_has_subscription && ! magicnet_mihomo_has_subscription; then
        printf '%s\n' "sing-box"
    elif magicnet_mihomo_has_subscription && ! magicnet_singbox_has_subscription; then
        printf '%s\n' "mihomo"
    else
        printf '%s\n' "${MAGICNET_AUTO_DEFAULT_CORE:-sing-box}"
    fi
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
