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
    _mtpi_cmd="$1"
    shift
    if "$_mtpi_cmd" -w 1 -L >/dev/null 2>&1; then
        "$_mtpi_cmd" -w 100 "$@"
    else
        "$_mtpi_cmd" "$@"
    fi
    _mtpi_rc=$?
    unset _mtpi_cmd
    return "$_mtpi_rc"
}

magicnet_tproxy_ensure_jump() {
    _mtpj_cmd="$1"
    _mtpj_table="$2"
    _mtpj_chain="$3"
    _mtpj_jump="$4"

    magicnet_tproxy_iptables "$_mtpj_cmd" -t "$_mtpj_table" -C "$_mtpj_chain" -j "$_mtpj_jump" >/dev/null 2>&1 ||
        magicnet_tproxy_iptables "$_mtpj_cmd" -t "$_mtpj_table" -I "$_mtpj_chain" -j "$_mtpj_jump" >/dev/null 2>&1
    _mtpj_rc=$?
    unset _mtpj_cmd _mtpj_table _mtpj_chain _mtpj_jump
    return "$_mtpj_rc"
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
    _mtpo_cmd="$1"
    _mtpo_chain="$2"
    _mtpo_uid="${MAGICNET_TPROXY_EXEMPT_UID:-0}"

    magicnet_tproxy_iptables "$_mtpo_cmd" -t mangle -A "$_mtpo_chain" -m owner --uid-owner "$_mtpo_uid" -j RETURN 2>/dev/null || true
    magicnet_tproxy_iptables "$_mtpo_cmd" -t mangle -A "$_mtpo_chain" -m owner --uid-owner 1052 -j RETURN 2>/dev/null || true
    magicnet_tproxy_iptables "$_mtpo_cmd" -t mangle -A "$_mtpo_chain" -m owner --gid-owner 3005 -j RETURN 2>/dev/null || true
    unset _mtpo_cmd _mtpo_chain _mtpo_uid
}

