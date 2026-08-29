magicnet_iface_name_valid() {
    case "$1" in
    '' | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-]*) return 1 ;;
    esac
    [ "${#1}" -le 15 ]
}

magicnet_iface_exists() {
    magicnet_iface_name_valid "$1" && [ -d "/sys/class/net/$1" ]
}

# Android's iptables front-end can wait indefinitely for the netd xtables
# writer when a vendor process leaves a restore transaction open.  Network
# setup is called while starting/restarting sing-box, so an unbounded probe
# can strand the subscription transaction and its config lock forever.  Keep
# test doubles untouched, but bound real device calls and fail closed when
# the lock is not available promptly.
magicnet_xtables_function_defined() {
    _xtables_command="$1"
    case "$(LC_ALL=C LANG=C command -V "$_xtables_command" 2>/dev/null || true)" in
    *function* | *Function*)
        unset _xtables_command
        return 0
        ;;
    esac
    unset _xtables_command
    return 1
}

magicnet_xtables_timeout() {
    _xtables_timeout="${MAGICNET_XTABLES_TIMEOUT:-5}"
    case "$_xtables_timeout" in
    '' | *[!0-9]*) _xtables_timeout=5 ;;
    *)
        if [ "$_xtables_timeout" -lt 1 ] || [ "$_xtables_timeout" -gt 30 ]; then
            _xtables_timeout=5
        fi
        ;;
    esac
    printf '%s\n' "$_xtables_timeout"
    unset _xtables_timeout
}

magicnet_iptables_cmd() {
    if magicnet_xtables_function_defined iptables; then
        iptables "$@"
        return $?
    fi
    if magicnet_cmd_exists timeout; then
        timeout "$(magicnet_xtables_timeout)" iptables "$@"
    else
        # All supported Android builds ship toybox timeout.  Keep a bounded
        # xtables wait even on a minimal test/runtime image without it.
        iptables -w 1 "$@"
    fi
}

magicnet_ip6tables_cmd() {
    if magicnet_xtables_function_defined ip6tables; then
        ip6tables "$@"
        return $?
    fi
    if magicnet_cmd_exists timeout; then
        timeout "$(magicnet_xtables_timeout)" ip6tables "$@"
    else
        ip6tables -w 1 "$@"
    fi
}

# Root is not sufficient for legacy xtables on every Android vendor build:
# the KSU shell context may see the binaries but still be denied access to
# the kernel table.  DNS interception is already handled by sing-box inside
# the MagicNet TUN, so these optional kernel rules must not make TUN startup
# fail closed.  Test doubles remain treated as available so the shell tests
# can still exercise their failure paths.
magicnet_xtables_available() {
    _xtables_family="$1"
    case "$_xtables_family" in
    iptables | ip6tables) ;;
    *)
        unset _xtables_family
        return 1
        ;;
    esac
    if ! magicnet_cmd_exists "$_xtables_family"; then
        unset _xtables_family
        return 1
    fi
    if magicnet_xtables_function_defined "$_xtables_family"; then
        unset _xtables_family
        return 0
    fi
    case "$_xtables_family" in
    iptables) magicnet_iptables_cmd -L >/dev/null 2>&1 ;;
    ip6tables) magicnet_ip6tables_cmd -L >/dev/null 2>&1 ;;
    esac
    _xtables_rc=$?
    unset _xtables_family
    return "$_xtables_rc"
}

magicnet_xtables_ensure_rule() (
    _ensure_cmd="$1"
    _ensure_add="$2"
    _ensure_table="$3"
    shift 3
    _ensure_rc=0
    if [ -n "$_ensure_table" ]; then
        "$_ensure_cmd" -t "$_ensure_table" -C "$@" >/dev/null 2>&1 || _ensure_rc=$?
    else
        "$_ensure_cmd" -C "$@" >/dev/null 2>&1 || _ensure_rc=$?
    fi
    case "$_ensure_rc" in
    0) return 0 ;;
    1)
        if [ -n "$_ensure_table" ]; then
            "$_ensure_cmd" -t "$_ensure_table" "$_ensure_add" "$@" >/dev/null 2>&1
        else
            "$_ensure_cmd" "$_ensure_add" "$@" >/dev/null 2>&1
        fi
        ;;
    124 | 137 | 143) return 124 ;;
    *) return "$_ensure_rc" ;;
    esac
)

