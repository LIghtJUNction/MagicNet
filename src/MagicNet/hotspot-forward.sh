#!/system/bin/sh
# shellcheck shell=ash

# Allow Android tethered clients to forward through the module TUN interface.
# This avoids flushing Android's whole FORWARD chain while preserving hotspot use.

magicnet_log() {
    if command -v info >/dev/null 2>&1; then
        info "$1"
    elif command -v print >/dev/null 2>&1; then
        print "MagicNet: $1"
    fi
}

magicnet_warn() {
    if command -v warn >/dev/null 2>&1; then
        warn "$1"
    elif command -v print >/dev/null 2>&1; then
        print "MagicNet: $1"
    fi
}

magicnet_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

magicnet_iface_exists() {
    [ -n "$1" ] && [ -d "/sys/class/net/$1" ]
}

magicnet_iface_has_hotspot_addr() {
    magicnet_cmd_exists ip || return 1
    ip -o -4 addr show dev "$1" 2>/dev/null | grep -Eq 'inet (192\.168\.[0-9]+\.1|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.1|10\.[0-9]+\.[0-9]+\.1)/'
}

magicnet_collect_tun_ifaces() {
    _magicnet_tun_ifaces=""

    if [ -n "${MAGIC_TUN_IFACES:-}" ]; then
        _magicnet_tun_ifaces="$MAGIC_TUN_IFACES"
    fi

    if [ -f "${MODDIR}/.config/mihomo/config.yaml" ]; then
        _mihomo_tun=$(awk -F: '
            /^[[:space:]]*device[[:space:]]*:/ {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                gsub(/["'\'']/, "", $2)
                if ($2 != "") {
                    print $2
                    exit
                }
            }
        ' "${MODDIR}/.config/mihomo/config.yaml" 2>/dev/null)
        [ -n "$_mihomo_tun" ] && _magicnet_tun_ifaces="$_magicnet_tun_ifaces $_mihomo_tun"
    fi

    if [ -f "${MODDIR}/.config/sing-box/config.json" ]; then
        _singbox_tun=$(sed -n 's/.*"interface_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${MODDIR}/.config/sing-box/config.json" | head -n 1)
        [ -n "$_singbox_tun" ] && _magicnet_tun_ifaces="$_magicnet_tun_ifaces $_singbox_tun"
    fi

    _magicnet_tun_ifaces="$_magicnet_tun_ifaces Meta mihoyo utun tun0"
    for _iface in $_magicnet_tun_ifaces; do
        if magicnet_iface_exists "$_iface"; then
            printf '%s\n' "$_iface"
        fi
    done | awk '!seen[$0]++'
}

magicnet_collect_hotspot_ifaces() {
    if [ -n "${MAGIC_HOTSPOT_IFACES:-}" ]; then
        for _iface in $MAGIC_HOTSPOT_IFACES; do
            printf '%s\n' "$_iface"
        done
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
                magicnet_iface_has_hotspot_addr "$_iface" && printf '%s\n' "$_iface"
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
    [ "${MAGIC_HOTSPOT_FORWARD:-1}" != "0" ] || return 0

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
            magicnet_iptables_ensure "$_forward_chain" -i "$_tun" -o "$_hotspot" -m state --state RELATED,ESTABLISHED -j ACCEPT || \
                magicnet_iptables_ensure "$_forward_chain" -i "$_tun" -o "$_hotspot" -j ACCEPT || true
        done
        magicnet_iptables_ensure -t nat POSTROUTING -o "$_tun" -j MASQUERADE || true
    done

    magicnet_log "Hotspot forwarding rules applied via $_forward_chain"
}
