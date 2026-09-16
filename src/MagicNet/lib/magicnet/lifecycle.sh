# shellcheck shell=ash
#
# Kernel lifecycle ownership for MagicNet-managed routing state.
#
# sing-box owns the TUN route table while the managed core is alive. MagicNet
# adds hotspot policy rules that point at the same table. Keep both sides tied
# to the core lifecycle so a stopped core never leaves traffic routed into a
# dead table.

magicnet_kernel_route_table() {
    printf '%s\n' 2022
}

magicnet_kernel_route_rule_start() {
    printf '%s\n' 9000
}

magicnet_kernel_route_rule_end() {
    # sing-box allocates its auto-route rules from 9000. Keep cleanup bounded
    # to MagicNet's reserved window; hotspot rules are tracked separately.
    printf '%s\n' 9099
}

magicnet_kernel_route_fallback_rule() {
    printf '%s\n' 32768
}

magicnet_kernel_route_state_file() {
    printf '%s\n' "${MODDIR}/.state/network/kernel-route-table.state"
}

# Override routes.sh's readiness probe with an explicit core-liveness gate.
# A stale magicnet0 interface/table after a crash must never be enough to make
# `hotspot reconcile` install new policy rules while the kernel is stopped.
magicnet_hotspot_tun_route_table_ready() (
    if magicnet_kernel_running; then
        _route_kernel_rc=0
    else
        _route_kernel_rc=$?
    fi
    [ "$_route_kernel_rc" -eq 0 ] || return "$_route_kernel_rc"

    magicnet_iface_exists magicnet0 || return 1
    _route_table="$(magicnet_kernel_route_table)"
    _route_live="$(ip route show table "$_route_table" 2>/dev/null)" || return 2
    printf '%s\n' "$_route_live" | awk '
        index($0, "dev magicnet0") > 0 { found = 1 }
        END { exit found ? 0 : 1 }
    '
)

magicnet_kernel_route_state_capture() (
    _route_mode="$(magicnet_transparent_mode 2>/dev/null || true)"
    _route_state="$(magicnet_kernel_route_state_file)"

    case "$_route_mode" in
    tun) ;;
    ebpf)
        # Mode intent is not proof that old TUN resources were removed.
        [ ! -e "$_route_state" ] || return 1
        return 0 ;;
    *) return 2 ;;
    esac

    if magicnet_kernel_running; then
        _route_kernel_rc=0
    else
        _route_kernel_rc=$?
    fi
    [ "$_route_kernel_rc" -eq 0 ] || return "$_route_kernel_rc"

    # Do not claim table ownership merely because the process is alive. The
    # table must be materialized by this generation and point at magicnet0.
    magicnet_hotspot_tun_route_table_ready || return $?

    _route_state_dir="${_route_state%/*}"
    _route_state_tmp="${_route_state}.new.$$"
    mkdir -p "$_route_state_dir" || return 1
    if ! (
        umask 077
        printf 'table=%s\n' "$(magicnet_kernel_route_table)"
        printf 'rule_start=%s\n' "$(magicnet_kernel_route_rule_start)"
        printf 'rule_end=%s\n' "$(magicnet_kernel_route_rule_end)"
        printf 'fallback_rule=%s\n' "$(magicnet_kernel_route_fallback_rule)"
        printf 'interface=magicnet0\n'
    ) >"$_route_state_tmp" || ! mv -f "$_route_state_tmp" "$_route_state"; then
        rm -f "$_route_state_tmp" 2>/dev/null || true
        return 1
    fi
)

magicnet_kernel_route_rule_present() (
    _route_family="$1"
    _route_priority="$2"
    _route_table="$3"
    case "$_route_family" in
    4) _route_rules="$(ip rule show 2>/dev/null)" || return 2 ;;
    6) _route_rules="$(ip -6 rule show 2>/dev/null)" || return 2 ;;
    *) return 1 ;;
    esac
    printf '%s\n' "$_route_rules" | awk \
        -v expected_priority="${_route_priority}:" \
        -v expected_table="$_route_table" '
        $1 == expected_priority {
            for (i = 2; i <= NF; i++) {
                if ($i == "lookup" && i < NF && $(i + 1) == expected_table) found = 1
            }
        }
        END { exit found ? 0 : 1 }
    '
)

