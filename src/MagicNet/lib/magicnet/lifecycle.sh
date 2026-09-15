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
    # Keep the cleanup range deliberately bounded around sing-box's configured
    # rule start. Hotspot rules are tracked separately and are never swept by
    # this range.
    printf '%s\n' 9099
}

magicnet_kernel_route_fallback_rule() {
    printf '%s\n' 32768
}

magicnet_kernel_route_state_file() {
    printf '%s\n' "${MODDIR}/.state/network/kernel-route-table.state"
}

magicnet_kernel_route_state_capture() (
    _route_mode="$(magicnet_transparent_mode 2>/dev/null || true)"
    _route_state="$(magicnet_kernel_route_state_file)"

    if [ "$_route_mode" != tun ]; then
        rm -f "$_route_state" 2>/dev/null || true
        return 0
    fi

    if magicnet_kernel_running; then
        _route_kernel_rc=0
    else
        _route_kernel_rc=$?
    fi
    [ "$_route_kernel_rc" -eq 0 ] || return "$_route_kernel_rc"

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

magicnet_kernel_route_rule_present() {
    _route_family="$1"
    _route_priority="$2"
    _route_table="$3"
    case "$_route_family" in
    4) _route_rules="$(ip rule show 2>/dev/null)" || return 1 ;;
    6) _route_rules="$(ip -6 rule show 2>/dev/null)" || return 1 ;;
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
    _route_rc=$?
    unset _route_family _route_priority _route_table _route_rules
    return "$_route_rc"
}

magicnet_kernel_route_delete_rule_priority() {
    _route_family="$1"
    _route_priority="$2"
    _route_table="$3"
    _route_attempt=0
    while [ "$_route_attempt" -lt 8 ] &&
        magicnet_kernel_route_rule_present "$_route_family" "$_route_priority" "$_route_table"; do
        case "$_route_family" in
        4) ip rule del priority "$_route_priority" >/dev/null 2>&1 || break ;;
        6) ip -6 rule del priority "$_route_priority" >/dev/null 2>&1 || break ;;
        esac
        _route_attempt=$((_route_attempt + 1))
    done
    if magicnet_kernel_route_rule_present "$_route_family" "$_route_priority" "$_route_table"; then
        _route_delete_rc=1
    else
        _route_delete_rc=0
    fi
    unset _route_family _route_priority _route_table _route_attempt
    return "$_route_delete_rc"
}

magicnet_kernel_route_cleanup_rule_family() {
    _route_family="$1"
    _route_table="$2"
    _route_start="$(magicnet_kernel_route_rule_start)"
    _route_end="$(magicnet_kernel_route_rule_end)"
    _route_fallback="$(magicnet_kernel_route_fallback_rule)"

    case "$_route_family" in
    4) ip rule show >/dev/null 2>&1 || return 0 ;;
    6) ip -6 rule show >/dev/null 2>&1 || return 0 ;;
    *) return 1 ;;
    esac

    _route_priority="$_route_start"
    _route_cleanup_rc=0
    while [ "$_route_priority" -le "$_route_end" ]; do
        magicnet_kernel_route_delete_rule_priority \
            "$_route_family" "$_route_priority" "$_route_table" || _route_cleanup_rc=1
        _route_priority=$((_route_priority + 1))
    done
    magicnet_kernel_route_delete_rule_priority \
        "$_route_family" "$_route_fallback" "$_route_table" || _route_cleanup_rc=1

    _route_result="$_route_cleanup_rc"
    unset _route_family _route_table _route_start _route_end _route_fallback
    unset _route_priority _route_cleanup_rc
    return "$_route_result"
}

magicnet_kernel_route_cleanup_orphan_hotspot_rules() (
    _route_table="$1"
    _route_rules="$(ip rule show 2>/dev/null)" || return 0
    printf '%s\n' "$_route_rules" | awk -v expected_table="$_route_table" '
        $1 ~ /^[0-9]+:$/ {
            priority = $1
            sub(/:$/, "", priority)
            iface = ""
            table = ""
            for (i = 2; i <= NF; i++) {
                if ($i == "iif" && i < NF) iface = $(i + 1)
                if ($i == "lookup" && i < NF) table = $(i + 1)
            }
            if (iface != "" && table == expected_table) print priority "|" iface
        }
    ' | while IFS='|' read -r _route_priority _route_iface; do
        magicnet_hotspot_interface_allowed "$_route_iface" || continue
        magicnet_hotspot_delete_rule "$_route_priority" "$_route_iface" || exit 1
    done
)

magicnet_kernel_route_flush_family() {
    _route_family="$1"
    _route_table="$2"
    case "$_route_family" in
    4)
        ip route show table "$_route_table" >/dev/null 2>&1 || return 0
        ip route flush table "$_route_table" >/dev/null 2>&1
        ;;
    6)
        ip -6 route show table "$_route_table" >/dev/null 2>&1 || return 0
        ip -6 route flush table "$_route_table" >/dev/null 2>&1
        ;;
    *) return 1 ;;
    esac
}

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
    magicnet_kernel_route_cleanup_orphan_hotspot_rules "$_route_table" || _route_cleanup_rc=1

    if [ "$_route_owned" -eq 1 ]; then
        magicnet_kernel_route_cleanup_rule_family 4 "$_route_table" || _route_cleanup_rc=1
        magicnet_kernel_route_cleanup_rule_family 6 "$_route_table" || _route_cleanup_rc=1
        magicnet_kernel_route_flush_family 4 "$_route_table" || _route_cleanup_rc=1
        magicnet_kernel_route_flush_family 6 "$_route_table" || _route_cleanup_rc=1
    else
        # Upgrade/crash compatibility: without an ownership marker, only touch
        # routes that still point at MagicNet's own TUN device.
        if magicnet_iface_exists magicnet0; then
            ip route flush table "$_route_table" dev magicnet0 >/dev/null 2>&1 || _route_cleanup_rc=1
            ip -6 route flush table "$_route_table" dev magicnet0 >/dev/null 2>&1 || true
        fi
    fi

    if [ "$_route_cleanup_rc" -eq 0 ]; then
        rm -f "$_route_state" 2>/dev/null || true
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
