magicnet_iface_exists() {
    [ -n "$1" ] && [ -d "/sys/class/net/$1" ]
}

magicnet_get_mihomo_tun() {
    [ -f "${MODDIR}/.config/mihomo/config.yaml" ] || return 0
    awk -F: '
        /^[[:space:]]*device[[:space:]]*:/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            gsub(/["'\'']/, "", $2)
            if ($2 != "") {
                print $2
                exit
            }
        }
    ' "${MODDIR}/.config/mihomo/config.yaml" 2>/dev/null
}

magicnet_get_singbox_tun() {
    [ -f "${MODDIR}/.config/sing-box/config.json" ] || return 0
    sed -n 's/.*"interface_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${MODDIR}/.config/sing-box/config.json" | head -n 1
}

magicnet_collect_tun_ifaces() {
    _magicnet_tun_ifaces="${MAGIC_TUN_IFACES:-}"
    _mihomo_tun=$(magicnet_get_mihomo_tun)
    _singbox_tun=$(magicnet_get_singbox_tun)

    [ -n "$_mihomo_tun" ] && _magicnet_tun_ifaces="$_magicnet_tun_ifaces $_mihomo_tun"
    [ -n "$_singbox_tun" ] && _magicnet_tun_ifaces="$_magicnet_tun_ifaces $_singbox_tun"

    _magicnet_tun_ifaces="$_magicnet_tun_ifaces Meta mihoyo utun magicnet0"
    for _iface in $_magicnet_tun_ifaces; do
        magicnet_iface_exists "$_iface" && printf '%s\n' "$_iface"
    done | awk '!seen[$0]++'
}

magicnet_iface_has_hotspot_addr() {
    magicnet_cmd_exists ip || return 1
    ip -o -4 addr show dev "$1" 2>/dev/null |
        grep -Eq 'inet (192\.168\.[0-9]+\.1|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.1|10\.[0-9]+\.[0-9]+\.1)/'
}

magicnet_iface_has_private_addr() {
    magicnet_cmd_exists ip || return 1
    ip -o -4 addr show dev "$1" 2>/dev/null |
        grep -Eq 'inet (10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)'
}

magicnet_iface_has_local_network_route() {
    magicnet_cmd_exists ip || return 1
    ip route show table local_network 2>/dev/null |
        grep -Eq "[[:space:]]dev[[:space:]]+$1([[:space:]]|$)"
}

magicnet_collect_hotspot_ifaces() {
    if [ -n "${MAGIC_HOTSPOT_IFACES:-}" ]; then
        for _iface in $MAGIC_HOTSPOT_IFACES; do
            printf '%s\n' "$_iface"
        done | awk '!seen[$0]++'
        return 0
    fi

    for _path in /sys/class/net/*; do
        [ -d "$_path" ] || continue
        _iface=${_path##*/}
        case "$_iface" in
            ap[0-9]*|swlan[0-9]*|softap[0-9]*|rndis[0-9]*|usb[0-9]*|bt-pan)
                printf '%s\n' "$_iface"
                ;;
            wlan[0-9]*|wifi[0-9]*)
                if magicnet_iface_has_hotspot_addr "$_iface" ||
                    { magicnet_iface_has_private_addr "$_iface" && magicnet_iface_has_local_network_route "$_iface"; }; then
                    printf '%s\n' "$_iface"
                fi
                ;;
        esac
    done | awk '!seen[$0]++'
}

magicnet_pick_forward_chain() {
    if iptables -nL tetherctrl_FORWARD >/dev/null 2>&1; then
        printf '%s\n' "tetherctrl_FORWARD"
    else
        printf '%s\n' "FORWARD"
    fi
}

magicnet_iptables_ensure() {
    _table=""
    if [ "$1" = "-t" ]; then
        _table="$2"
        shift 2
    fi

    if [ -n "$_table" ]; then
        iptables -t "$_table" -C "$@" >/dev/null 2>&1 || iptables -t "$_table" -A "$@" >/dev/null 2>&1
    else
        iptables -C "$@" >/dev/null 2>&1 || iptables -I "$@" >/dev/null 2>&1
    fi
}

magicnet_enable_hotspot_forward() {
    magicnet_hotspot_forward_enabled || return 0

    if ! magicnet_cmd_exists iptables; then
        magicnet_warn "iptables not found; hotspot forwarding fix skipped"
        return 0
    fi

    _forward_chain=$(magicnet_pick_forward_chain)
    _tun_ifaces=$(magicnet_collect_tun_ifaces)
    _hotspot_ifaces=$(magicnet_collect_hotspot_ifaces)

    if [ -z "$_tun_ifaces" ]; then
        magicnet_warn "No active TUN interface found; hotspot forwarding fix skipped"
        return 0
    fi
    if [ -z "$_hotspot_ifaces" ]; then
        magicnet_warn "No hotspot interface candidate found; hotspot forwarding fix skipped"
        return 0
    fi

    for _tun in $_tun_ifaces; do
        for _hotspot in $_hotspot_ifaces; do
            [ "$_tun" != "$_hotspot" ] || continue
            magicnet_iptables_ensure "$_forward_chain" -i "$_hotspot" -o "$_tun" -j ACCEPT || true
            magicnet_iptables_ensure "$_forward_chain" -i "$_tun" -o "$_hotspot" -m state --state RELATED,ESTABLISHED -j ACCEPT ||
                magicnet_iptables_ensure "$_forward_chain" -i "$_tun" -o "$_hotspot" -j ACCEPT || true
        done
        magicnet_iptables_ensure -t nat POSTROUTING -o "$_tun" -j MASQUERADE || true
    done

    magicnet_log "Hotspot forwarding rules applied via $_forward_chain"
}

