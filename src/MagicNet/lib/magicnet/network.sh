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

magicnet_ip6tables_nat_ensure() {
    magicnet_cmd_exists ip6tables || return 1
    ip6tables -t nat -C "$@" >/dev/null 2>&1 || ip6tables -t nat -A "$@" >/dev/null 2>&1
}

magicnet_dns_capture_enabled() {
    [ "${MAGIC_DNS_CAPTURE:-1}" = "1" ]
}

magicnet_dns_capture_port() {
    printf '%s\n' "${MAGIC_DNS_CAPTURE_PORT:-1053}"
}

magicnet_dns_capture_bypass_uids() {
    _dns_bypass_uid_file="${MODDIR}/.state/app-policy/exclude-uids.list"
    [ -f "$_dns_bypass_uid_file" ] || {
        unset _dns_bypass_uid_file
        return 0
    }
    awk '/^[0-9]+$/ && !seen[$0]++ { print }' "$_dns_bypass_uid_file" 2>/dev/null
    unset _dns_bypass_uid_file
}

magicnet_enable_dns_capture() {
    if ! magicnet_dns_capture_enabled; then
        if magicnet_disable_dns_capture; then
            return 0
        fi
        magicnet_warn "Failed to remove stale DNS capture rules while DNS capture is disabled"
        return 1
    fi

    if [ "$(magicnet_dns_profile)" = "cloudflare-udp" ]; then
        magicnet_warn "DNS capture skipped for cloudflare-udp profile to avoid redirect loops"
        if magicnet_disable_dns_capture; then
            return 0
        fi
        magicnet_warn "Failed to remove stale DNS capture rules for cloudflare-udp profile"
        return 1
    fi

    if ! magicnet_cmd_exists iptables; then
        magicnet_warn "iptables not found; DNS capture cannot be enforced"
        return 1
    fi

    _dns_capture_port="$(magicnet_dns_capture_port)"
    _dns_capture_bypass_uids="$(magicnet_dns_capture_bypass_uids)"
    _dns_capture_rc=0
    _dns_capture_ipv6_unavailable=0
    if ! iptables -t nat -N magicnet-dns-output >/dev/null 2>&1; then
        iptables -t nat -L magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
    fi
    iptables -t nat -F magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
    if ! iptables -t nat -C OUTPUT -j magicnet-dns-output >/dev/null 2>&1; then
        iptables -t nat -I OUTPUT 1 -j magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
    fi
    for _dns_capture_bypass_uid in $_dns_capture_bypass_uids; do
        magicnet_iptables_ensure -t nat magicnet-dns-output -m owner --uid-owner "$_dns_capture_bypass_uid" -j RETURN || _dns_capture_rc=1
    done
    magicnet_iptables_ensure -t nat magicnet-dns-output -p udp --dport 53 -j REDIRECT --to-ports "$_dns_capture_port" || _dns_capture_rc=1
    magicnet_iptables_ensure -t nat magicnet-dns-output -p tcp --dport 53 -j REDIRECT --to-ports "$_dns_capture_port" || _dns_capture_rc=1

    _dns_capture_ipv6_mode="$(magicnet_ipv6_mode 2>/dev/null || printf '%s\n' prefer_ipv4)"
    if [ "$_dns_capture_ipv6_mode" != ipv4_only ]; then
        if ! magicnet_cmd_exists ip6tables || ! ip6tables -t nat -L >/dev/null 2>&1; then
            if [ "$_dns_capture_ipv6_mode" = prefer_ipv6 ]; then
                _dns_capture_rc=1
            else
                # Android kernels commonly expose ip6tables without an IPv6
                # nat table.  IPv4-first mode can still enforce its required
                # IPv4 capture path; do not turn that platform limitation into
                # a false global startup failure.
                _dns_capture_ipv6_unavailable=1
                magicnet_warn "IPv6 DNS capture unavailable; continuing with IPv4-first capture"
            fi
        else
            if ! ip6tables -t nat -N magicnet-dns-output >/dev/null 2>&1; then
                ip6tables -t nat -L magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
            fi
            ip6tables -t nat -F magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
            if ! ip6tables -t nat -C OUTPUT -j magicnet-dns-output >/dev/null 2>&1; then
                ip6tables -t nat -I OUTPUT 1 -j magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
            fi
            for _dns_capture_bypass_uid in $_dns_capture_bypass_uids; do
                magicnet_ip6tables_nat_ensure magicnet-dns-output -m owner --uid-owner "$_dns_capture_bypass_uid" -j RETURN || _dns_capture_rc=1
            done
            magicnet_ip6tables_nat_ensure magicnet-dns-output -p udp --dport 53 -j REDIRECT --to-ports "$_dns_capture_port" || _dns_capture_rc=1
            magicnet_ip6tables_nat_ensure magicnet-dns-output -p tcp --dport 53 -j REDIRECT --to-ports "$_dns_capture_port" || _dns_capture_rc=1
        fi
    fi

    if [ "$_dns_capture_rc" -ne 0 ]; then
        magicnet_disable_dns_capture >/dev/null 2>&1 || true
        unset _dns_capture_port _dns_capture_bypass_uids _dns_capture_bypass_uid
        unset _dns_capture_rc _dns_capture_ipv6_mode _dns_capture_ipv6_unavailable
        return 1
    fi

    if [ "$_dns_capture_ipv6_unavailable" -eq 1 ]; then
        magicnet_log "DNS capture redirected IPv4 port 53 to 127.0.0.1:${_dns_capture_port}; IPv6 nat unavailable"
    else
        magicnet_log "DNS capture redirected port 53 to 127.0.0.1:${_dns_capture_port}"
    fi
    unset _dns_capture_port _dns_capture_bypass_uids _dns_capture_bypass_uid
    unset _dns_capture_rc _dns_capture_ipv6_mode _dns_capture_ipv6_unavailable
}