magicnet_kernel_route_delete_rule_priority() (
    _route_family="$1"
    _route_priority="$2"
    _route_table="$3"
    _route_attempt=0
    while [ "$_route_attempt" -lt 8 ]; do
        _route_present_rc=0
        magicnet_kernel_route_rule_present "$_route_family" "$_route_priority" "$_route_table" || _route_present_rc=$?
        case "$_route_present_rc" in 0) ;; 1) return 0 ;; *) return 2 ;; esac
        case "$_route_family" in
        4) ip rule del priority "$_route_priority" lookup "$_route_table" >/dev/null 2>&1 || return 1 ;;
        6) ip -6 rule del priority "$_route_priority" lookup "$_route_table" >/dev/null 2>&1 || return 1 ;;
        *) return 1 ;;
        esac
        _route_attempt=$((_route_attempt + 1))
    done
    _route_present_rc=0
    magicnet_kernel_route_rule_present "$_route_family" "$_route_priority" "$_route_table" || _route_present_rc=$?
    [ "$_route_present_rc" -eq 1 ]

)

magicnet_kernel_route_cleanup_rule_family() (
    _route_family="$1"
    _route_table="$2"
    _route_start="$(magicnet_kernel_route_rule_start)"
    _route_end="$(magicnet_kernel_route_rule_end)"
    _route_fallback="$(magicnet_kernel_route_fallback_rule)"

    case "$_route_family" in
    4) _route_rules="$(ip rule show 2>/dev/null)" || return 2 ;;
    6) _route_rules="$(ip -6 rule show 2>/dev/null)" || return 2 ;;
    *) return 1 ;;
    esac

    _route_priorities="$(printf '%s\n' "$_route_rules" | awk \
        -v expected_table="$_route_table" \
        -v range_start="$_route_start" \
        -v range_end="$_route_end" \
        -v fallback="$_route_fallback" '
        $1 ~ /^[0-9]+:$/ {
            priority = $1
            sub(/:$/, "", priority)
            table = ""
            for (i = 2; i <= NF; i++) {
                if ($i == "lookup" && i < NF) table = $(i + 1)
            }
            if (table == expected_table &&
                ((priority + 0 >= range_start + 0 && priority + 0 <= range_end + 0) ||
                 priority + 0 == fallback + 0) && !seen[priority]++) {
                print priority
            }
        }
    ')"

    _route_cleanup_rc=0
    while IFS= read -r _route_priority; do
        [ -n "$_route_priority" ] || continue
        magicnet_kernel_route_delete_rule_priority \
            "$_route_family" "$_route_priority" "$_route_table" || _route_cleanup_rc=1
    done <<EOF
$_route_priorities
EOF
    return "$_route_cleanup_rc"
)

# Return 2 for an unreadable table, not an empty one. Only an explicit
# kernel "table absent" diagnostic is treated as absence.
magicnet_kernel_route_read_family() (
    case "$1" in 4) set -- ip route show table "$2" ;; 6) set -- ip -6 route show table "$2" ;; *) return 2 ;; esac
    _route_read_rc=0
    _route_read="$(LC_ALL=C "$@" 2>&1)" || _route_read_rc=$?
    if [ "$_route_read_rc" -eq 0 ]; then printf '%s\n' "$_route_read"; return 0; fi
    case "$_route_read" in *"FIB table does not exist"*) return 0 ;; esac
    return 2
)

magicnet_kernel_route_flush_family() (
    _route_family="$1"
    _route_table="$2"
    _route_rows="$(magicnet_kernel_route_read_family "$_route_family" "$_route_table")" || return 2
    printf '%s\n' "$_route_rows" | grep -Eq '(^| )dev magicnet0( |$)' || return 0
    # A stale marker never owns foreign routes added to the same table later.
    case "$_route_family" in
    4) ip route flush table "$_route_table" dev magicnet0 >/dev/null 2>&1 || return 1 ;;
    6) ip -6 route flush table "$_route_table" dev magicnet0 >/dev/null 2>&1 || return 1 ;;
    *) return 1 ;;
    esac
    _route_rows="$(magicnet_kernel_route_read_family "$_route_family" "$_route_table")" || return 2
    if printf '%s\n' "$_route_rows" | grep -Eq '(^| )dev magicnet0( |$)'; then return 1; fi
    return 0
)

