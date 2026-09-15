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

magicnet_singbox_api_listener_exists() {
    _listener_port="$(magicnet_singbox_api_port)" || return 1
    ss -lnt 2>/dev/null | grep -E -q ":${_listener_port}[[:space:]]"
    _listener_rc=$?
    unset _listener_port
    return "$_listener_rc"
}

# Subscription readiness used to assume one fixed controller address. Match
# the configured controller port and the expected process instead, which also
# works for IPv6 loopback and wildcard controller binds.
magicnet_singbox_listener_owned() {
    _listener_pid="${1:-}"
    case "$_listener_pid" in
    '' | *[!0-9]*)
        unset _listener_pid
        return 1
        ;;
    esac
    _listener_port="$(magicnet_singbox_api_port)" || {
        unset _listener_pid
        return 1
    }
    ss -lntp 2>/dev/null |
        grep -E ":${_listener_port}[[:space:]]" |
        grep -Fq "pid=${_listener_pid},"
    _listener_rc=$?
    unset _listener_pid _listener_port
    return "$_listener_rc"
}