magicnet_dns_capture_delete_jump() {
    _dns_capture_delete_cmd="$1"
    _dns_capture_delete_table_flag="$2"
    _dns_capture_delete_table="$3"
    shift 3
    _dns_capture_delete_attempts=0
    while [ "$_dns_capture_delete_attempts" -lt 64 ]; do
        if "$_dns_capture_delete_cmd" "$_dns_capture_delete_table_flag" "$_dns_capture_delete_table" \
            -D "$@" >/dev/null 2>&1; then
            _dns_capture_delete_attempts=$((_dns_capture_delete_attempts + 1))
            continue
        fi

        # A failed delete can be a transient xtables error rather than an
        # absent jump.  Probe the rule before declaring cleanup complete.
        _dns_capture_delete_check_rc=0
        "$_dns_capture_delete_cmd" "$_dns_capture_delete_table_flag" "$_dns_capture_delete_table" \
            -C "$@" >/dev/null 2>&1 ||
            _dns_capture_delete_check_rc=$?
        if [ "$_dns_capture_delete_check_rc" -eq 0 ]; then
            _dns_capture_delete_attempts=$((_dns_capture_delete_attempts + 1))
            continue
        fi
        if [ "$_dns_capture_delete_check_rc" -eq 1 ]; then
            unset _dns_capture_delete_cmd _dns_capture_delete_table_flag _dns_capture_delete_table
            unset _dns_capture_delete_attempts _dns_capture_delete_check_rc
            return 0
        fi
        unset _dns_capture_delete_cmd _dns_capture_delete_table_flag _dns_capture_delete_table
        unset _dns_capture_delete_attempts _dns_capture_delete_check_rc
        return 1
    done

    _dns_capture_delete_check_rc=0
    "$_dns_capture_delete_cmd" "$_dns_capture_delete_table_flag" "$_dns_capture_delete_table" \
        -C "$@" >/dev/null 2>&1 ||
        _dns_capture_delete_check_rc=$?
    if [ "$_dns_capture_delete_check_rc" -eq 1 ]; then
        unset _dns_capture_delete_cmd _dns_capture_delete_table_flag _dns_capture_delete_table
        unset _dns_capture_delete_attempts _dns_capture_delete_check_rc
        return 0
    fi
    unset _dns_capture_delete_cmd _dns_capture_delete_table_flag _dns_capture_delete_table
    unset _dns_capture_delete_attempts _dns_capture_delete_check_rc
    return 1
}