magicnet_iptables_ensure() {
    if [ "$1" = "-t" ]; then
        _table="$2"
        shift 2
        magicnet_xtables_ensure_rule magicnet_iptables_cmd -A "$_table" "$@"
        _ensure_result=$?
        unset _table
        return "$_ensure_result"
    fi
    magicnet_xtables_ensure_rule magicnet_iptables_cmd -I "" "$@"
}

magicnet_ip6tables_ensure() {
    magicnet_cmd_exists ip6tables || return 1
    magicnet_xtables_ensure_rule magicnet_ip6tables_cmd -I "" "$@"
}

magicnet_ip6tables_nat_ensure() {
    magicnet_cmd_exists ip6tables || return 1
    magicnet_xtables_ensure_rule magicnet_ip6tables_cmd -A nat "$@"
}

magicnet_dns_capture_enabled() {
    [ "${MAGIC_DNS_CAPTURE:-1}" = "1" ]
}

magicnet_dns_capture_port() {
    _dns_capture_port="${MAGIC_DNS_CAPTURE_PORT:-1053}"
    case "$_dns_capture_port" in
    '' | *[!0-9]*) _dns_capture_port=1053 ;;
    *)
        if [ "$_dns_capture_port" -lt 1 ] || [ "$_dns_capture_port" -gt 65535 ]; then
            _dns_capture_port=1053
        fi
        ;;
    esac
    printf '%s\n' "$_dns_capture_port"
    unset _dns_capture_port
}

magicnet_dns_capture_bypass_uids() {
    _dns_bypass_uid_file="${MODDIR}/.state/app-policy/exclude-uids.list"
    [ -f "$_dns_bypass_uid_file" ] || {
        unset _dns_bypass_uid_file
        return 0
    }
    # UID 0 matrix (keep in sync with transparent.sh TUN exclude_uid):
    # - TUN always excludes UID 0 from magicnet0.
    # - DNS capture usually intercepts UID 0 (Android netd).
    # - Android netd can emit a Bypass TUN app's DNS request as UID 0. Once
    #   netd proxies the lookup, xt_owner cannot recover the originating app;
    #   keep UID 0 outside capture whenever a real bypass UID is configured so
    #   the app and its DNS stay on the same non-MagicNet path.
    _dns_bypass_uids="$(awk '/^[0-9]+$/ && ($0 + 0) != 0 && !seen[$0]++ { print }' "$_dns_bypass_uid_file" 2>/dev/null)"
    if [ -n "$_dns_bypass_uids" ]; then
        printf '%s\n' 0
    fi
    printf '%s\n' "$_dns_bypass_uids"
    unset _dns_bypass_uid_file _dns_bypass_uids
}

