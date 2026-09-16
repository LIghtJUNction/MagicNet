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
        timeout "$(magicnet_xtables_timeout)" iptables -w 1 "$@"
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
        timeout "$(magicnet_xtables_timeout)" ip6tables -w 1 "$@"
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
    iptables) magicnet_iptables_cmd -L -n >/dev/null 2>&1 ;;
    ip6tables) magicnet_ip6tables_cmd -L -n >/dev/null 2>&1 ;;
    esac
    _xtables_rc=$?
    unset _xtables_family
    return "$_xtables_rc"
}

# Probe the table actually used by the caller. A working filter table says
# nothing about nat support. Return 2 only for a missing binary/table/family;
# permission errors and lock timeouts are failures, not proof of absence.
magicnet_xtables_table_probe() (
    _probe_family="$1"
    _probe_table="$2"
    magicnet_cmd_exists "$_probe_family" || return 2
    # A readable legacy table registry gives a non-mutating answer. In
    # particular do not ask ip6tables to autoload an absent optional NAT table.
    if [ "$_probe_family:$_probe_table" = ip6tables:nat ] &&
        ! magicnet_xtables_function_defined ip6tables &&
        [ -r /proc/net/ip6_tables_names ] &&
        ! grep -Fqx nat /proc/net/ip6_tables_names; then
        # The proc registry belongs to legacy xtables, not the nft backend.
        # Version inspection does not create or autoload a kernel table.
        _probe_version="$(magicnet_ip6tables_cmd --version 2>/dev/null)" || return 1
        case "$_probe_version" in *"(legacy)"*) return 2 ;; esac
    fi
    _probe_rc=0
    _probe_error="$(LC_ALL=C LANG=C "magicnet_${_probe_family}_cmd" -t "$_probe_table" -L -n 2>&1 >/dev/null)" || _probe_rc=$?
    [ "$_probe_rc" -ne 0 ] || return 0
    case "$_probe_rc" in
    124 | 137 | 143) ;;
    *)
        case "$_probe_error" in
        *"Table does not exist"* | *"Address family not supported"* | *"Protocol not supported"*) return 2 ;;
        esac
        ;;
    esac
    # Absence is a capability result; permission/timeout is an actual failure.
    magicnet_warn "$_probe_family -t $_probe_table -L failed (exit=$_probe_rc): $_probe_error"
    return 1
)

# Preserve actionable stderr without logging expected absent-rule checks.
magicnet_xtables_require() (
    _require_rc=0
    _require_error="$("$@" 2>&1 >/dev/null)" || _require_rc=$?
    [ "$_require_rc" -ne 0 ] || return 0
    magicnet_warn "$* failed (exit=$_require_rc): $_require_error"
    return "$_require_rc"
)

magicnet_xtables_ensure_rule() (
    _ensure_cmd="$1"
    _ensure_add="$2"
    _ensure_table="$3"
    shift 3
    _ensure_rc=0
    if [ -n "$_ensure_table" ]; then
        _ensure_error="$("$_ensure_cmd" -t "$_ensure_table" -C "$@" 2>&1 >/dev/null)" || _ensure_rc=$?
    else
        _ensure_error="$("$_ensure_cmd" -C "$@" 2>&1 >/dev/null)" || _ensure_rc=$?
    fi
    case "$_ensure_rc" in
    0) return 0 ;;
    1)
        if [ -n "$_ensure_table" ]; then
            magicnet_xtables_require "$_ensure_cmd" -t "$_ensure_table" "$_ensure_add" "$@"
        else
            magicnet_xtables_require "$_ensure_cmd" "$_ensure_add" "$@"
        fi
        ;;
    *)
        magicnet_warn "$_ensure_cmd rule check failed (table=${_ensure_table:-filter}, exit=$_ensure_rc): $_ensure_error"
        case "$_ensure_rc" in 124 | 137 | 143) return 124 ;; esac
        return "$_ensure_rc"
        ;;
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
    # Android netd commonly emits application DNS as UID 0.  Exempting UID 0
    # whenever any app bypass exists leaks unrelated applications' DNS through
    # the physical resolver.  Keep only the concrete non-root bypass UIDs here;
    # netd-mediated DNS remains captured even when its originating app bypasses
    # the transparent dataplane.
    _dns_bypass_uids="$(awk '/^[0-9]+$/ && ($0 + 0) != 0 && !seen[$0]++ { print }' "$_dns_bypass_uid_file" 2>/dev/null)"
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

