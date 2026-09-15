# shellcheck shell=ash
#
# Canonical shell-side access to the local sing-box Clash API.
# Endpoint parsing and validation belongs to the Rust CLI so shell callers do
# not duplicate assumptions about the controller host or port.

magicnet_singbox_api_endpoint() {
    [ -x "${MODDIR}/cli" ] || return 1
    _magicnet_api_endpoint="$("${MODDIR}/cli" api endpoint 2>/dev/null)" || {
        unset _magicnet_api_endpoint
        return 1
    }
    [ -n "$_magicnet_api_endpoint" ] || {
        unset _magicnet_api_endpoint
        return 1
    }
    printf '%s\n' "$_magicnet_api_endpoint"
    unset _magicnet_api_endpoint
}

magicnet_singbox_api_port() {
    _magicnet_api_endpoint="$(magicnet_singbox_api_endpoint)" || return 1
    _magicnet_api_port="${_magicnet_api_endpoint##*:}"
    case "$_magicnet_api_port" in
    '' | 0 | *[!0-9]*)
        unset _magicnet_api_endpoint _magicnet_api_port
        return 1
        ;;
    esac
    [ "$_magicnet_api_port" -le 65535 ] 2>/dev/null || {
        unset _magicnet_api_endpoint _magicnet_api_port
        return 1
    }
    printf '%s\n' "$_magicnet_api_port"
    unset _magicnet_api_endpoint _magicnet_api_port
}

# Override the legacy probe from common.sh. Runtime health must follow the
# configured external_controller rather than assuming the bootstrap default.
magicnet_singbox_api_has_nodes() {
    magicnet_cmd_exists curl || return 1
    _api_endpoint="$(magicnet_singbox_api_endpoint)" || return 1
    _api=$(curl -sS --max-time 5 "${_api_endpoint}/proxies" 2>/dev/null ||
        curl -sS --max-time 5 "${_api_endpoint}/providers/proxies" 2>/dev/null || true)
    [ -n "$_api" ] || {
        unset _api_endpoint _api
        return 1
    }
    printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks|AnyTLS|TUIC|Socks|SOCKS|Selector|WireGuard)"'
    _rc=$?
    unset _api_endpoint _api
    return "$_rc"
}

# Subscription readiness previously assumed 127.0.0.1:9090. Match the
# configured controller port and the expected process instead, which also
# works for IPv6 loopback and wildcard controller binds.
magicnet_singbox_listener_owned() {
    _listener_pid="$1"
    _listener_port="$(magicnet_singbox_api_port)" || return 1
    ss -lntp 2>/dev/null |
        grep -E ":${_listener_port}[[:space:]]" |
        grep -Fq "pid=${_listener_pid},"
    _listener_rc=$?
    unset _listener_pid _listener_port
    return "$_listener_rc"
}
