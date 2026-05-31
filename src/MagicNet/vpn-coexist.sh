#!/system/bin/sh
# shellcheck shell=ash

# Optional coexistence helper for root TUN/VPN stacks.
# It keeps other VPN overlay interface routes in the main table so MagicNet does
# not accidentally steal their control/data traffic.

magicnet_vpn_log() {
    if command -v info >/dev/null 2>&1; then
        info "$1"
    elif command -v print >/dev/null 2>&1; then
        print "MagicNet: $1"
    fi
}

magicnet_vpn_warn() {
    if command -v warn >/dev/null 2>&1; then
        warn "$1"
    elif command -v print >/dev/null 2>&1; then
        print "MagicNet: $1"
    fi
}

magicnet_vpn_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

magicnet_vpn_iface_exists() {
    [ -n "$1" ] && [ -d "/sys/class/net/$1" ]
}

magicnet_vpn_collect_magic_ifaces() {
    _magicnet_vpn_magic_ifaces="${MAGIC_TUN_IFACES:-}"

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
        [ -n "$_mihomo_tun" ] && _magicnet_vpn_magic_ifaces="$_magicnet_vpn_magic_ifaces $_mihomo_tun"
    fi

    if [ -f "${MODDIR}/.config/sing-box/config.json" ]; then
        _singbox_tun=$(sed -n 's/.*"interface_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${MODDIR}/.config/sing-box/config.json" | head -n 1)
        [ -n "$_singbox_tun" ] && _magicnet_vpn_magic_ifaces="$_magicnet_vpn_magic_ifaces $_singbox_tun"
    fi

    _magicnet_vpn_magic_ifaces="$_magicnet_vpn_magic_ifaces Meta mihoyo utun tun0"
    for _iface in $_magicnet_vpn_magic_ifaces; do
        magicnet_vpn_iface_exists "$_iface" && printf '%s\n' "$_iface"
    done | awk '!seen[$0]++'
}

magicnet_vpn_is_magic_iface() {
    _candidate="$1"
    for _magic_iface in $_magicnet_vpn_magic_ifaces; do
        [ "$_candidate" = "$_magic_iface" ] && return 0
    done
    return 1
}

magicnet_vpn_collect_external_ifaces() {
    if [ -n "${MAGIC_VPN_COEXIST_IFACES:-}" ]; then
        for _iface in $MAGIC_VPN_COEXIST_IFACES; do
            magicnet_vpn_iface_exists "$_iface" && printf '%s\n' "$_iface"
        done | awk '!seen[$0]++'
        return 0
    fi

    for _path in /sys/class/net/*; do
        [ -d "$_path" ] || continue
        _iface=${_path##*/}
        magicnet_vpn_is_magic_iface "$_iface" && continue
        case "$_iface" in
            tun[0-9]*|wg[0-9]*|tailscale[0-9]*|zt[0-9]*|zerotier[0-9]*|warp[0-9]*)
                printf '%s\n' "$_iface"
                ;;
        esac
    done | awk '!seen[$0]++'
}

magicnet_vpn_rule_exists() {
    ip rule show 2>/dev/null | grep -F "$1" | grep -F "$2" >/dev/null 2>&1
}

magicnet_vpn_add_rule() {
    _priority="$1"
    shift
    _needle="$*"
    magicnet_vpn_rule_exists "$_priority:" "$_needle" || ip rule add priority "$_priority" "$@" >/dev/null 2>&1 || true
}

magicnet_enable_vpn_coexist() {
    [ "${MAGIC_VPN_COEXIST:-0}" = "1" ] || return 0

    if ! magicnet_vpn_cmd_exists ip; then
        magicnet_vpn_warn "ip command not found; VPN coexistence rules skipped"
        return 0
    fi

    _magicnet_vpn_magic_ifaces=$(magicnet_vpn_collect_magic_ifaces)
    _magicnet_vpn_external_ifaces=$(magicnet_vpn_collect_external_ifaces)

    if [ -z "$_magicnet_vpn_external_ifaces" ]; then
        magicnet_vpn_log "VPN coexistence enabled; no external VPN interface found"
        return 0
    fi

    _priority4=${MAGIC_VPN_COEXIST_RULE_PRIORITY4:-10200}
    _priority6=${MAGIC_VPN_COEXIST_RULE_PRIORITY6:-10250}

    for _iface in $_magicnet_vpn_external_ifaces; do
        ip -o -4 addr show dev "$_iface" 2>/dev/null | while read -r _line; do
            _cidr=$(printf '%s\n' "$_line" | awk '{print $4}')
            [ -n "$_cidr" ] || continue
            magicnet_vpn_add_rule "$_priority4" from "$_cidr" lookup main
            magicnet_vpn_add_rule "$((_priority4 + 1))" to "$_cidr" lookup main
        done

        ip -o -6 addr show dev "$_iface" scope global 2>/dev/null | while read -r _line; do
            _cidr=$(printf '%s\n' "$_line" | awk '{print $4}')
            [ -n "$_cidr" ] || continue
            magicnet_vpn_add_rule "$_priority6" from "$_cidr" lookup main
            magicnet_vpn_add_rule "$((_priority6 + 1))" to "$_cidr" lookup main
        done
    done

    magicnet_vpn_log "VPN coexistence route rules applied for: $_magicnet_vpn_external_ifaces"
}