magicnet_dns_capture_singbox_udp_marked() {
    _dns_marked_config="$(magicnet_singbox_config_file 2>/dev/null || printf '%s\n' "${MODDIR}/.config/sing-box/config.json")"
    _dns_marked_jq="${MODDIR}/bin/jq"
    [ -x "$_dns_marked_jq" ] || _dns_marked_jq="$(command -v jq 2>/dev/null || true)"
    [ -f "$_dns_marked_config" ] && [ -n "$_dns_marked_jq" ] || {
        unset _dns_marked_config _dns_marked_jq
        return 1
    }
    "$_dns_marked_jq" -e --argjson dns_capture_singbox_mark "$(magicnet_dns_capture_singbox_mark)" \
        'any((.dns.servers // [])[]?; .type == "udp" and .routing_mark == $dns_capture_singbox_mark)' \
        "$_dns_marked_config" >/dev/null 2>&1
    _dns_marked_rc=$?
    unset _dns_marked_config _dns_marked_jq
    return "$_dns_marked_rc"
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

    if ! magicnet_xtables_available iptables; then
        magicnet_warn "iptables is unavailable in the current Android root context; skipping kernel DNS capture and keeping sing-box TUN DNS"
        return 0
    fi

    _dns_capture_port="$(magicnet_dns_capture_port)"
    _dns_capture_bypass_uids="$(magicnet_dns_capture_bypass_uids)"
    _dns_capture_singbox_mark="$(magicnet_dns_capture_singbox_mark)"
    _dns_capture_singbox_marked=0
    magicnet_dns_capture_singbox_udp_marked && _dns_capture_singbox_marked=1
    _dns_capture_rc=0
    _dns_capture_ipv6_unavailable=0
    if ! magicnet_iptables_cmd -t nat -N magicnet-dns-output >/dev/null 2>&1; then
        magicnet_iptables_cmd -t nat -L magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
    fi
    magicnet_iptables_cmd -t nat -F magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
    _dns_capture_check_rc=0
    magicnet_iptables_cmd -t nat -C OUTPUT -j magicnet-dns-output >/dev/null 2>&1 || _dns_capture_check_rc=$?
    case "$_dns_capture_check_rc" in
    0) ;;
    1) magicnet_iptables_cmd -t nat -I OUTPUT 1 -j magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1 ;;
    *) _dns_capture_rc=1 ;;
    esac
    # Direct UDP DNS servers are marked in the sing-box config. Keep those
    # resolver packets out of this chain without exempting all UID-0 traffic.
    if [ "$_dns_capture_singbox_marked" -eq 1 ]; then
        magicnet_iptables_ensure -t nat magicnet-dns-output -m mark --mark "$_dns_capture_singbox_mark/$_dns_capture_singbox_mark" -j RETURN || _dns_capture_rc=1
    fi
    case " $_dns_capture_bypass_uids " in
    *" 0 "*)
        magicnet_log "DNS capture keeps UID 0 outside interception while Bypass TUN UIDs are configured"
        ;;
    esac
    for _dns_capture_bypass_uid in $_dns_capture_bypass_uids; do
        magicnet_iptables_ensure -t nat magicnet-dns-output -m owner --uid-owner "$_dns_capture_bypass_uid" -j RETURN || _dns_capture_rc=1
    done
    magicnet_iptables_ensure -t nat magicnet-dns-output -p udp --dport 53 -j REDIRECT --to-ports "$_dns_capture_port" || _dns_capture_rc=1
    magicnet_iptables_ensure -t nat magicnet-dns-output -p tcp --dport 53 -j REDIRECT --to-ports "$_dns_capture_port" || _dns_capture_rc=1

    _dns_capture_ipv6_mode="$(magicnet_ipv6_mode 2>/dev/null || printf '%s\n' prefer_ipv4)"
    if [ "$_dns_capture_ipv6_mode" != ipv4_only ]; then
        if ! magicnet_cmd_exists ip6tables || ! magicnet_ip6tables_cmd -t nat -L >/dev/null 2>&1; then
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
            if ! magicnet_ip6tables_cmd -t nat -N magicnet-dns-output >/dev/null 2>&1; then
                magicnet_ip6tables_cmd -t nat -L magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
            fi
            magicnet_ip6tables_cmd -t nat -F magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1
            _dns_capture_check_rc=0
            magicnet_ip6tables_cmd -t nat -C OUTPUT -j magicnet-dns-output >/dev/null 2>&1 || _dns_capture_check_rc=$?
            case "$_dns_capture_check_rc" in
            0) ;;
            1) magicnet_ip6tables_cmd -t nat -I OUTPUT 1 -j magicnet-dns-output >/dev/null 2>&1 || _dns_capture_rc=1 ;;
            *) _dns_capture_rc=1 ;;
            esac
            if [ "$_dns_capture_singbox_marked" -eq 1 ]; then
                magicnet_ip6tables_nat_ensure magicnet-dns-output -m mark --mark "$_dns_capture_singbox_mark/$_dns_capture_singbox_mark" -j RETURN || _dns_capture_rc=1
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
        unset _dns_capture_port _dns_capture_bypass_uids _dns_capture_bypass_uid _dns_capture_singbox_mark _dns_capture_singbox_marked
        unset _dns_capture_rc _dns_capture_check_rc _dns_capture_ipv6_mode _dns_capture_ipv6_unavailable
        return 1
    fi

    if [ "$_dns_capture_ipv6_unavailable" -eq 1 ]; then
        magicnet_log "DNS capture redirected IPv4 port 53 to 127.0.0.1:${_dns_capture_port}; IPv6 nat unavailable"
    else
        magicnet_log "DNS capture redirected port 53 to 127.0.0.1:${_dns_capture_port}"
    fi
    unset _dns_capture_port _dns_capture_bypass_uids _dns_capture_bypass_uid _dns_capture_singbox_mark _dns_capture_singbox_marked
    unset _dns_capture_rc _dns_capture_check_rc _dns_capture_ipv6_mode _dns_capture_ipv6_unavailable
}

