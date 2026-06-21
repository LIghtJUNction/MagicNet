magicnet_iface_exists() {
    [ -n "$1" ] && [ -d "/sys/class/net/$1" ]
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

magicnet_ip6tables_ensure() {
    magicnet_cmd_exists ip6tables || return 1
    ip6tables -C "$@" >/dev/null 2>&1 || ip6tables -I "$@" >/dev/null 2>&1
}

magicnet_collect_physical_egress_ifaces() {
    if [ -n "${MAGIC_DNS_GUARD_IFACES:-}" ]; then
        for _iface in $MAGIC_DNS_GUARD_IFACES; do
            magicnet_iface_exists "$_iface" && printf '%s\n' "$_iface"
        done | awk '!seen[$0]++'
        return 0
    fi

    for _path in /sys/class/net/*; do
        [ -d "$_path" ] || continue
        _iface=${_path##*/}
        case "$_iface" in
            rmnet*|ccmni*|ccemni*|pdp*|wwan*|wlan*|wifi*|eth*)
                printf '%s\n' "$_iface"
                ;;
        esac
    done | awk '!seen[$0]++'
}

magicnet_dns_leak_guard_enabled() {
    [ "${MAGIC_DNS_LEAK_GUARD:-0}" = "1" ]
}

magicnet_dns_leak_guard_supported_for_mode() {
    return 0
}

magicnet_enable_dns_leak_guard() {
    if ! magicnet_dns_leak_guard_enabled; then
        magicnet_disable_dns_leak_guard
        return 0
    fi

    if ! magicnet_cmd_exists iptables; then
        magicnet_warn "iptables not found; DNS leak guard skipped"
        return 0
    fi

    _dns_guard_ifaces="$(magicnet_collect_physical_egress_ifaces)"
    if [ -z "$_dns_guard_ifaces" ]; then
        magicnet_warn "No physical egress interface found; DNS leak guard skipped"
        return 0
    fi

    for _dns_guard_iface in $_dns_guard_ifaces; do
        for _dns_guard_port in 53 853; do
            magicnet_iptables_ensure OUTPUT -o "$_dns_guard_iface" -p udp --dport "$_dns_guard_port" -j REJECT || true
            magicnet_iptables_ensure OUTPUT -o "$_dns_guard_iface" -p tcp --dport "$_dns_guard_port" -j REJECT || true
            magicnet_ip6tables_ensure OUTPUT -o "$_dns_guard_iface" -p udp --dport "$_dns_guard_port" -j REJECT || true
            magicnet_ip6tables_ensure OUTPUT -o "$_dns_guard_iface" -p tcp --dport "$_dns_guard_port" -j REJECT || true
        done
    done

    magicnet_log "DNS leak guard blocked direct 53/853 on: $_dns_guard_ifaces"
    unset _dns_guard_ifaces _dns_guard_iface _dns_guard_port
}

magicnet_disable_dns_leak_guard() {
    if magicnet_cmd_exists iptables; then
        _dns_guard_ifaces="$(magicnet_collect_physical_egress_ifaces)"
        for _dns_guard_iface in $_dns_guard_ifaces; do
            for _dns_guard_port in 53 853; do
                iptables -D OUTPUT -o "$_dns_guard_iface" -p udp --dport "$_dns_guard_port" -j REJECT 2>/dev/null || true
                iptables -D OUTPUT -o "$_dns_guard_iface" -p tcp --dport "$_dns_guard_port" -j REJECT 2>/dev/null || true
                if magicnet_cmd_exists ip6tables; then
                    ip6tables -D OUTPUT -o "$_dns_guard_iface" -p udp --dport "$_dns_guard_port" -j REJECT 2>/dev/null || true
                    ip6tables -D OUTPUT -o "$_dns_guard_iface" -p tcp --dport "$_dns_guard_port" -j REJECT 2>/dev/null || true
                fi
            done
        done
    fi
    unset _dns_guard_ifaces _dns_guard_iface _dns_guard_port
}

magicnet_after_kernel_start() {
    magicnet_singbox_apply_zashboard || true
    mkdir -p "${MODDIR}/.state" 2>/dev/null || true
    _after_kernel_runner="nohup"
    command -v setsid >/dev/null 2>&1 && _after_kernel_runner="setsid"
    $_after_kernel_runner sh -c '
        MODDIR="$1"
        MODPATH="$1"
        PATH="$1/bin:$1/system/bin:$PATH"
        export MODDIR MODPATH PATH
        . "$MODDIR/lib/kamfw/.kamfwrc"
        import __runtime__
        . "$MODDIR/lib/magicnet.sh"
        magicnet_after_kernel_start_deferred
        rm -f "$MODDIR/.state/after-kernel-start.pid" 2>/dev/null || true
    ' sh "$MODDIR" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" >"${MODDIR}/.state/after-kernel-start.pid" 2>/dev/null || true
    unset _after_kernel_runner
}

magicnet_after_kernel_start_deferred_unlocked() {
    magicnet_transparent_apply_unlocked || true
    magicnet_app_policy_apply_unlocked || true
    magicnet_enable_dns_leak_guard || true
}

magicnet_after_kernel_start_deferred() {
    magicnet_with_config_lock magicnet_after_kernel_start_deferred_unlocked
}
