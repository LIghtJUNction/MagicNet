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
