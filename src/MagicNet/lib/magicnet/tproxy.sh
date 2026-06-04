# shellcheck shell=ash

magicnet_tproxy_mark() {
    printf '%s\n' "${MAGICNET_TPROXY_MARK:-0x1}"
}

magicnet_tproxy_table() {
    printf '%s\n' "${MAGICNET_TPROXY_TABLE:-100}"
}

magicnet_tproxy_port() {
    printf '%s\n' "${MAGICNET_TPROXY_PORT:-9898}"
}

magicnet_tproxy_pref() {
    printf '%s\n' "${MAGICNET_TPROXY_PREF:-100}"
}

magicnet_tproxy_disable_quic() {
    [ "${MAGICNET_TPROXY_DISABLE_QUIC:-0}" = "1" ]
}

magicnet_tproxy_has_kernel_support() {
    [ -d /sys/module/xt_TPROXY ] && return 0
    [ -r /proc/net/ip_tables_targets ] &&
        grep -qx TPROXY /proc/net/ip_tables_targets 2>/dev/null
}

magicnet_tproxy_iptables() {
    _cmd="$1"
    shift
    if "$_cmd" -w 1 -L >/dev/null 2>&1; then
        "$_cmd" -w 100 "$@"
    else
        "$_cmd" "$@"
    fi
    _rc=$?
    unset _cmd
    return "$_rc"
}

magicnet_tproxy_ensure_jump() {
    _cmd="$1"
    _table="$2"
    _chain="$3"
    _jump="$4"

    magicnet_tproxy_iptables "$_cmd" -t "$_table" -C "$_chain" -j "$_jump" >/dev/null 2>&1 ||
        magicnet_tproxy_iptables "$_cmd" -t "$_table" -I "$_chain" -j "$_jump" >/dev/null 2>&1
    _rc=$?
    unset _cmd _table _chain _jump
    return "$_rc"
}

magicnet_tproxy_private_cidrs4() {
    cat <<'EOF'
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.0.0.0/24
192.0.2.0/24
192.88.99.0/24
192.168.0.0/16
198.51.100.0/24
203.0.113.0/24
224.0.0.0/4
240.0.0.0/4
255.255.255.255/32
EOF
    ip -o -4 addr show 2>/dev/null |
        awk '$4 !~ /^127\./ { print $4 }'
}

magicnet_tproxy_private_cidrs6() {
    cat <<'EOF'
::/128
::1/128
::ffff:0:0/96
64:ff9b::/96
100::/64
2001::/32
2001:10::/28
2001:20::/28
2001:db8::/32
2002::/16
fc00::/7
fe80::/10
ff00::/8
EOF
    ip -o -6 addr show scope global 2>/dev/null |
        awk '$4 !~ /^(::1|fe80|fd00)/ { print $4 }'
}

magicnet_tproxy_collect_outbound_bypass_ifaces() {
    _ifaces="${MAGICNET_TPROXY_BYPASS_IFACES:-}"
    _ifaces="$_ifaces rmnet_data+ ccmni+ rndis+ ncm+ eth+"
    for _iface in $_ifaces; do
        printf '%s\n' "$_iface"
    done | awk '!seen[$0]++'
    unset _ifaces _iface
}

magicnet_tproxy_app_uid_list() {
    _list="$1"
    [ -s "$_list" ] || return 0
    [ -r /data/system/packages.list ] || return 0

    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_list" 2>/dev/null |
        while read -r _pkg; do
            case "$_pkg" in
                *:*)
                    _user="${_pkg%%:*}"
                    _pkg_name="${_pkg##*:}"
                    ;;
                *)
                    _user=0
                    _pkg_name="$_pkg"
                    ;;
            esac
            _appid=$(awk -v p="$_pkg_name" '$1 == p { print $2; exit }' /data/system/packages.list 2>/dev/null)
            case "$_user:$_appid" in
                *[!0-9:]*|:*|*:) continue ;;
                *) printf '%s\n' "$((_user * 100000 + _appid))" ;;
            esac
        done | awk '!seen[$0]++'
    unset _list _pkg _pkg_name _user _appid
}