# Only new connections traverse nat. Keep ordinary TCP/UDP connections from
# scanning every app-bypass UID; RETURN resumes the caller's remaining rules,
# not ACCEPT. DNS still reaches the existing mark/owner checks and redirect.
magicnet_dns_capture_fast_path() {
    magicnet_xtables_ensure_rule "$1" -A nat magicnet-dns-output -p tcp ! --dport 53 -j RETURN &&
        magicnet_xtables_ensure_rule "$1" -A nat magicnet-dns-output -p udp ! --dport 53 -j RETURN
}

# A successful -C only proves membership, not priority. sing-box can prepend
# its own DNS DNAT jump when the core restarts; leaving our old jump in place
# then sends netd/application DNS to the TUN address before local capture.
# Remove only our known jump forms (including the temporary port-53 repair),
# using the bounded deletion helper. Never flush OUTPUT or another owner's rules.
magicnet_dns_capture_remove_output_jumps() (
    _dns_jump_cmd="$1"
    magicnet_xtables_delete_rule "$_dns_jump_cmd" nat OUTPUT -j magicnet-dns-output || return $?
    for _dns_jump_proto in udp tcp; do
        magicnet_xtables_delete_rule "$_dns_jump_cmd" nat OUTPUT \
            -p "$_dns_jump_proto" --dport 53 -j magicnet-dns-output || return $?
    done
)
magicnet_dns_capture_prepend_jump() (
    _dns_prepend_cmd="$1"
    magicnet_dns_capture_remove_output_jumps "$_dns_prepend_cmd" || return $?
    # -I without a rule number inserts at position one, even on Android xtables.
    magicnet_xtables_require "$_dns_prepend_cmd" -t nat -I OUTPUT -j magicnet-dns-output
)

# Canonical comparison of our complete chain, not a cached success marker.
# Ignore only iptables redundant transport modules and numeric mark spelling.
magicnet_dns_capture_normalize_rules() {
    awk '
        function number(v, n,i,c) {
            if (v !~ /^0x/) return v + 0
            n=0; for(i=3;i<=length(v);i++) { c=index("0123456789abcdef",tolower(substr(v,i,1)))-1; if(c<0) return v; n=n*16+c }
            return n
        }
        $1 == "-A" {
            out=""
            for(i=1;i<=NF;i++) {
                if ($i == "-m" && ($(i+1)=="tcp" || $(i+1)=="udp")) { i++; continue }
                value=$i
                if ($(i-1)=="--mark") { split(value,m,"/"); value=number(m[1]) "/" number(m[2]) }
                if (value == "\047!\047") value="!"
                out=out (out=="" ? "" : " ") value
            }
            print out
        }
    '
}

magicnet_dns_capture_expected_rules() (
    for _expected_proto in tcp udp; do
        printf '%s\n' "-A magicnet-dns-output -p $_expected_proto ! --dport 53 -j RETURN"
    done
    if [ "$_dns_capture_singbox_marked" -eq 1 ]; then
        printf '%s\n' "-A magicnet-dns-output -m mark --mark $_dns_capture_singbox_mark/$_dns_capture_singbox_mark -j RETURN"
    fi
    for _expected_uid in $_dns_capture_bypass_uids; do
        printf '%s\n' "-A magicnet-dns-output -m owner --uid-owner $_expected_uid -j RETURN"
    done
    for _expected_proto in udp tcp; do
        printf '%s\n' "-A magicnet-dns-output -p $_expected_proto --dport 53 -j REDIRECT --to-ports $_dns_capture_port"
    done
)

