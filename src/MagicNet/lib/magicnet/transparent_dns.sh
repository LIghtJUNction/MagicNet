# Network policy helpers (IPv6 preference, TUN MTU, UDP timeout).
# Kernel DNS capture / leak-guard live in network.sh, not here.
magicnet_network_policy_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/network-policy.conf"
}

magicnet_network_policy_value() {
    _network_policy_key="$1"
    _network_policy_conf="$(magicnet_network_policy_conf)"
    [ -f "$_network_policy_conf" ] || {
        unset _network_policy_key _network_policy_conf
        return 1
    }
    if awk -F= -v key="$_network_policy_key" '
        $1 == key {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value ~ /^[A-Za-z0-9_-]+$/) {
                print value
                found = 1
                exit
            }
        }
        END { exit found ? 0 : 1 }
    ' "$_network_policy_conf"; then
        unset _network_policy_key _network_policy_conf
        return 0
    fi
    unset _network_policy_key _network_policy_conf
    return 1
}

magicnet_ipv6_mode() {
    _ipv6_mode="${MAGICNET_IPV6_MODE:-}"
    [ -n "$_ipv6_mode" ] || _ipv6_mode="$(magicnet_network_policy_value MAGICNET_IPV6_MODE 2>/dev/null || true)"
    case "$_ipv6_mode" in
        ipv4_only|prefer_ipv4|prefer_ipv6) ;;
        ipv4-only|compat|disabled) _ipv6_mode="ipv4_only" ;;
        prefer-ipv6) _ipv6_mode="prefer_ipv6" ;;
        prefer-ipv4|auto|dual|"") _ipv6_mode="prefer_ipv4" ;;
        *) _ipv6_mode="prefer_ipv4" ;;
    esac
    printf '%s\n' "$_ipv6_mode"
    unset _ipv6_mode
}

magicnet_tun_mtu() {
    _tun_mtu="${MAGICNET_TUN_MTU:-}"
    [ -n "$_tun_mtu" ] || _tun_mtu="$(magicnet_network_policy_value MAGICNET_TUN_MTU 2>/dev/null || true)"
    case "$_tun_mtu" in
        ''|*[!0-9]*) _tun_mtu=1400 ;;
        *)
            if [ "$_tun_mtu" -lt 1280 ] || [ "$_tun_mtu" -gt 1500 ]; then
                _tun_mtu=1400
            fi
            ;;
    esac
    printf '%s\n' "$_tun_mtu"
    unset _tun_mtu
}

magicnet_udp_timeout() {
    _udp_timeout="${MAGICNET_UDP_TIMEOUT:-}"
    [ -n "$_udp_timeout" ] || _udp_timeout="$(magicnet_network_policy_value MAGICNET_UDP_TIMEOUT 2>/dev/null || true)"
    case "$_udp_timeout" in
        1m|3m|5m|10m|15m|30m) ;;
        *) _udp_timeout="5m" ;;
    esac
    printf '%s\n' "$_udp_timeout"
    unset _udp_timeout
}

magicnet_singbox_dns_strategy_for_mode() {
    magicnet_ipv6_mode
}