magicnet_xtables_delete_rule() (
    _delete_cmd="$1"
    _delete_table="$2"
    shift 2
    _delete_attempt=0
    while [ "$_delete_attempt" -lt 64 ]; do
        _delete_rc=0
        if [ -n "$_delete_table" ]; then
            "$_delete_cmd" -t "$_delete_table" -D "$@" >/dev/null 2>&1 || _delete_rc=$?
        else
            "$_delete_cmd" -D "$@" >/dev/null 2>&1 || _delete_rc=$?
        fi
        case "$_delete_rc" in 124 | 137 | 143) return 124 ;; esac
        _delete_rc=0
        if [ -n "$_delete_table" ]; then
            "$_delete_cmd" -t "$_delete_table" -C "$@" >/dev/null 2>&1 || _delete_rc=$?
        else
            "$_delete_cmd" -C "$@" >/dev/null 2>&1 || _delete_rc=$?
        fi
        case "$_delete_rc" in
        0)
            _delete_attempt=$((_delete_attempt + 1))
            continue
            ;;
        1) return 0 ;;
        124 | 137 | 143) return 124 ;;
        *) return 1 ;;
        esac
    done
    return 1
)

magicnet_dns_capture_delete_jump() (
    _dns_capture_delete_cmd="$1"
    _dns_capture_delete_table="$3"
    shift 3
    magicnet_xtables_delete_rule "$_dns_capture_delete_cmd" "$_dns_capture_delete_table" "$@"
)

magicnet_disable_dns_capture() {
    _dns_capture_cleanup_rc=0
    if magicnet_xtables_available iptables; then
        # A failed/repeated enable can leave duplicate jumps in OUTPUT.  A
        # single `-D` only removes the first one, so keep deleting until the
        # chain is no longer referenced before flushing/removing it.
        magicnet_dns_capture_delete_jump magicnet_iptables_cmd -t nat OUTPUT -j magicnet-dns-output || _dns_capture_cleanup_rc=1
        _dns_capture_chain_rc=0
        magicnet_iptables_cmd -t nat -L magicnet-dns-output >/dev/null 2>&1 || _dns_capture_chain_rc=$?
        if [ "$_dns_capture_chain_rc" -eq 0 ]; then
            magicnet_iptables_cmd -t nat -F magicnet-dns-output >/dev/null 2>&1 || _dns_capture_cleanup_rc=1
            magicnet_iptables_cmd -t nat -X magicnet-dns-output >/dev/null 2>&1 || _dns_capture_cleanup_rc=1
        elif [ "$_dns_capture_chain_rc" -ne 1 ]; then
            _dns_capture_cleanup_rc=1
        fi
    fi
    if magicnet_xtables_available ip6tables && magicnet_ip6tables_cmd -t nat -L >/dev/null 2>&1; then
        magicnet_dns_capture_delete_jump magicnet_ip6tables_cmd -t nat OUTPUT -j magicnet-dns-output || _dns_capture_cleanup_rc=1
        _dns_capture_chain_rc=0
        magicnet_ip6tables_cmd -t nat -L magicnet-dns-output >/dev/null 2>&1 || _dns_capture_chain_rc=$?
        if [ "$_dns_capture_chain_rc" -eq 0 ]; then
            magicnet_ip6tables_cmd -t nat -F magicnet-dns-output >/dev/null 2>&1 || _dns_capture_cleanup_rc=1
            magicnet_ip6tables_cmd -t nat -X magicnet-dns-output >/dev/null 2>&1 || _dns_capture_cleanup_rc=1
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
        rmnet* | ccmni* | ccemni* | pdp* | wwan* | wlan* | wifi* | eth*)
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