magicnet_dns_capture_family_current() (
    _current_cmd="$1"
    _current_rc=0
    _current_chain="$("$_current_cmd" -t nat -S magicnet-dns-output 2>/dev/null)" || _current_rc=$?
    case "$_current_rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
    _current_output="$("$_current_cmd" -t nat -S OUTPUT 2>/dev/null)" || return 2
    _current_chain="$(printf '%s\n' "$_current_chain" | magicnet_dns_capture_normalize_rules)"
    _expected_chain="$(magicnet_dns_capture_expected_rules | magicnet_dns_capture_normalize_rules)"
    [ "$_current_chain" = "$_expected_chain" ] || return 1
    # A core restart may have prepended its own DNAT. Membership is not order.
    printf '%s\n' "$_current_output" | awk '
        $1=="-A" { n++; if(n==1 && $0=="-A OUTPUT -j magicnet-dns-output") first=1 }
        /-j magicnet-dns-output( |$)/ { jumps++ }
        END { exit first && jumps==1 ? 0 : 1 }
    '
)

magicnet_dns_capture_install_family() (
    _install_cmd="$1"
    _install_current=0
    magicnet_dns_capture_family_current "$_install_cmd" || _install_current=$?
    case "$_install_current" in
    0) return 0 ;;
    1) ;;
    *) magicnet_warn "DNS capture inspection failed; refusing speculative firewall rewrite"; return 1 ;;
    esac
    # Detach only our jump before rebuilding; never expose a partially built
    # hooked chain or flush a system chain. Reattach after the recipe succeeds.
    magicnet_dns_capture_remove_output_jumps "$_install_cmd" || return 1
    if ! "$_install_cmd" -t nat -N magicnet-dns-output >/dev/null 2>&1; then
        magicnet_xtables_require "$_install_cmd" -t nat -L magicnet-dns-output -n || return 1
    fi
    magicnet_xtables_require "$_install_cmd" -t nat -F magicnet-dns-output || return 1
    _install_recipe="$(magicnet_dns_capture_expected_rules)" || return 1
    while IFS= read -r _install_rule; do
        # Every token is generated above from validated numeric configuration.
        set -f
        # shellcheck disable=SC2086
        set -- $_install_rule
        magicnet_xtables_require "$_install_cmd" -t nat "$@" || return 1
    done <<EOF
$_install_recipe
EOF
    magicnet_dns_capture_prepend_jump "$_install_cmd"
)

