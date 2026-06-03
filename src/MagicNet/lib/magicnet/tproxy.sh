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

magicnet_tproxy_has_kernel_support() {
    [ -d /sys/module/xt_TPROXY ] && return 0
    [ -r /proc/net/ip_tables_targets ] &&
        grep -qx TPROXY /proc/net/ip_tables_targets 2>/dev/null
}

magicnet_tproxy_cleanup_family() {
    _cmd="$1"
    _ip_args="$2"
    _mark="$(magicnet_tproxy_mark)"
    _table="$(magicnet_tproxy_table)"

    if magicnet_cmd_exists "$_cmd"; then
        "$_cmd" -t mangle -D PREROUTING -j MAGICNET_TPROXY 2>/dev/null || true
        "$_cmd" -t mangle -F MAGICNET_TPROXY 2>/dev/null || true
        "$_cmd" -t mangle -X MAGICNET_TPROXY 2>/dev/null || true
    fi
    if magicnet_cmd_exists ip; then
        # shellcheck disable=SC2086
        ip $_ip_args rule del fwmark "$_mark" table "$_table" 2>/dev/null || true
        # shellcheck disable=SC2086
        ip $_ip_args route del local default dev lo table "$_table" 2>/dev/null || true
    fi
    unset _cmd _ip_args _mark _table
}

magicnet_tproxy_cleanup() {
    magicnet_tproxy_cleanup_family iptables ""
    magicnet_tproxy_cleanup_family ip6tables "-6"
}

magicnet_tproxy_apply_family() {
    _cmd="$1"
    _ip_args="$2"
    _port="$(magicnet_tproxy_port)"
    _mark="$(magicnet_tproxy_mark)"
    _table="$(magicnet_tproxy_table)"
    _uid="${MAGICNET_TPROXY_EXEMPT_UID:-0}"

    magicnet_cmd_exists "$_cmd" || return 0
    "$_cmd" -t mangle -N MAGICNET_TPROXY 2>/dev/null || true
    "$_cmd" -t mangle -F MAGICNET_TPROXY 2>/dev/null || true
    "$_cmd" -t mangle -A MAGICNET_TPROXY -m owner --uid-owner "$_uid" -j RETURN 2>/dev/null || true

    if [ "$_cmd" = "ip6tables" ]; then
        "$_cmd" -t mangle -A MAGICNET_TPROXY -d ::1/128 -j RETURN 2>/dev/null || true
        "$_cmd" -t mangle -A MAGICNET_TPROXY -d fc00::/7 -j RETURN 2>/dev/null || true
        "$_cmd" -t mangle -A MAGICNET_TPROXY -d fe80::/10 -j RETURN 2>/dev/null || true
        "$_cmd" -t mangle -A MAGICNET_TPROXY -d ff00::/8 -j RETURN 2>/dev/null || true
    else
        for _cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
            169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4; do
            "$_cmd" -t mangle -A MAGICNET_TPROXY -d "$_cidr" -j RETURN 2>/dev/null || true
        done
    fi

    "$_cmd" -t mangle -A MAGICNET_TPROXY -p tcp -j TPROXY \
        --on-port "$_port" --tproxy-mark "$_mark/$_mark" 2>/dev/null || return 1
    "$_cmd" -t mangle -A MAGICNET_TPROXY -p udp -j TPROXY \
        --on-port "$_port" --tproxy-mark "$_mark/$_mark" 2>/dev/null || return 1
    "$_cmd" -t mangle -C PREROUTING -j MAGICNET_TPROXY >/dev/null 2>&1 ||
        "$_cmd" -t mangle -A PREROUTING -j MAGICNET_TPROXY >/dev/null 2>&1 || return 1

    # shellcheck disable=SC2086
    ip $_ip_args rule show 2>/dev/null | grep -F "fwmark $_mark lookup $_table" >/dev/null 2>&1 ||
        ip $_ip_args rule add fwmark "$_mark" table "$_table" >/dev/null 2>&1 || return 1
    # shellcheck disable=SC2086
    ip $_ip_args route show table "$_table" 2>/dev/null | grep -F "local default dev lo" >/dev/null 2>&1 ||
        ip $_ip_args route add local default dev lo table "$_table" >/dev/null 2>&1 || return 1

    unset _cmd _ip_args _port _mark _table _uid _cidr
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

    magicnet_tproxy_apply_family iptables "" || return 1
    magicnet_tproxy_apply_family ip6tables "-6" || true
    magicnet_log "TProxy rules applied on port $(magicnet_tproxy_port) mark $(magicnet_tproxy_mark) table $(magicnet_tproxy_table)"
}