magicnet_tproxy_owner_return() {
    _cmd="$1"
    _chain="$2"
    _uid="${MAGICNET_TPROXY_EXEMPT_UID:-0}"

    magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -m owner --uid-owner "$_uid" -j RETURN 2>/dev/null || true
    magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -m owner --uid-owner 1052 -j RETURN 2>/dev/null || true
    magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -m owner --gid-owner 3005 -j RETURN 2>/dev/null || true
    unset _cmd _chain _uid
}

magicnet_tproxy_apply_app_policy() {
    _cmd="$1"
    _chain="$2"
    _mark="$3"
    _dir="$(magicnet_app_policy_dir)"
    _mode="$(magicnet_app_policy_mode)"

    case "$_mode" in
        whitelist)
            _uids=$(magicnet_tproxy_app_uid_list "${_dir}/app-proxy.list")
            if [ -n "$_uids" ]; then
                printf '%s\n' "$_uids" | while read -r _uid; do
                    [ -n "$_uid" ] || continue
                    magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -p tcp -m owner --uid-owner "$_uid" -j MARK --set-xmark "$_mark" 2>/dev/null || true
                    magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -p udp -m owner --uid-owner "$_uid" -j MARK --set-xmark "$_mark" 2>/dev/null || true
                done
            else
                magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -p tcp -j MARK --set-xmark "$_mark" 2>/dev/null || return 1
                magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -p udp -j MARK --set-xmark "$_mark" 2>/dev/null || return 1
            fi
            ;;
        *)
            _uids=$(magicnet_tproxy_app_uid_list "${_dir}/app-bypass.list")
            if [ -n "$_uids" ]; then
                printf '%s\n' "$_uids" | while read -r _uid; do
                    [ -n "$_uid" ] || continue
                    magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -m owner --uid-owner "$_uid" -j RETURN 2>/dev/null || true
                done
            fi
            magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -p tcp -j MARK --set-xmark "$_mark" 2>/dev/null || return 1
            magicnet_tproxy_iptables "$_cmd" -t mangle -A "$_chain" -p udp -j MARK --set-xmark "$_mark" 2>/dev/null || return 1
            ;;
    esac
    unset _cmd _chain _mark _dir _mode _uids _uid
}

magicnet_tproxy_cleanup_family() {
    _cmd="$1"
    _ip_args="$2"
    _mark="$(magicnet_tproxy_mark)"
    _table="$(magicnet_tproxy_table)"
    _pref="$(magicnet_tproxy_pref)"

    if magicnet_cmd_exists "$_cmd"; then
        magicnet_tproxy_iptables "$_cmd" -t mangle -D PREROUTING -p tcp -m socket -j MAGICNET_TPROXY_DIVERT 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -D PREROUTING -j MAGICNET_TPROXY 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -D OUTPUT -j MAGICNET_TPROXY_OUTPUT 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -F MAGICNET_TPROXY 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -X MAGICNET_TPROXY 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -F MAGICNET_TPROXY_OUTPUT 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -X MAGICNET_TPROXY_OUTPUT 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -F MAGICNET_TPROXY_DIVERT 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -X MAGICNET_TPROXY_DIVERT 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -D OUTPUT -p udp --dport 443 -j REJECT 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -D OUTPUT -p udp --dport 80 -j REJECT 2>/dev/null || true
    fi
    if magicnet_cmd_exists ip; then
        # shellcheck disable=SC2086
        ip $_ip_args rule del fwmark "$_mark" table "$_table" pref "$_pref" 2>/dev/null || true
        # shellcheck disable=SC2086
        ip $_ip_args rule del pref "$_pref" 2>/dev/null || true
        # shellcheck disable=SC2086
        ip $_ip_args rule del fwmark "$_mark" table "$_table" 2>/dev/null || true
        # shellcheck disable=SC2086
        ip $_ip_args route del local default dev lo table "$_table" 2>/dev/null || true
        # shellcheck disable=SC2086
        ip $_ip_args route flush table "$_table" 2>/dev/null || true
    fi
    unset _cmd _ip_args _mark _table _pref
}