magicnet_enable_dns_capture() {
    _dns_capture_mode="$(magicnet_transparent_mode)" || {
        magicnet_warn "transparent mode configuration is invalid; DNS capture rejected"
        magicnet_disable_dns_capture >/dev/null 2>&1 || true
        return 1
    }
    if [ "$_dns_capture_mode" = ebpf ]; then
        # The eBPF inbound owns port 53 interception (local is always hijack).
        # Keep the legacy OUTPUT REDIRECT path detached to avoid double capture.
        magicnet_disable_dns_capture
        _dns_capture_mode_rc=$?
        unset _dns_capture_mode
        return "$_dns_capture_mode_rc"
    fi
    unset _dns_capture_mode
    if ! magicnet_dns_capture_enabled; then
        if magicnet_disable_dns_capture; then
            return 0
        fi
        magicnet_warn "Failed to remove stale DNS capture rules while DNS capture is disabled"
        return 1
    fi

    # All TUN DNS profiles need the local port-53 capture path. In particular,
    # Android netd commonly emits application DNS as UID 0 while tun-in excludes
    # UID 0. cloudflare-udp is proxy-detoured by dns.sh, so its upstream packets
    # do not need a profile-wide capture bypass and cannot recurse through 1053.
    _dns_capture_probe_rc=0
    magicnet_xtables_table_probe iptables nat || _dns_capture_probe_rc=$?
    case "$_dns_capture_probe_rc" in
    0) ;;
    2)
        [ "$(magicnet_ipv6_mode)" != prefer_ipv6 ] || return 1
        magicnet_warn "IPv4 nat unavailable; skipping kernel DNS capture and keeping sing-box TUN DNS only"
        return 0
        ;;
    *) return 1 ;;
    esac

    _dns_capture_port="$(magicnet_dns_capture_port)"
    _dns_capture_bypass_uids="$(magicnet_dns_capture_bypass_uids)"
    _dns_capture_singbox_mark="$(magicnet_dns_capture_singbox_mark)"
    _dns_capture_singbox_marked=0
    magicnet_dns_capture_singbox_udp_marked && _dns_capture_singbox_marked=1
    _dns_capture_rc=0
    _dns_capture_ipv6_unavailable=0
    magicnet_dns_capture_install_family magicnet_iptables_cmd || _dns_capture_rc=1

    _dns_capture_ipv6_mode="$(magicnet_ipv6_mode 2>/dev/null || printf '%s\n' prefer_ipv4)"
    if [ "$_dns_capture_ipv6_mode" != ipv4_only ]; then
        _dns_capture_probe_rc=0
        magicnet_xtables_table_probe ip6tables nat || _dns_capture_probe_rc=$?
        if [ "$_dns_capture_probe_rc" -ne 0 ]; then
            if [ "$_dns_capture_probe_rc" -ne 2 ] || [ "$_dns_capture_ipv6_mode" = prefer_ipv6 ]; then
                _dns_capture_rc=1
            else
                # Android kernels commonly expose ip6tables without an IPv6
                # nat table.  IPv4-first mode can still enforce its required
                # IPv4 capture path; do not turn that platform limitation into
                # a false global startup failure.
                _dns_capture_ipv6_unavailable=1
                magicnet_log "IPv6 nat unsupported; IPv6 kernel DNS capture not installed (IPv4-first policy)"
            fi
        else
            magicnet_dns_capture_install_family magicnet_ip6tables_cmd || _dns_capture_rc=1
        fi
    else
        magicnet_dns_capture_cleanup_family ip6tables || _dns_capture_rc=1
    fi

    if [ "$_dns_capture_rc" -ne 0 ]; then
        magicnet_disable_dns_capture >/dev/null 2>&1 || true
        unset _dns_capture_port _dns_capture_bypass_uids _dns_capture_bypass_uid _dns_capture_singbox_mark _dns_capture_singbox_marked
        unset _dns_capture_rc _dns_capture_probe_rc _dns_capture_ipv6_mode _dns_capture_ipv6_unavailable
        return 1
    fi

    if [ "$_dns_capture_ipv6_unavailable" -eq 1 ]; then
        magicnet_log "DNS capture redirected IPv4 port 53 to 127.0.0.1:${_dns_capture_port}; IPv6 nat unavailable"
    else
        magicnet_log "DNS capture redirected port 53 to 127.0.0.1:${_dns_capture_port}"
    fi
    unset _dns_capture_port _dns_capture_bypass_uids _dns_capture_bypass_uid _dns_capture_singbox_mark _dns_capture_singbox_marked
    unset _dns_capture_rc _dns_capture_probe_rc _dns_capture_ipv6_mode _dns_capture_ipv6_unavailable
}