magicnet_disable_dns_capture() {
    _dns_capture_cleanup_rc=0
    if magicnet_cmd_exists iptables; then
        # A failed/repeated enable can leave duplicate jumps in OUTPUT.  A
        # single `-D` only removes the first one, so keep deleting until the
        # chain is no longer referenced before flushing/removing it.
        magicnet_dns_capture_delete_jump iptables -t nat OUTPUT -j magicnet-dns-output || _dns_capture_cleanup_rc=1
        _dns_capture_chain_rc=0
        iptables -t nat -L magicnet-dns-output >/dev/null 2>&1 || _dns_capture_chain_rc=$?
        if [ "$_dns_capture_chain_rc" -eq 0 ]; then
            iptables -t nat -F magicnet-dns-output >/dev/null 2>&1 || _dns_capture_cleanup_rc=1
            iptables -t nat -X magicnet-dns-output >/dev/null 2>&1 || _dns_capture_cleanup_rc=1
        elif [ "$_dns_capture_chain_rc" -ne 1 ]; then
            _dns_capture_cleanup_rc=1
        fi
    fi
    if magicnet_cmd_exists ip6tables && ip6tables -t nat -L >/dev/null 2>&1; then
        magicnet_dns_capture_delete_jump ip6tables -t nat OUTPUT -j magicnet-dns-output || _dns_capture_cleanup_rc=1
        _dns_capture_chain_rc=0
        ip6tables -t nat -L magicnet-dns-output >/dev/null 2>&1 || _dns_capture_chain_rc=$?
        if [ "$_dns_capture_chain_rc" -eq 0 ]; then
            ip6tables -t nat -F magicnet-dns-output >/dev/null 2>&1 || _dns_capture_cleanup_rc=1
            ip6tables -t nat -X magicnet-dns-output >/dev/null 2>&1 || _dns_capture_cleanup_rc=1
        elif [ "$_dns_capture_chain_rc" -ne 1 ]; then
            _dns_capture_cleanup_rc=1
        fi
    fi
    if [ "$_dns_capture_cleanup_rc" -ne 0 ]; then
        unset _dns_capture_cleanup_rc _dns_capture_chain_rc
        return 1
    fi
    unset _dns_capture_cleanup_rc _dns_capture_chain_rc
    return 0
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

magicnet_dns_leak_guard_state_file() {
    printf '%s\n' "${MODDIR}/.state/dns-leak-guard.ifaces"
}

magicnet_dns_leak_guard_supported_for_mode() {
    return 0
}

magicnet_dns_leak_guard_delete_rule() {
    _dns_guard_delete_cmd="$1"
    shift
    _dns_guard_delete_attempts=0
    while [ "$_dns_guard_delete_attempts" -lt 64 ]; do
        if "$_dns_guard_delete_cmd" -D "$@" >/dev/null 2>&1; then
            _dns_guard_delete_attempts=$((_dns_guard_delete_attempts + 1))
            continue
        fi

        # A failed delete is normal when the rule is already absent.  A
        # successful check means a transient xtables failure left the rule in
        # place, while any other check error is also unsafe to forget.
        _dns_guard_delete_check_rc=0
        "$_dns_guard_delete_cmd" -C "$@" >/dev/null 2>&1 ||
            _dns_guard_delete_check_rc=$?
        if [ "$_dns_guard_delete_check_rc" -eq 1 ]; then
            unset _dns_guard_delete_cmd _dns_guard_delete_attempts _dns_guard_delete_check_rc
            return 0
        fi
        unset _dns_guard_delete_cmd _dns_guard_delete_attempts _dns_guard_delete_check_rc
        return 1
    done

    _dns_guard_delete_check_rc=0
    "$_dns_guard_delete_cmd" -C "$@" >/dev/null 2>&1 ||
        _dns_guard_delete_check_rc=$?
    if [ "$_dns_guard_delete_check_rc" -eq 1 ]; then
        unset _dns_guard_delete_cmd _dns_guard_delete_attempts _dns_guard_delete_check_rc
        return 0
    fi
    unset _dns_guard_delete_cmd _dns_guard_delete_attempts _dns_guard_delete_check_rc
    return 1
}

magicnet_enable_dns_leak_guard() {
    if ! magicnet_dns_leak_guard_enabled; then
        if magicnet_disable_dns_leak_guard; then
            return 0
        fi
        magicnet_warn "Failed to remove stale DNS leak guard rules while the guard is disabled"
        return 1
    fi

    if ! magicnet_cmd_exists iptables; then
        magicnet_warn "iptables not found; DNS leak guard cannot be enforced"
        return 1
    fi

    # Re-apply is also used after a network transition.  Remove rules owned
    # by the previous interface set first; otherwise replacing the state file
    # below would strand REJECT rules on the old Wi-Fi/cellular interface.
    if ! magicnet_disable_dns_leak_guard >/dev/null 2>&1; then
        # Never replace the saved interface set while an old rule may still
        # be installed.  Doing so strands a DNS reject rule on the previous
        # Wi-Fi/cellular interface and makes the next network transition fail
        # in a way that looks like an unrelated connectivity outage.
        magicnet_warn "Failed to clear previous DNS leak guard rules"
        return 1
    fi
    _dns_guard_ifaces="$(magicnet_collect_physical_egress_ifaces)"
    if [ -z "$_dns_guard_ifaces" ]; then
        magicnet_warn "No physical egress interface found; DNS leak guard cannot be enforced"
        return 1
    fi

    _dns_guard_rc=0
    _dns_guard_ipv6_mode="$(magicnet_ipv6_mode 2>/dev/null || printf '%s\n' prefer_ipv4)"
    _dns_guard_ipv6_available=0
    if [ "$_dns_guard_ipv6_mode" != ipv4_only ]; then
        # Leak-guard rules live in the IPv6 filter table, not nat.  Android
        # devices commonly expose filter support while omitting an IPv6 nat
        # table; probing nat here would silently disable IPv6 leak protection
        # on exactly those devices.
        if magicnet_cmd_exists ip6tables && ip6tables -L >/dev/null 2>&1; then
            _dns_guard_ipv6_available=1
        elif [ "$_dns_guard_ipv6_mode" = prefer_ipv6 ]; then
            _dns_guard_rc=1
        else
            magicnet_warn "IPv6 DNS leak guard unavailable; continuing with IPv4-first guard"
        fi
    fi
    for _dns_guard_iface in $_dns_guard_ifaces; do
        for _dns_guard_port in 53 853; do
            magicnet_iptables_ensure OUTPUT -o "$_dns_guard_iface" -p udp --dport "$_dns_guard_port" -j REJECT || _dns_guard_rc=1
            magicnet_iptables_ensure OUTPUT -o "$_dns_guard_iface" -p tcp --dport "$_dns_guard_port" -j REJECT || _dns_guard_rc=1
            if [ "$_dns_guard_ipv6_available" -eq 1 ]; then
                magicnet_ip6tables_ensure OUTPUT -o "$_dns_guard_iface" -p udp --dport "$_dns_guard_port" -j REJECT || _dns_guard_rc=1
                magicnet_ip6tables_ensure OUTPUT -o "$_dns_guard_iface" -p tcp --dport "$_dns_guard_port" -j REJECT || _dns_guard_rc=1
            fi
        done
    done

    if [ "$_dns_guard_rc" -ne 0 ]; then
        magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
        unset _dns_guard_ifaces _dns_guard_iface _dns_guard_port
        unset _dns_guard_rc _dns_guard_ipv6_mode _dns_guard_ipv6_available
        return 1
    fi

    # Keep the interface set that actually received rules.  Android can
    # switch from Wi-Fi to cellular between enable and cleanup; discovering
    # only the current interface would otherwise leave the old REJECT rules
    # behind and make later DNS behavior depend on the previous network.
    _dns_guard_state_file="$(magicnet_dns_leak_guard_state_file)"
    _dns_guard_state_tmp="${_dns_guard_state_file}.new.$$"
    if ! mkdir -p "${_dns_guard_state_file%/*}" ||
        ! (umask 077; printf '%s\n' "$_dns_guard_ifaces" >"$_dns_guard_state_tmp") ||
        ! mv -f "$_dns_guard_state_tmp" "$_dns_guard_state_file"; then
        magicnet_warn "Failed to persist DNS leak guard interface state"
        rm -f "$_dns_guard_state_tmp" 2>/dev/null || true
        magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
        unset _dns_guard_ifaces _dns_guard_iface _dns_guard_port
        unset _dns_guard_rc _dns_guard_ipv6_mode _dns_guard_ipv6_available _dns_guard_state_file _dns_guard_state_tmp
        return 1
    fi

    magicnet_log "DNS leak guard blocked direct 53/853 on: $_dns_guard_ifaces"
    unset _dns_guard_ifaces _dns_guard_iface _dns_guard_port
    unset _dns_guard_rc _dns_guard_ipv6_mode _dns_guard_ipv6_available _dns_guard_state_file _dns_guard_state_tmp
}

magicnet_disable_dns_leak_guard() {
    _dns_guard_result=0
    if magicnet_cmd_exists iptables; then
        _dns_guard_state_file="$(magicnet_dns_leak_guard_state_file)"
        _dns_guard_saved_ifaces=
        _dns_guard_cleanup_rc=0
        if [ -f "$_dns_guard_state_file" ]; then
            if ! _dns_guard_saved_ifaces="$(awk '/^[[:alnum:]_.-]+$/ { print }' "$_dns_guard_state_file" 2>/dev/null)"; then
                _dns_guard_saved_ifaces=
                _dns_guard_cleanup_rc=1
            fi
        fi
        _dns_guard_ifaces="$(printf '%s\n%s\n' "$_dns_guard_saved_ifaces" "$(magicnet_collect_physical_egress_ifaces)" |
            awk 'NF && !seen[$0]++')"
        for _dns_guard_iface in $_dns_guard_ifaces; do
            for _dns_guard_port in 53 853; do
                magicnet_dns_leak_guard_delete_rule iptables OUTPUT -o "$_dns_guard_iface" \
                    -p udp --dport "$_dns_guard_port" -j REJECT || _dns_guard_cleanup_rc=1
                magicnet_dns_leak_guard_delete_rule iptables OUTPUT -o "$_dns_guard_iface" \
                    -p tcp --dport "$_dns_guard_port" -j REJECT || _dns_guard_cleanup_rc=1
                if magicnet_cmd_exists ip6tables && ip6tables -L >/dev/null 2>&1; then
                    magicnet_dns_leak_guard_delete_rule ip6tables OUTPUT -o "$_dns_guard_iface" \
                        -p udp --dport "$_dns_guard_port" -j REJECT || _dns_guard_cleanup_rc=1
                    magicnet_dns_leak_guard_delete_rule ip6tables OUTPUT -o "$_dns_guard_iface" \
                        -p tcp --dport "$_dns_guard_port" -j REJECT || _dns_guard_cleanup_rc=1
                fi
            done
        done
        if [ "$_dns_guard_cleanup_rc" -eq 0 ]; then
            rm -f "$_dns_guard_state_file" 2>/dev/null || true
        else
            _dns_guard_result=1
        fi
    fi
    unset _dns_guard_state_file _dns_guard_saved_ifaces _dns_guard_ifaces _dns_guard_iface _dns_guard_port
    if [ "$_dns_guard_result" -ne 0 ]; then
        unset _dns_guard_cleanup_rc _dns_guard_result
        return 1
    fi
    unset _dns_guard_cleanup_rc _dns_guard_result
    return 0
}