magicnet_dns_leak_guard_delete_rule() (
    _dns_guard_delete_cmd="$1"
    shift
    magicnet_xtables_delete_rule "$_dns_guard_delete_cmd" "" "$@"
)

magicnet_dns_leak_guard_delete_family() (
    _delete_family_cmd="$1"
    shift
    _delete_family_result=0
    for _delete_family_iface in $1; do
        for _delete_family_port in 53 853; do
            for _delete_family_proto in udp tcp; do
                _delete_family_rc=0
                magicnet_dns_leak_guard_delete_rule "$_delete_family_cmd" OUTPUT \
                    -o "$_delete_family_iface" -p "$_delete_family_proto" \
                    --dport "$_delete_family_port" -j REJECT ||
                    _delete_family_rc=$?
                case "$_delete_family_rc" in
                0) ;;
                124) return 124 ;;
                *) _delete_family_result=1 ;;
                esac
            done
        done
    done
    return "$_delete_family_result"
)

magicnet_dns_leak_guard_rule_ifaces() (
    _dns_guard_scan_cmd="$1"
    _dns_guard_scan_rules="$("$_dns_guard_scan_cmd" -S OUTPUT 2>/dev/null)" || return $?
    printf '%s\n' "$_dns_guard_scan_rules" | awk '
        $1 == "-A" && $2 == "OUTPUT" {
            iface = proto = port = target = ""
            for (field_index = 3; field_index <= NF; field_index++) {
                if ($field_index == "-o" && field_index < NF) iface = $(field_index + 1)
                if ($field_index == "-p" && field_index < NF) proto = $(field_index + 1)
                if ($field_index == "--dport" && field_index < NF) port = $(field_index + 1)
                if ($field_index == "-j" && field_index < NF) target = $(field_index + 1)
            }
            if (iface ~ /^[[:alnum:]_.-]+$/ && target == "REJECT" &&
                ((proto == "udp" && (port == "53" || port == "853")) ||
                 (proto == "tcp" && (port == "53" || port == "853")))) {
                print iface
            }
        }
    ' | awk '!seen[$0]++'
)