magicnet_xtables_delete_rule() (
    _delete_cmd="$1"
    _delete_table="$2"
    shift 2
    _delete_attempt=0
    _delete_transient_retries=0
    while [ "$_delete_attempt" -lt 64 ]; do
        _delete_rc=0
        if [ -n "$_delete_table" ]; then
            _delete_error="$("$_delete_cmd" -t "$_delete_table" -D "$@" 2>&1 >/dev/null)" || _delete_rc=$?
        else
            _delete_error="$("$_delete_cmd" -D "$@" 2>&1 >/dev/null)" || _delete_rc=$?
        fi
        case "$_delete_rc" in 124 | 137 | 143) return 124 ;; esac
        _delete_write_rc=$_delete_rc
        _delete_rc=0
        if [ -n "$_delete_table" ]; then
            "$_delete_cmd" -t "$_delete_table" -C "$@" >/dev/null 2>&1 || _delete_rc=$?
        else
            "$_delete_cmd" -C "$@" >/dev/null 2>&1 || _delete_rc=$?
        fi
        case "$_delete_rc" in
        0)
            if [ "$_delete_write_rc" -ne 0 ]; then
                # Rule replacement can race a delete/check pair. Retry one
                # generic rc=1 failure, but never spin on permission/lock errors.
                if [ "$_delete_write_rc" -eq 1 ] && [ "$_delete_transient_retries" -eq 0 ]; then
                    _delete_transient_retries=1
                    continue
                fi
                magicnet_warn "$_delete_cmd delete failed (exit=$_delete_write_rc): $_delete_error"
                return 1
            fi
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

magicnet_dns_capture_cleanup_family() (
    _dns_capture_family="$1"
    _dns_capture_probe_rc=0
    magicnet_xtables_table_probe "$_dns_capture_family" nat || _dns_capture_probe_rc=$?
    case "$_dns_capture_probe_rc" in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    _dns_capture_cmd="magicnet_${_dns_capture_family}_cmd"
    _dns_capture_chain_rc=0
    "$_dns_capture_cmd" -t nat -L magicnet-dns-output -n >/dev/null 2>&1 || _dns_capture_chain_rc=$?
    case "$_dns_capture_chain_rc" in
    0)
        # Never flush a chain while a failed detach may still send traffic into it.
        magicnet_dns_capture_remove_output_jumps "$_dns_capture_cmd" || return 1
        magicnet_xtables_require "$_dns_capture_cmd" -t nat -F magicnet-dns-output || return 1
        magicnet_xtables_require "$_dns_capture_cmd" -t nat -X magicnet-dns-output
        ;;
    # The table was readable; Android variants use 1 or 2 for no chain.
    1 | 2) return 0 ;;
    *) return 1 ;;
    esac
)

magicnet_disable_dns_capture() (
    _dns_capture_cleanup_rc=0
    for _dns_capture_family in iptables ip6tables; do
        magicnet_dns_capture_cleanup_family "$_dns_capture_family" || _dns_capture_cleanup_rc=1
    done
    return "$_dns_capture_cleanup_rc"
)