magicnet_tproxy_cleanup_legacy_dns_nat_family() {
    _cmd="$1"

    magicnet_cmd_exists "$_cmd" || {
        unset _cmd
        return 0
    }

    "$_cmd" -t nat -D PREROUTING -j MAGICNET_DNS_REDIRECT 2>/dev/null || true
    "$_cmd" -t nat -D OUTPUT -j MAGICNET_DNS_REDIRECT 2>/dev/null || true
    "$_cmd" -t nat -D OUTPUT -j MAGICNET_DNS_OUTPUT 2>/dev/null || true
    "$_cmd" -t nat -F MAGICNET_DNS_REDIRECT 2>/dev/null || true
    "$_cmd" -t nat -X MAGICNET_DNS_REDIRECT 2>/dev/null || true
    "$_cmd" -t nat -F MAGICNET_DNS_OUTPUT 2>/dev/null || true
    "$_cmd" -t nat -X MAGICNET_DNS_OUTPUT 2>/dev/null || true

    unset _cmd
}

magicnet_tproxy_cleanup_legacy_dns_nat() {
    magicnet_tproxy_cleanup_legacy_dns_nat_family iptables
    magicnet_tproxy_cleanup_legacy_dns_nat_family ip6tables
}

magicnet_tproxy_cleanup() {
    magicnet_tproxy_cleanup_legacy_dns_nat
    magicnet_tproxy_cleanup_family iptables ""
    magicnet_tproxy_cleanup_family ip6tables "-6"
}

