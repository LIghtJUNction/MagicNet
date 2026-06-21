# shellcheck shell=ash

magicnet_tproxy_udp_cleanup_family() {
    _mtu_cmd="$1"
    _mtu_ip_args="$2"
    _mtu_chain="$3"
    _mtu_out_chain="${_mtu_chain}_OUTPUT"
    _mtu_mark="${MAGICNET_TPROXY_UDP_MARK:-0x2333}"
    _mtu_table="${MAGICNET_TPROXY_UDP_TABLE:-233}"
    _mtu_pref="${MAGICNET_TPROXY_UDP_PREF:-12333}"

    if magicnet_cmd_exists "$_mtu_cmd"; then
        "$_mtu_cmd" -w 1 -t mangle -D PREROUTING -j "$_mtu_chain" 2>/dev/null || true
        "$_mtu_cmd" -w 1 -t mangle -D OUTPUT -j "$_mtu_out_chain" 2>/dev/null || true
        "$_mtu_cmd" -w 1 -t mangle -F "$_mtu_chain" 2>/dev/null || true
        "$_mtu_cmd" -w 1 -t mangle -X "$_mtu_chain" 2>/dev/null || true
        "$_mtu_cmd" -w 1 -t mangle -F "$_mtu_out_chain" 2>/dev/null || true
        "$_mtu_cmd" -w 1 -t mangle -X "$_mtu_out_chain" 2>/dev/null || true
    fi
    if magicnet_cmd_exists ip; then
        # shellcheck disable=SC2086
        ip $_mtu_ip_args rule del fwmark "$_mtu_mark" table "$_mtu_table" pref "$_mtu_pref" 2>/dev/null || true
        # shellcheck disable=SC2086
        ip $_mtu_ip_args rule del pref "$_mtu_pref" 2>/dev/null || true
        # shellcheck disable=SC2086
        ip $_mtu_ip_args route flush table "$_mtu_table" 2>/dev/null || true
    fi
    unset _mtu_cmd _mtu_ip_args _mtu_chain _mtu_out_chain _mtu_mark _mtu_table _mtu_pref
}

magicnet_tproxy_udp_cleanup() {
    magicnet_tproxy_udp_cleanup_family iptables "" MAGICNET_UDP_TPROXY
    magicnet_tproxy_udp_cleanup_family ip6tables "-6" MAGICNET_UDP_TPROXY6
}