# Stop is fail-open for device connectivity: remove every MagicNet-owned route
# and DNS rule while the core can still serve traffic. A transient xtables or
# policy-routing lock is retried here instead of forcing the user to repeat the
# lifecycle action. Persistent cleanup failure must abort the core stop.
magicnet_prepare_network_for_core_stop() (
    _stop_cleanup_attempts="${MAGICNET_STOP_CLEANUP_ATTEMPTS:-3}"
    _stop_cleanup_delay="${MAGICNET_STOP_CLEANUP_DELAY:-1}"
    case "$_stop_cleanup_attempts" in
    '' | *[!0-9]* | 0) _stop_cleanup_attempts=3 ;;
    esac
    [ "$_stop_cleanup_attempts" -le 10 ] || _stop_cleanup_attempts=10
    case "$_stop_cleanup_delay" in
    '' | *[!0-9]*) _stop_cleanup_delay=1 ;;
    esac
    [ "$_stop_cleanup_delay" -le 5 ] || _stop_cleanup_delay=5

    # Lifecycle callers quiesce supervisors before entering this function.
    # Re-scanning short-lived shell watcher processes here introduces a /proc
    # TOCTOU and can falsely reject an otherwise safe cleanup.
    _stop_cleanup_attempt=1
    while [ "$_stop_cleanup_attempt" -le "$_stop_cleanup_attempts" ]; do
        _stop_cleanup_rc=0
        magicnet_hotspot_route_cleanup || _stop_cleanup_rc=1
        magicnet_disable_dns_capture || _stop_cleanup_rc=1
        magicnet_disable_dns_leak_guard || _stop_cleanup_rc=1
        if [ "$_stop_cleanup_rc" -eq 0 ]; then
            return 0
        fi
        if [ "$_stop_cleanup_attempt" -lt "$_stop_cleanup_attempts" ]; then
            magicnet_warn "Network cleanup before core stop failed; retrying (${_stop_cleanup_attempt}/${_stop_cleanup_attempts})."
            [ "$_stop_cleanup_delay" -eq 0 ] || sleep "$_stop_cleanup_delay"
        fi
        _stop_cleanup_attempt=$((_stop_cleanup_attempt + 1))
    done

    magicnet_warn "Network cleanup before core stop failed; keeping sing-box running to avoid breaking connectivity."
    return 1
)

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
                for _delete_family_style in tagged legacy; do
                    set -- OUTPUT -o "$_delete_family_iface" -p "$_delete_family_proto" --dport "$_delete_family_port"
                    if [ "$_delete_family_style" = tagged ]; then
                        set -- "$@" -m comment --comment magicnet-dns-guard
                    else
                        case " ${MAGICNET_DNS_GUARD_LEGACY_IFACES:-} " in
                        *" $_delete_family_iface "*) ;;
                        *) continue ;;
                        esac
                    fi
                    _delete_family_rc=0
                    magicnet_dns_leak_guard_delete_rule "$_delete_family_cmd" "$@" -j REJECT || _delete_family_rc=$?
                    case "$_delete_family_rc" in
                    0) ;;
                    124) return 124 ;;
                    *) _delete_family_result=1 ;;
                    esac
                done
            done
        done
    done
    return "$_delete_family_result"
)