magicnet_disable_hotspot_forward() {
    if ! magicnet_cmd_exists iptables; then
        return 0
    fi

    _forward_chain=$(magicnet_pick_forward_chain)
    _tun_ifaces=$(magicnet_collect_tun_ifaces)
    _hotspot_ifaces=$(magicnet_collect_hotspot_ifaces)

    for _tun in $_tun_ifaces; do
        for _hotspot in $_hotspot_ifaces; do
            [ "$_tun" != "$_hotspot" ] || continue
            iptables -D "$_forward_chain" -i "$_hotspot" -o "$_tun" -j ACCEPT 2>/dev/null || true
            iptables -D "$_forward_chain" -i "$_tun" -o "$_hotspot" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
            iptables -D "$_forward_chain" -i "$_tun" -o "$_hotspot" -j ACCEPT 2>/dev/null || true
        done
        iptables -t nat -D POSTROUTING -o "$_tun" -j MASQUERADE 2>/dev/null || true
    done

    magicnet_log "Hotspot forwarding rules disabled via $_forward_chain"
}

magicnet_is_magic_iface() {
    _candidate="$1"
    for _magic_iface in $_magicnet_magic_ifaces; do
        [ "$_candidate" = "$_magic_iface" ] && return 0
    done
    return 1
}

magicnet_collect_external_vpn_ifaces() {
    if [ -n "${MAGIC_VPN_COEXIST_IFACES:-}" ]; then
        for _iface in $MAGIC_VPN_COEXIST_IFACES; do
            magicnet_iface_exists "$_iface" && printf '%s\n' "$_iface"
        done | awk '!seen[$0]++'
        return 0
    fi

    for _path in /sys/class/net/*; do
        [ -d "$_path" ] || continue
        _iface=${_path##*/}
        magicnet_is_magic_iface "$_iface" && continue
        case "$_iface" in
            tun[0-9]*|wg[0-9]*|tailscale[0-9]*|zt[0-9]*|zerotier[0-9]*|warp[0-9]*)
                printf '%s\n' "$_iface"
                ;;
        esac
    done | awk '!seen[$0]++'
}

magicnet_ip_rule_exists() {
    ip rule show 2>/dev/null | grep -F "$1" | grep -F "$2" >/dev/null 2>&1
}

magicnet_ip_rule_ensure() {
    _priority="$1"
    shift
    _needle="$*"
    magicnet_ip_rule_exists "$_priority:" "$_needle" || ip rule add priority "$_priority" "$@" >/dev/null 2>&1 || true
}

magicnet_ip_rule_delete_priority() {
    _priority="$1"
    while ip rule show 2>/dev/null | grep -q "^$_priority:"; do
        ip rule del priority "$_priority" >/dev/null 2>&1 || break
    done
}

magicnet_enable_vpn_coexist() {
    magicnet_vpn_coexist_enabled || return 0

    if ! magicnet_cmd_exists ip; then
        magicnet_warn "ip command not found; VPN coexistence rules skipped"
        return 0
    fi

    _magicnet_magic_ifaces=$(magicnet_collect_tun_ifaces)
    _external_ifaces=$(magicnet_collect_external_vpn_ifaces)

    if [ -z "$_external_ifaces" ]; then
        magicnet_log "VPN coexistence enabled; no external VPN interface found"
        return 0
    fi

    _priority4=${MAGIC_VPN_COEXIST_RULE_PRIORITY4:-8900}
    _priority6=${MAGIC_VPN_COEXIST_RULE_PRIORITY6:-8950}

    for _iface in $_external_ifaces; do
        magicnet_ip_rule_ensure "$_priority4" iif "$_iface" lookup main
        magicnet_ip_rule_ensure "$_priority6" iif "$_iface" lookup main

        ip -o -4 addr show dev "$_iface" 2>/dev/null | while read -r _line; do
            _cidr=$(printf '%s\n' "$_line" | awk '{print $4}')
            [ -n "$_cidr" ] || continue
            magicnet_ip_rule_ensure "$_priority4" from "$_cidr" lookup main
            magicnet_ip_rule_ensure "$((_priority4 + 1))" to "$_cidr" lookup main
        done

        ip -o -6 addr show dev "$_iface" scope global 2>/dev/null | while read -r _line; do
            _cidr=$(printf '%s\n' "$_line" | awk '{print $4}')
            [ -n "$_cidr" ] || continue
            magicnet_ip_rule_ensure "$_priority6" from "$_cidr" lookup main
            magicnet_ip_rule_ensure "$((_priority6 + 1))" to "$_cidr" lookup main
        done
    done

    magicnet_log "VPN coexistence route rules applied for: $_external_ifaces"
}

magicnet_disable_vpn_coexist() {
    if ! magicnet_cmd_exists ip; then
        return 0
    fi

    _priority4=${MAGIC_VPN_COEXIST_RULE_PRIORITY4:-8900}
    _priority6=${MAGIC_VPN_COEXIST_RULE_PRIORITY6:-8950}
    magicnet_ip_rule_delete_priority "$_priority4"
    magicnet_ip_rule_delete_priority "$((_priority4 + 1))"
    magicnet_ip_rule_delete_priority "$_priority6"
    magicnet_ip_rule_delete_priority "$((_priority6 + 1))"
    magicnet_log "VPN coexistence route rules disabled"
}

magicnet_after_kernel_start() {
    magicnet_singbox_apply_zashboard
    magicnet_app_policy_apply
    magicnet_capture_apply
    magicnet_enable_hotspot_forward
    magicnet_enable_vpn_coexist
}