magicnet_after_kernel_start_unlocked() {
    magicnet_singbox_apply_zashboard ||
        magicnet_warn "Failed to materialize the sing-box Zashboard panel; the core will continue without the panel rewrite."
    # This phase used to be detached from the caller.  That allowed a
    # successful `service start` to race the DNS/TUN materialization and made
    # the first diagnostic or WebUI action fail intermittently.  Run it in the
    # current root shell so the caller observes the actual ready/failed state.
    magicnet_after_kernel_start_deferred
    _after_result=$?
    if [ "$_after_result" -ne 0 ]; then
        magicnet_warn "Post-start network initialization failed; DNS interception remains disabled."
    fi
    set -- "$_after_result"
    unset _after_result
    return "$1"
}

# Keep the post-start config rewrites and their corresponding kernel rules in
# one transaction.  Without this outer lock, fswatch or a concurrent WebUI
# action can observe the startup-time rewrites after `singbox_start` returns,
# restart the core, and leave DNS interception attached to the wrong instance.
magicnet_after_kernel_start() {
    magicnet_with_config_lock magicnet_after_kernel_start_unlocked
}

magicnet_after_kernel_start_deferred_unlocked() {
    _deferred_failures=
    _deferred_mark_failed() {
        _deferred_failures="${_deferred_failures}${_deferred_failures:+,}$1"
    }

    magicnet_dns_apply_unlocked || _deferred_mark_failed dns
    magicnet_transparent_apply_unlocked || _deferred_mark_failed transparent
    magicnet_app_policy_apply_unlocked || _deferred_mark_failed app-policy
    magicnet_warp_apply_unlocked || _deferred_mark_failed warp
    # Keep the hotspot route authoritative after every deferred config rewrite.
    # These rewrites run asynchronously after the core starts and may otherwise
    # publish a snapshot that predates the startup-time hotspot normalization.
    magicnet_singbox_apply_hotspot_policy || _deferred_mark_failed hotspot
    # Android inserts a higher-priority tethering rule after the hotspot
    # interface appears. Install MagicNet's per-interface rule after the TUN
    # table exists so forwarded clients reach magicnet0 before that rule.
    magicnet_hotspot_reconcile ||
        magicnet_warn "Hotspot TUN policy is not ready; the interface watcher will retry it."

    if [ -n "$_deferred_failures" ]; then
        # A partially applied configuration must not leave stale interception
        # or leak-guard rules pointing at a failed DNS/core setup.
        _deferred_failure_names="$_deferred_failures"
        magicnet_warn "Post-start network rewrites failed: $_deferred_failure_names"
        magicnet_disable_dns_capture || true
        magicnet_disable_dns_leak_guard || true
        magicnet_warn "Deferred network configuration failed: ${_deferred_failures}; DNS interception disabled"
        unset _deferred_failures _deferred_failure_names
        return 1
    fi

    if ! magicnet_enable_dns_capture; then
        _deferred_mark_failed dns-capture
    fi
    if ! magicnet_enable_dns_leak_guard; then
        _deferred_mark_failed dns-leak-guard
    fi
    if [ -n "$_deferred_failures" ]; then
        _deferred_failure_names="$_deferred_failures"
        magicnet_warn "Post-start network controls failed: $_deferred_failure_names"
        magicnet_disable_dns_capture || true
        magicnet_disable_dns_leak_guard || true
        unset _deferred_failures _deferred_failure_names
        return 1
    fi
    unset _deferred_failures _deferred_failure_names
    return 0
}

magicnet_after_kernel_start_deferred() {
    magicnet_with_config_lock magicnet_after_kernel_start_deferred_unlocked
}