magicnet_dns_leak_guard_rule_ifaces() (
    _dns_guard_scan_cmd="$1"
    _dns_guard_scan_rc=0
    _dns_guard_scan_rules="$(LC_ALL=C "$_dns_guard_scan_cmd" -S OUTPUT 2>&1)" || _dns_guard_scan_rc=$?
    if [ "$_dns_guard_scan_rc" -ne 0 ]; then
        case "$_dns_guard_scan_rules" in
        *"Table does not exist"* | *"Address family not supported"*) return 76 ;;
        esac
        return "$_dns_guard_scan_rc"
    fi
    # New rules have an explicit owner. Legacy unlabelled rules may be removed
    # only on interfaces in the pre-upgrade ownership journal, never on an
    # interface inferred from a current physical link or another owner's rule.
    printf '%s\n' "$_dns_guard_scan_rules" | awk -v legacy="${MAGICNET_DNS_GUARD_LEGACY_IFACES:-}" '
        BEGIN { n = split(legacy, names, /[[:space:]]+/); for (i=1; i<=n; i++) owned[names[i]]=1 }
        $1 == "-A" && $2 == "OUTPUT" {
            iface = proto = port = target = owner = ""
            for (i=3; i<=NF; i++) {
                if ($i == "-o" && i<NF) iface=$(i+1)
                if ($i == "-p" && i<NF) proto=$(i+1)
                if ($i == "--dport" && i<NF) port=$(i+1)
                if ($i == "-j" && i<NF) target=$(i+1)
                if ($i == "--comment" && i<NF) { owner=$(i+1); gsub(/"/, "", owner) }
            }
            if (iface ~ /^[[:alnum:]_.-]+$/ && target == "REJECT" &&
                (proto == "udp" || proto == "tcp") && (port == "53" || port == "853") &&
                (owner == "magicnet-dns-guard" || (owner == "" && owned[iface])) && !seen[iface]++) print iface
        }
    '
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
        if magicnet_cmd_exists ip6tables && magicnet_ip6tables_cmd -L -n >/dev/null 2>&1; then
            _dns_guard_ipv6_available=1
        elif [ "$_dns_guard_ipv6_mode" = prefer_ipv6 ]; then
            _dns_guard_rc=1
        else
            magicnet_warn "IPv6 DNS leak guard unavailable; continuing with IPv4-first guard"
        fi
    fi
    # Record ownership before the first write, so partial failures remain
    # recoverable. This is private recovery evidence, not canonical success.
    _dns_guard_state_file="$(magicnet_dns_leak_guard_state_file)"
    _dns_guard_state_tmp="${_dns_guard_state_file}.new.$$"
    if ! mkdir -p "${_dns_guard_state_file%/*}" ||
        ! (umask 077; printf '%s\n' "$_dns_guard_ifaces" '# magicnet-owned-v2' >"$_dns_guard_state_tmp") ||
        ! mv -f "$_dns_guard_state_tmp" "$_dns_guard_state_file"; then
        rm -f "$_dns_guard_state_tmp" 2>/dev/null || true
        magicnet_warn "DNS guard ownership could not be staged; no rules installed"
        return 1
    fi
    for _dns_guard_iface in $_dns_guard_ifaces; do
        for _dns_guard_port in 53 853; do
            magicnet_iptables_ensure OUTPUT -o "$_dns_guard_iface" -p udp --dport "$_dns_guard_port" -m comment --comment magicnet-dns-guard -j REJECT || _dns_guard_rc=1
            magicnet_iptables_ensure OUTPUT -o "$_dns_guard_iface" -p tcp --dport "$_dns_guard_port" -m comment --comment magicnet-dns-guard -j REJECT || _dns_guard_rc=1
            if [ "$_dns_guard_ipv6_available" -eq 1 ]; then
                magicnet_ip6tables_ensure OUTPUT -o "$_dns_guard_iface" -p udp --dport "$_dns_guard_port" -m comment --comment magicnet-dns-guard -j REJECT || _dns_guard_rc=1
                magicnet_ip6tables_ensure OUTPUT -o "$_dns_guard_iface" -p tcp --dport "$_dns_guard_port" -m comment --comment magicnet-dns-guard -j REJECT || _dns_guard_rc=1
            fi
        done
    done

    if [ "$_dns_guard_rc" -ne 0 ]; then
        magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
        unset _dns_guard_ifaces _dns_guard_iface _dns_guard_port
        unset _dns_guard_rc _dns_guard_ipv6_mode _dns_guard_ipv6_available
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
    _cleanup_state="$(magicnet_dns_leak_guard_state_file)"
    _cleanup_saved=
    MAGICNET_DNS_GUARD_LEGACY_IFACES=
    if [ -e "$_cleanup_state" ]; then
        [ -f "$_cleanup_state" ] && [ -r "$_cleanup_state" ] || return 1
        _cleanup_saved="$(awk '/^[[:alnum:]_.-]+$/ { print }' "$_cleanup_state")" || return 1
        if ! grep -Fqx '# magicnet-owned-v2' "$_cleanup_state"; then
            MAGICNET_DNS_GUARD_LEGACY_IFACES="$(printf '%s\n' "$_cleanup_saved" | tr '\n' ' ')"
        fi
    fi
    export MAGICNET_DNS_GUARD_LEGACY_IFACES
    _cleanup_result=0
    for _cleanup_family in iptables ip6tables; do
        magicnet_cmd_exists "$_cleanup_family" || continue
        _cleanup_scan_rc=0
        _cleanup_ifaces="$(magicnet_dns_leak_guard_rule_ifaces "magicnet_${_cleanup_family}_cmd")" || _cleanup_scan_rc=$?
        case "$_cleanup_scan_rc" in
        0) ;;
        76) continue ;; # Explicit absent-filter/family result, not raw exit 3.
        124 | 137 | 143) return 1 ;;
        *)
            # A failed read cannot prove absence. Known ownership may be used
            # for a bounded cleanup, but never guessed physical interfaces.
            [ -n "$_cleanup_saved" ] || return 1
            _cleanup_ifaces="$_cleanup_saved"
            ;;
        esac
        _cleanup_rc=0
        magicnet_dns_leak_guard_delete_family "magicnet_${_cleanup_family}_cmd" "$_cleanup_ifaces" || _cleanup_rc=$?
        case "$_cleanup_rc" in
        124) return 1 ;;
        0) ;;
        *) _cleanup_result=1 ;;
        esac
        # If the listing was unreadable, retain the journal for reconciliation
        # even when individual -C checks suggest the known rules disappeared.
        [ "$_cleanup_scan_rc" -eq 0 ] || _cleanup_result=1
    done
    [ "$_cleanup_result" -eq 0 ] || return 1
    rm -f "$_cleanup_state" 2>/dev/null
)

