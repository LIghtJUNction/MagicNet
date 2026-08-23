# shellcheck shell=ash
#
# Kamfw-free helpers for isolated sing-box subscription loads.

type magicnet_cmd_exists >/dev/null 2>&1 || magicnet_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
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

magicnet_singbox_config_file() {
    printf '%s\n' "${MAGICNET_SUB_CONFIG_FILE:-${MODDIR}/.config/sing-box/config.json}"
}

magicnet_singbox_subscription_config_file() {
    magicnet_singbox_config_file
}

magicnet_subscription_schedule_file() {
    printf '%s\n' "${MODDIR}/.config/magicnet/subscription-refresh-hours"
}

magicnet_singbox_config_has_nodes() {
    _config=$(magicnet_singbox_config_file)
    [ -f "$_config" ] || {
        unset _config
        return 1
    }
    type magicnet_singbox_ai_selectors_canonical >/dev/null 2>&1 ||
        . "${MODDIR}/lib/magicnet/singbox_subscribe/common.sh"
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks|wireguard|tuic|anytls|socks)"' "$_config" &&
        magicnet_singbox_ai_selectors_canonical "$_config"
    _rc=$?
    unset _config
    return "$_rc"
}

command -v error >/dev/null 2>&1 || error() { printf '%s\n' "ERROR: $1"; }
command -v warn >/dev/null 2>&1 || warn() { printf '%s\n' "WARN: $1"; }
command -v success >/dev/null 2>&1 || success() { printf '%s\n' "$1"; }

magicnet_jq_ai_tags_lib() {
    if type magicnet_lib_dir >/dev/null 2>&1; then
        printf '%s\n' "$(magicnet_lib_dir)/jq"
    else
        printf '%s\n' "${MODDIR}/lib/magicnet/jq"
    fi
}

magicnet_jq() {
    [ -x "${MODDIR}/bin/jq" ] || return 1
    printf '%s\n' "${MODDIR}/bin/jq"
}

magicnet_require_jq() {
    _jq="$(magicnet_jq)" || {
        if command -v magicnet_warn >/dev/null 2>&1; then
            magicnet_warn "${1:-packaged jq is unavailable; config apply rejected}"
        else
            warn "${1:-packaged jq is unavailable; config apply rejected}"
        fi
        return 1
    }
    printf '%s\n' "$_jq"
}

magicnet_jq_install_config() (
    _config="$1"
    _tmp_hint="$2"
    shift 2
    if { [ -e "$_tmp_hint" ] || [ -L "$_tmp_hint" ]; } &&
        ! rm -f "$_tmp_hint" 2>/dev/null; then
        unset _config _tmp_hint
        return 1
    fi
    _tmp=$(mktemp "${_tmp_hint}.XXXXXX") || {
        unset _config _tmp_hint
        return 1
    }
    if (umask 077; "$@" >"$_tmp") &&
        [ -f "$_tmp" ] && [ ! -L "$_tmp" ] &&
        chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config"; then
        _rc=0
    else
        _rc=$?
        [ "$_rc" -ne 0 ] || _rc=1
        rm -f "$_tmp" 2>/dev/null || true
    fi
    set -- "$_rc"
    unset _config _tmp_hint _tmp _rc
    return "$1"
)

magicnet_list_file_values() {
    _file="$1"
    [ -f "$_file" ] || return 0
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++'
}