magicnet_enable_dns_leak_guard() {
    if ! magicnet_dns_leak_guard_enabled; then
        if magicnet_disable_dns_leak_guard; then
            return 0
        fi
        magicnet_warn "Failed to remove stale DNS leak guard rules while the guard is disabled"
        return 1
    fi

    if ! magicnet_xtables_available iptables; then
        magicnet_warn "iptables is unavailable in the current Android root context; skipping optional DNS leak guard"
        return 0
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
        if magicnet_cmd_exists ip6tables && magicnet_ip6tables_cmd -L >/dev/null 2>&1; then
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
        ! (
            umask 077
            printf '%s\n' "$_dns_guard_ifaces" >"$_dns_guard_state_tmp"
        ) ||
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

magicnet_disable_dns_leak_guard() (
    MAGICNET_XTABLES_TIMEOUT="${MAGICNET_DNS_GUARD_XTABLES_TIMEOUT:-1}"
    case "$MAGICNET_XTABLES_TIMEOUT" in
    '' | *[!0-9]* | 0) MAGICNET_XTABLES_TIMEOUT=1 ;;
    esac

    _cleanup_probe=0
    magicnet_xtables_available iptables || _cleanup_probe=$?
    case "$_cleanup_probe" in
    124 | 137 | 143) return 1 ;;
    0) ;;
    *) return 0 ;;
    esac

    _cleanup_state="$(magicnet_dns_leak_guard_state_file)"
    _cleanup_saved=
    _cleanup_result=0
    if [ -f "$_cleanup_state" ]; then
        _cleanup_saved=$(awk '/^[[:alnum:]_.-]+$/ { print }' "$_cleanup_state" 2>/dev/null) ||
            _cleanup_result=1
    fi

    # Listing OUTPUT once is much cheaper than issuing four delete/check pairs
    # for every physical interface when the guard is disabled (the default).
    # Keep the saved state as a fallback and discover all current interfaces
    # only when the ruleset cannot be inspected.
    _cleanup_ipv4_scan_failed=0
    _cleanup_ipv4_scan_rc=0
    _cleanup_ipv4_rules="$(magicnet_dns_leak_guard_rule_ifaces magicnet_iptables_cmd)" ||
        _cleanup_ipv4_scan_rc=$?
    case "$_cleanup_ipv4_scan_rc" in
    124 | 137 | 143) return 1 ;;
    0) ;;
    *) _cleanup_ipv4_scan_failed=1 ;;
    esac
    _cleanup_ipv4_ifaces=$(printf '%s\n%s\n' "$_cleanup_saved" "$_cleanup_ipv4_rules" |
        awk 'NF && !seen[$0]++')
    if [ "$_cleanup_ipv4_scan_failed" -ne 0 ]; then
        _cleanup_ipv4_ifaces=$(printf '%s\n%s\n' "$_cleanup_ipv4_ifaces" "$(magicnet_collect_physical_egress_ifaces)" |
            awk 'NF && !seen[$0]++')
    fi

    _cleanup_rc=0
    magicnet_dns_leak_guard_delete_family magicnet_iptables_cmd "$_cleanup_ipv4_ifaces" || _cleanup_rc=$?
    case "$_cleanup_rc" in
    124) return 1 ;;
    0) ;;
    *) _cleanup_result=1 ;;
    esac

    _cleanup_probe=0
    magicnet_xtables_available ip6tables || _cleanup_probe=$?
    if [ "$_cleanup_probe" -eq 0 ]; then
        _cleanup_ipv6_scan_failed=0
        _cleanup_ipv6_scan_rc=0
        _cleanup_ipv6_rules="$(magicnet_dns_leak_guard_rule_ifaces magicnet_ip6tables_cmd)" ||
            _cleanup_ipv6_scan_rc=$?
        case "$_cleanup_ipv6_scan_rc" in
        124 | 137 | 143) return 1 ;;
        0) ;;
        *) _cleanup_ipv6_scan_failed=1 ;;
        esac
        _cleanup_ipv6_ifaces=$(printf '%s\n%s\n' "$_cleanup_saved" "$_cleanup_ipv6_rules" |
            awk 'NF && !seen[$0]++')
        if [ "$_cleanup_ipv6_scan_failed" -ne 0 ]; then
            _cleanup_ipv6_ifaces=$(printf '%s\n%s\n' "$_cleanup_ipv6_ifaces" "$(magicnet_collect_physical_egress_ifaces)" |
                awk 'NF && !seen[$0]++')
        fi
        _cleanup_rc=0
        magicnet_dns_leak_guard_delete_family magicnet_ip6tables_cmd "$_cleanup_ipv6_ifaces" || _cleanup_rc=$?
        case "$_cleanup_rc" in
        124) return 1 ;;
        0) ;;
        *) _cleanup_result=1 ;;
        esac
    else
        case "$_cleanup_probe" in 124 | 137 | 143) return 1 ;; esac
    fi

    [ "$_cleanup_result" -eq 0 ] || return 1
    rm -f "$_cleanup_state" 2>/dev/null || true
)

magicnet_after_kernel_start_unlocked() {
    # Configuration is fully materialized before sing-box snapshots it.  The
    # synchronous post-start phase now installs only kernel state that requires
    # magicnet0 to exist, avoiding a second round of jq rewrites and config-lock
    # waits after the core is already healthy.
    magicnet_after_kernel_start_deferred_unlocked
    _after_result=$?
    if [ "$_after_result" -ne 0 ]; then
        magicnet_warn "Post-start network initialization failed; DNS interception remains disabled."
    fi
    set -- "$_after_result"
    unset _after_result
    return "$1"
}

magicnet_after_kernel_start() {
    magicnet_after_kernel_start_unlocked
}

magicnet_after_kernel_start_deferred_unlocked() {
    _deferred_failures=
    _deferred_mark_failed() {
        _deferred_failures="${_deferred_failures}${_deferred_failures:+,}$1"
    }

    # Android inserts a higher-priority tethering rule after the hotspot
    # interface appears. Install MagicNet's per-interface rule after the TUN
    # table exists so forwarded clients reach magicnet0 before that rule.
    magicnet_hotspot_reconcile ||
        magicnet_warn "Hotspot TUN policy is not ready; the interface watcher will retry it."

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