magicnet_after_kernel_start_unlocked() {
    # Configuration is fully materialized before sing-box snapshots it.  The
    # synchronous post-start phase now installs only kernel state that requires
    # magicnet0 to exist, avoiding a second round of jq rewrites and config-lock
    # waits after the core is already healthy.
    magicnet_after_kernel_start_deferred_unlocked
    _after_result=$?
    if [ "$_after_result" -ne 0 ]; then
        magicnet_warn "Post-start network initialization failed; DNS rule cleanup was attempted."
    fi
    set -- "$_after_result"
    unset _after_result
    return "$1"
}

magicnet_after_kernel_start() {
    magicnet_after_kernel_start_unlocked
}

magicnet_after_kernel_start_deferred_unlocked() {
    # TUN installs table 2022 rules; eBPF only removes stale TUN rules because
    # shared-network TC is attached by sing-box itself.
    magicnet_hotspot_reconcile ||
        magicnet_warn "Hotspot TUN policy is not ready; the interface watcher will retry it."

    _deferred_attempts="${MAGICNET_START_NETWORK_ATTEMPTS:-3}"
    _deferred_delay="${MAGICNET_START_NETWORK_DELAY:-1}"
    case "$_deferred_attempts" in
    '' | *[!0-9]* | 0) _deferred_attempts=3 ;;
    esac
    [ "$_deferred_attempts" -le 10 ] || _deferred_attempts=10
    case "$_deferred_delay" in
    '' | *[!0-9]*) _deferred_delay=1 ;;
    esac
    [ "$_deferred_delay" -le 5 ] || _deferred_delay=5

    _deferred_attempt=1
    while [ "$_deferred_attempt" -le "$_deferred_attempts" ]; do
        _deferred_failures=
        if ! magicnet_enable_dns_capture; then
            _deferred_failures=dns-capture
        fi
        if ! magicnet_enable_dns_leak_guard; then
            _deferred_failures="${_deferred_failures}${_deferred_failures:+,}dns-leak-guard"
        fi
        if [ -z "$_deferred_failures" ]; then
            unset _deferred_attempts _deferred_delay _deferred_attempt _deferred_failures
            return 0
        fi

        _deferred_failure_names="$_deferred_failures"
        magicnet_disable_dns_capture || true
        magicnet_disable_dns_leak_guard || true
        if [ "$_deferred_attempt" -lt "$_deferred_attempts" ]; then
            magicnet_warn "Post-start network controls failed (${_deferred_failure_names}); retrying (${_deferred_attempt}/${_deferred_attempts})."
            [ "$_deferred_delay" -eq 0 ] || sleep "$_deferred_delay"
        fi
        _deferred_attempt=$((_deferred_attempt + 1))
    done

    magicnet_warn "Post-start network controls failed: $_deferred_failure_names"
    unset _deferred_attempts _deferred_delay _deferred_attempt _deferred_failures _deferred_failure_names
    return 1
}