magicnet_tproxy_apply_family() {
    _cmd="$1"
    _ip_args="$2"
    _port="$(magicnet_tproxy_port)"
    _mark="$(magicnet_tproxy_mark)"
    _table="$(magicnet_tproxy_table)"
    _pref="$(magicnet_tproxy_pref)"

    magicnet_cmd_exists "$_cmd" || return 0
    magicnet_tproxy_iptables "$_cmd" -t mangle -N MAGICNET_TPROXY 2>/dev/null || true
    magicnet_tproxy_iptables "$_cmd" -t mangle -F MAGICNET_TPROXY 2>/dev/null || true
    magicnet_tproxy_iptables "$_cmd" -t mangle -N MAGICNET_TPROXY_OUTPUT 2>/dev/null || true
    magicnet_tproxy_iptables "$_cmd" -t mangle -F MAGICNET_TPROXY_OUTPUT 2>/dev/null || true
    magicnet_tproxy_iptables "$_cmd" -t mangle -N MAGICNET_TPROXY_DIVERT 2>/dev/null || true
    magicnet_tproxy_iptables "$_cmd" -t mangle -F MAGICNET_TPROXY_DIVERT 2>/dev/null || true

    magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY_DIVERT -j MARK --set-xmark "$_mark" 2>/dev/null || true
    magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY_DIVERT -j ACCEPT 2>/dev/null || true

    magicnet_tproxy_owner_return "$_cmd" MAGICNET_TPROXY_OUTPUT
    if [ "$_cmd" = "ip6tables" ]; then
        magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -d ::1/128 -j RETURN 2>/dev/null || true
    else
        magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -d 127.0.0.0/8 -j RETURN 2>/dev/null || true
    fi

    if [ "$_cmd" = "ip6tables" ]; then
        magicnet_tproxy_private_cidrs6
    else
        magicnet_tproxy_private_cidrs4
    fi | while read -r _cidr; do
        [ -n "$_cidr" ] || continue
        magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY -d "$_cidr" -j RETURN 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -d "$_cidr" -j RETURN 2>/dev/null || true
    done

    magicnet_tproxy_collect_outbound_bypass_ifaces | while read -r _iface; do
        [ -n "$_iface" ] || continue
        magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -o "$_iface" -j RETURN 2>/dev/null || true
    done

    magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY -p tcp --dport 53 -j TPROXY \
        --on-port "$_port" --tproxy-mark "$_mark/$_mark" 2>/dev/null || return 1
    magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY -p udp --dport 53 -j TPROXY \
        --on-port "$_port" --tproxy-mark "$_mark/$_mark" 2>/dev/null || return 1
    magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -p tcp --dport 53 -j MARK --set-xmark "$_mark" 2>/dev/null || return 1
    magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -p udp --dport 53 -j MARK --set-xmark "$_mark" 2>/dev/null || return 1

    if [ "$_cmd" = "iptables" ]; then
        _hotspot_ifaces=$(magicnet_collect_hotspot_ifaces)
        for _hotspot in $_hotspot_ifaces; do
            magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY -p tcp -i "$_hotspot" -j TPROXY \
                --on-port "$_port" --tproxy-mark "$_mark/$_mark" 2>/dev/null || true
            magicnet_tproxy_iptables "$_cmd" -t mangle -A MAGICNET_TPROXY -p udp -i "$_hotspot" -j TPROXY \
                --on-port "$_port" --tproxy-mark "$_mark/$_mark" 2>/dev/null || true
        done
    fi

    magicnet_tproxy_apply_app_policy "$_cmd" MAGICNET_TPROXY_OUTPUT "$_mark" || return 1
    magicnet_tproxy_ensure_jump "$_cmd" mangle PREROUTING MAGICNET_TPROXY || return 1
    magicnet_tproxy_ensure_jump "$_cmd" mangle OUTPUT MAGICNET_TPROXY_OUTPUT || return 1
    magicnet_tproxy_iptables "$_cmd" -t mangle -C PREROUTING -p tcp -m socket -j MAGICNET_TPROXY_DIVERT >/dev/null 2>&1 ||
        magicnet_tproxy_iptables "$_cmd" -t mangle -I PREROUTING -p tcp -m socket -j MAGICNET_TPROXY_DIVERT >/dev/null 2>&1 || true

    if magicnet_tproxy_disable_quic; then
        magicnet_tproxy_iptables "$_cmd" -A OUTPUT -p udp --dport 443 -j REJECT 2>/dev/null || true
        magicnet_tproxy_iptables "$_cmd" -A OUTPUT -p udp --dport 80 -j REJECT 2>/dev/null || true
    fi

    # shellcheck disable=SC2086
    ip $_ip_args rule show 2>/dev/null | grep -F "$_pref:" | grep -F "fwmark" | grep -F "$_table" >/dev/null 2>&1 ||
        ip $_ip_args rule add fwmark "$_mark" table "$_table" pref "$_pref" >/dev/null 2>&1 || return 1
    # shellcheck disable=SC2086
    ip $_ip_args route show table "$_table" 2>/dev/null | grep -F "local default dev lo" >/dev/null 2>&1 ||
        ip $_ip_args route add local default dev lo table "$_table" >/dev/null 2>&1 || return 1

    unset _cmd _ip_args _port _mark _table _pref _cidr _iface _hotspot _hotspot_ifaces
}

magicnet_enable_tproxy() {
    [ "$(magicnet_transparent_mode)" = "tproxy" ] || {
        magicnet_tproxy_cleanup
        return 0
    }

    if ! magicnet_cmd_exists ip || ! magicnet_cmd_exists iptables; then
        magicnet_warn "ip/iptables not found; TProxy routing skipped"
        return 0
    fi
    if ! magicnet_tproxy_has_kernel_support; then
        magicnet_warn "kernel TPROXY target is unavailable; keep TUN mode on this device"
        return 1
    fi

    magicnet_tproxy_cleanup_legacy_dns_nat
    magicnet_tproxy_apply_family iptables "" || return 1
    magicnet_tproxy_apply_family ip6tables "-6" || true
    magicnet_log "TProxy rules applied on port $(magicnet_tproxy_port) mark $(magicnet_tproxy_mark) table $(magicnet_tproxy_table)"
}