magicnet_kernel_route_cleanup_after_stop() (
    if magicnet_kernel_running; then
        magicnet_warn "Refusing to remove the MagicNet route table while the core is still running."
        return 1
    else
        _route_kernel_rc=$?
    fi
    case "$_route_kernel_rc" in
    1) ;;
    *)
        magicnet_warn "Kernel state is indeterminate; route-table cleanup was not attempted."
        return 2
        ;;
    esac

    _route_table="$(magicnet_kernel_route_table)"
    _route_state="$(magicnet_kernel_route_state_file)"
    _route_owned=0
    if [ -f "$_route_state" ] &&
        grep -Fqx "table=$_route_table" "$_route_state" 2>/dev/null &&
        grep -Fqx 'interface=magicnet0' "$_route_state" 2>/dev/null; then
        _route_owned=1
    fi

    _route_cleanup_rc=0
    # The state-file cleanup is the normal path. The orphan scan also catches
    # interrupted state publication without deleting unrelated policy rules.
    magicnet_hotspot_route_cleanup || _route_cleanup_rc=1
    # No speculative orphan deletion: a matching iif/table is not ownership.

    if [ "$_route_owned" -eq 1 ]; then
        for _route_family in 4 6; do
            _route_rows="$(magicnet_kernel_route_read_family "$_route_family" "$_route_table")" || return 2
            if printf '%s\n' "$_route_rows" | awk 'NF && $0 !~ /(^| )dev magicnet0( |$)/ { foreign=1 } END { exit foreign ? 0 : 1 }'; then
                magicnet_warn "Route table contains unowned entries; preserving policy rules and ownership evidence."
                return 2
            fi
        done
        # Preflight both policy families before any destructive cleanup. A
        # permission failure must not leave a rule pointing into a flushed table.
        ip rule show >/dev/null 2>&1 && ip -6 rule show >/dev/null 2>&1 || return 2
        magicnet_kernel_route_cleanup_rule_family 4 "$_route_table" || _route_cleanup_rc=1
        magicnet_kernel_route_cleanup_rule_family 6 "$_route_table" || _route_cleanup_rc=1
        magicnet_kernel_route_flush_family 4 "$_route_table" || _route_cleanup_rc=1
        magicnet_kernel_route_flush_family 6 "$_route_table" || _route_cleanup_rc=1
    else
        # Upgrade/crash compatibility: without an ownership marker, only touch
        # routes that still point at MagicNet's own TUN device.
        if magicnet_iface_exists magicnet0; then
            magicnet_kernel_route_flush_family 4 "$_route_table" || _route_cleanup_rc=1
            magicnet_kernel_route_flush_family 6 "$_route_table" || _route_cleanup_rc=1
        fi
    fi

    if [ "$_route_cleanup_rc" -eq 0 ]; then
        rm -f "$_route_state" 2>/dev/null || _route_cleanup_rc=1
    fi
    return "$_route_cleanup_rc"
)

magicnet_lifecycle_after_start() {
    # Core readiness is the commit point for kernel routing ownership. The
    # route table must never be marked as active before sing-box has started.
    if ! magicnet_kernel_route_state_capture; then
        magicnet_warn "Failed to record MagicNet route-table ownership."
    fi
    magicnet_refresh_status ||
        magicnet_warn "Failed to synchronize the module description after core start."
    return 0
}

magicnet_lifecycle_after_stop() {
    _lifecycle_stop_rc=0
    magicnet_kernel_route_cleanup_after_stop || _lifecycle_stop_rc=$?
    magicnet_refresh_status ||
        magicnet_warn "Failed to synchronize the module description after core stop."
    _lifecycle_result="$_lifecycle_stop_rc"
    unset _lifecycle_stop_rc
    return "$_lifecycle_result"
}

magicnet_lifecycle_sync() {
    if magicnet_kernel_running; then
        _lifecycle_kernel_rc=0
    else
        _lifecycle_kernel_rc=$?
    fi
    case "$_lifecycle_kernel_rc" in
    0)
        unset _lifecycle_kernel_rc
        magicnet_lifecycle_after_start
        ;;
    1)
        unset _lifecycle_kernel_rc
        magicnet_lifecycle_after_stop
        ;;
    *)
        _lifecycle_result="$_lifecycle_kernel_rc"
        unset _lifecycle_kernel_rc
        return "$_lifecycle_result"
        ;;
    esac
}