magicnet_tproxy_apply_app_policy() {
    _mtpap_cmd="$1"
    _mtpap_chain="$2"
    _mtpap_mark="$3"
    _mtpap_dir="$(magicnet_app_policy_dir)"
    _mtpap_mode="$(magicnet_app_policy_mode)"

    case "$_mtpap_mode" in
        whitelist)
            _mtpap_uids=$(magicnet_tproxy_app_uid_list "${_mtpap_dir}/app-proxy.list")
            if [ -n "$_mtpap_uids" ]; then
                printf '%s\n' "$_mtpap_uids" | while read -r _mtpap_uid; do
                    [ -n "$_mtpap_uid" ] || continue
                    magicnet_tproxy_iptables "$_mtpap_cmd" -t mangle -A "$_mtpap_chain" -p tcp -m owner --uid-owner "$_mtpap_uid" -j MARK --set-xmark "$_mtpap_mark" 2>/dev/null || true
                    magicnet_tproxy_iptables "$_mtpap_cmd" -t mangle -A "$_mtpap_chain" -p udp -m owner --uid-owner "$_mtpap_uid" -j MARK --set-xmark "$_mtpap_mark" 2>/dev/null || true
                done
            else
                magicnet_tproxy_iptables "$_mtpap_cmd" -t mangle -A "$_mtpap_chain" -p tcp -j MARK --set-xmark "$_mtpap_mark" 2>/dev/null || return 1
                magicnet_tproxy_iptables "$_mtpap_cmd" -t mangle -A "$_mtpap_chain" -p udp -j MARK --set-xmark "$_mtpap_mark" 2>/dev/null || return 1
            fi
            ;;
        *)
            _mtpap_uids=$(magicnet_tproxy_app_uid_list "${_mtpap_dir}/app-bypass.list")
            if [ -n "$_mtpap_uids" ]; then
                printf '%s\n' "$_mtpap_uids" | while read -r _mtpap_uid; do
                    [ -n "$_mtpap_uid" ] || continue
                    magicnet_tproxy_iptables "$_mtpap_cmd" -t mangle -A "$_mtpap_chain" -m owner --uid-owner "$_mtpap_uid" -j RETURN 2>/dev/null || true
                done
            fi
            magicnet_tproxy_iptables "$_mtpap_cmd" -t mangle -A "$_mtpap_chain" -p tcp -j MARK --set-xmark "$_mtpap_mark" 2>/dev/null || return 1
            magicnet_tproxy_iptables "$_mtpap_cmd" -t mangle -A "$_mtpap_chain" -p udp -j MARK --set-xmark "$_mtpap_mark" 2>/dev/null || return 1
            ;;
    esac
    unset _mtpap_cmd _mtpap_chain _mtpap_mark _mtpap_dir _mtpap_mode _mtpap_uids _mtpap_uid
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
    _mtpaf_cmd="$1"
    _mtpaf_ip_args="$2"
    _mtpaf_port="$(magicnet_tproxy_port)"
    _mtpaf_mark="$(magicnet_tproxy_mark)"
    _mtpaf_table="$(magicnet_tproxy_table)"
    _mtpaf_pref="$(magicnet_tproxy_pref)"

    magicnet_cmd_exists "$_mtpaf_cmd" || return 0
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -N MAGICNET_TPROXY 2>/dev/null || true
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -F MAGICNET_TPROXY 2>/dev/null || true
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -N MAGICNET_TPROXY_OUTPUT 2>/dev/null || true
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -F MAGICNET_TPROXY_OUTPUT 2>/dev/null || true
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -N MAGICNET_TPROXY_DIVERT 2>/dev/null || true
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -F MAGICNET_TPROXY_DIVERT 2>/dev/null || true

    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY_DIVERT -j MARK --set-xmark "$_mtpaf_mark" 2>/dev/null || true
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY_DIVERT -j ACCEPT 2>/dev/null || true

    magicnet_tproxy_owner_return "$_mtpaf_cmd" MAGICNET_TPROXY_OUTPUT
    if [ "$_mtpaf_cmd" = "ip6tables" ]; then
        magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -d ::1/128 -j RETURN 2>/dev/null || true
    else
        magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -d 127.0.0.0/8 -j RETURN 2>/dev/null || true
    fi

    if [ "$_mtpaf_cmd" = "ip6tables" ]; then
        magicnet_tproxy_private_cidrs6
    else
        magicnet_tproxy_private_cidrs4
    fi | while read -r _mtpaf_cidr; do
        [ -n "$_mtpaf_cidr" ] || continue
        magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY -d "$_mtpaf_cidr" -j RETURN 2>/dev/null || true
        magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -d "$_mtpaf_cidr" -j RETURN 2>/dev/null || true
    done

    magicnet_tproxy_collect_outbound_bypass_ifaces | while read -r _mtpaf_iface; do
        [ -n "$_mtpaf_iface" ] || continue
        magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -o "$_mtpaf_iface" -j RETURN 2>/dev/null || true
    done

    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY -p tcp --dport 53 -j TPROXY \
        --on-port "$_mtpaf_port" --tproxy-mark "$_mtpaf_mark/$_mtpaf_mark" 2>/dev/null || return 1
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY -p udp --dport 53 -j TPROXY \
        --on-port "$_mtpaf_port" --tproxy-mark "$_mtpaf_mark/$_mtpaf_mark" 2>/dev/null || return 1
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -p tcp --dport 53 -j MARK --set-xmark "$_mtpaf_mark" 2>/dev/null || return 1
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY_OUTPUT -p udp --dport 53 -j MARK --set-xmark "$_mtpaf_mark" 2>/dev/null || return 1

    if [ "$_mtpaf_cmd" = "iptables" ]; then
        _mtpaf_hotspot_ifaces=$(magicnet_collect_hotspot_ifaces)
        for _mtpaf_hotspot in $_mtpaf_hotspot_ifaces; do
            magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY -p tcp -i "$_mtpaf_hotspot" -j TPROXY \
                --on-port "$_mtpaf_port" --tproxy-mark "$_mtpaf_mark/$_mtpaf_mark" 2>/dev/null || true
            magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -A MAGICNET_TPROXY -p udp -i "$_mtpaf_hotspot" -j TPROXY \
                --on-port "$_mtpaf_port" --tproxy-mark "$_mtpaf_mark/$_mtpaf_mark" 2>/dev/null || true
        done
    fi

    magicnet_tproxy_apply_app_policy "$_mtpaf_cmd" MAGICNET_TPROXY_OUTPUT "$_mtpaf_mark" || return 1
    magicnet_tproxy_ensure_jump "$_mtpaf_cmd" mangle PREROUTING MAGICNET_TPROXY || return 1
    magicnet_tproxy_ensure_jump "$_mtpaf_cmd" mangle OUTPUT MAGICNET_TPROXY_OUTPUT || return 1
    magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -C PREROUTING -p tcp -m socket -j MAGICNET_TPROXY_DIVERT >/dev/null 2>&1 ||
        magicnet_tproxy_iptables "$_mtpaf_cmd" -t mangle -I PREROUTING -p tcp -m socket -j MAGICNET_TPROXY_DIVERT >/dev/null 2>&1 || true

    if magicnet_tproxy_disable_quic; then
        magicnet_tproxy_iptables "$_mtpaf_cmd" -A OUTPUT -p udp --dport 443 -j REJECT 2>/dev/null || true
        magicnet_tproxy_iptables "$_mtpaf_cmd" -A OUTPUT -p udp --dport 80 -j REJECT 2>/dev/null || true
    fi

    # shellcheck disable=SC2086
    ip $_mtpaf_ip_args rule show 2>/dev/null | grep -F "$_mtpaf_pref:" | grep -F "fwmark" | grep -F "$_mtpaf_table" >/dev/null 2>&1 ||
        ip $_mtpaf_ip_args rule add fwmark "$_mtpaf_mark" table "$_mtpaf_table" pref "$_mtpaf_pref" >/dev/null 2>&1 || return 1
    # shellcheck disable=SC2086
    ip $_mtpaf_ip_args route show table "$_mtpaf_table" 2>/dev/null | grep -F "local default dev lo" >/dev/null 2>&1 ||
        ip $_mtpaf_ip_args route add local default dev lo table "$_mtpaf_table" >/dev/null 2>&1 || return 1

    unset _mtpaf_cmd _mtpaf_ip_args _mtpaf_port _mtpaf_mark _mtpaf_table _mtpaf_pref _mtpaf_cidr _mtpaf_iface _mtpaf_hotspot _mtpaf_hotspot_ifaces
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
    if ! magicnet_tproxy_apply_family iptables ""; then
        magicnet_warn "failed to apply IPv4 TProxy iptables/ip rules; keep TUN mode on this device"
        magicnet_tproxy_cleanup
        return 1
    fi
    magicnet_tproxy_apply_family ip6tables "-6" || magicnet_warn "failed to apply IPv6 TProxy rules; IPv4 TProxy remains active"
    magicnet_log "TProxy rules applied on port $(magicnet_tproxy_port) mark $(magicnet_tproxy_mark) table $(magicnet_tproxy_table)"
}
