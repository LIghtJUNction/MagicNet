magicnet_singbox_dns_strategy_state() {
    printf '%s\n' "${MODDIR}/.config/magicnet/singbox-dns-strategy.before-ebpf"
}

magicnet_singbox_current_dns_strategy() {
    _mscds_config="$1"
    [ -f "$_mscds_config" ] || {
        unset _mscds_config
        return 1
    }
    if command -v jq >/dev/null 2>&1; then
        jq -r '.dns.strategy // empty' "$_mscds_config" 2>/dev/null
    else
        awk '
            /"dns"[[:space:]]*:[[:space:]]*\{/ { in_dns = 1 }
            in_dns && /"strategy"[[:space:]]*:/ {
                value = $0
                sub("^.*\"strategy\"[[:space:]]*:[[:space:]]*\"", "", value)
                sub("\".*$", "", value)
                print value
                exit
            }
            in_dns && /^[[:space:]]*}[,]?[[:space:]]*$/ { in_dns = 0 }
        ' "$_mscds_config" 2>/dev/null
    fi
    unset _mscds_config
}

magicnet_singbox_valid_dns_strategy() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

magicnet_ip_family_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/ip-family.conf"
}

magicnet_ip_family_mode() {
    _mif_conf="$(magicnet_ip_family_conf)"
    if [ -f "$_mif_conf" ]; then
        . "$_mif_conf"
    fi
    case "${MAGICNET_IP_FAMILY:-auto}" in
        ipv4|ipv4_only) printf '%s\n' "ipv4" ;;
        dual|dualstack|prefer_ipv4) printf '%s\n' "dual" ;;
        ipv6|prefer_ipv6) printf '%s\n' "ipv6" ;;
        *) printf '%s\n' "auto" ;;
    esac
    unset _mif_conf
}

magicnet_singbox_mixed_port_for_config() {
    _msmp_config="$1"
    _msmp_jq="${MODDIR}/bin/jq"
    if [ ! -x "$_msmp_jq" ]; then
        _msmp_jq="$(command -v jq 2>/dev/null || true)"
    fi
    if [ -n "$_msmp_jq" ]; then
        _msmp_port="$(
            "$_msmp_jq" -r '
              (.inbounds // [])
              | map(select((.tag // "") == "mixed-in"))
              | .[0].listen_port // empty
            ' "$_msmp_config" 2>/dev/null
        )"
    fi
    case "${_msmp_port:-}" in
        *[!0-9]*|"") printf '%s\n' "${MAGICNET_MIXED_PORT:-7892}" ;;
        *) printf '%s\n' "$_msmp_port" ;;
    esac
    unset _msmp_config _msmp_jq _msmp_port
}

magicnet_singbox_proxy_ipv6_works() {
    _mspiw_port="$(magicnet_singbox_mixed_port_for_config "$1")"
    command -v curl >/dev/null 2>&1 || {
        unset _mspiw_port
        return 1
    }
    curl -6 -k -fsS --max-time "${MAGICNET_IPV6_PROBE_TIMEOUT:-6}" \
        -x "http://127.0.0.1:${_mspiw_port}" \
        "${MAGICNET_IPV6_PROBE_URL:-https://[2606:4700:4700::1111]/}" >/dev/null 2>&1
    _mspiw_rc=$?
    unset _mspiw_port
    return "$_mspiw_rc"
}

magicnet_singbox_dns_strategy_for_ip_family() {
    _msdsfif_config="$1"
    case "$(magicnet_ip_family_mode)" in
        ipv4)
            printf '%s\n' "ipv4_only"
            ;;
        dual)
            printf '%s\n' "prefer_ipv4"
            ;;
        ipv6)
            printf '%s\n' "prefer_ipv6"
            ;;
        *)
            if magicnet_singbox_proxy_ipv6_works "$_msdsfif_config"; then
                printf '%s\n' "prefer_ipv4"
            else
                printf '%s\n' "ipv4_only"
            fi
            ;;
    esac
    unset _msdsfif_config
}

magicnet_singbox_dns_strategy_for_mode() {
    _msdsfm_config="$1"
    _msdsfm_mode="$2"
    _msdsfm_state="$(magicnet_singbox_dns_strategy_state)"

    if [ -f "$_msdsfm_state" ]; then
        _msdsfm_saved="$(sed -n '1p' "$_msdsfm_state" 2>/dev/null)"
        rm -f "$_msdsfm_state" 2>/dev/null || true
        if magicnet_singbox_valid_dns_strategy "$_msdsfm_saved"; then
            printf '%s\n' "$_msdsfm_saved"
            unset _msdsfm_config _msdsfm_mode _msdsfm_state _msdsfm_current _msdsfm_saved
            return 0
        fi
    fi

    if [ "$_msdsfm_mode" = "tun" ]; then
        printf '%s\n' "ipv4_only"
        unset _msdsfm_config _msdsfm_mode _msdsfm_state _msdsfm_current _msdsfm_saved
        return 0
    fi

    magicnet_singbox_dns_strategy_for_ip_family "$_msdsfm_config"
    unset _msdsfm_config _msdsfm_mode _msdsfm_state _msdsfm_current _msdsfm_saved
}
