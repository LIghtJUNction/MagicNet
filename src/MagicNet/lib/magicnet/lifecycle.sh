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
    _route_output="$(ip route show table "$_route_table" 2>/dev/null)" || return 2
    printf '%s\n' "$_route_output" | awk '
        { for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == "magicnet0") found = 1 }
        END { exit !found }
    '
)

# Called while the lifecycle lock is held and BEFORE starting a new core.
# A pre-existing rule is not ours merely because it uses the same table/index.
magicnet_kernel_route_state_begin() (
    _mode="$(magicnet_transparent_mode)" || return 2
    case "$_mode" in ebpf | tun) ;; *) return 2 ;; esac
    if magicnet_kernel_running; then return 2; else _rc=$?; fi
    [ "$_rc" -eq 1 ] || return 2
    _state="$(magicnet_kernel_route_state_file)"
    if [ -e "$_state" ]; then
        magicnet_kernel_route_cleanup_after_stop || return 2
    fi
    [ "$_mode" != ebpf ] || return 0
    _rules4="$(magicnet_kernel_route_rules 4)" || return 2
    _rules6="$(magicnet_kernel_route_rules 6)" || return 2
    magicnet_kernel_route_state_write prepared "$_rules4" "$_rules6"
)

magicnet_kernel_route_state_write() (
    _state="$(magicnet_kernel_route_state_file)"
    _tmp="${_state}.new.$$"
    _boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || return 2
    umask 077
    mkdir -p "${_state%/*}" || return 1
    if ! {
        printf 'schema=2\nphase=%s\nboot=%s\n' "$1" "$_boot"
        printf 'table=2022\ninterface=magicnet0\n'
        printf '%s\n' "$2" | sed '/^$/d; s/^/rule4=/'
        printf '%s\n' "$3" | sed '/^$/d; s/^/rule6=/'
    } >"$_tmp" || ! mv -f "$_tmp" "$_state"; then
        rm -f "$_tmp"
        return 1
    fi
)

magicnet_kernel_route_new_rules() (
    _family="$1"
    _state="$(magicnet_kernel_route_state_file)"
    _before="$(sed -n "s/^rule${_family}=//p" "$_state")" || return 2
    _after="$(magicnet_kernel_route_rules "$_family")" || return 2
    while IFS= read -r _rule; do
        [ -n "$_rule" ] || continue
        # An identical pre-existing rule remains foreign; never adopt it.
        printf '%s\n' "$_before" | grep -Fqx -- "$_rule" || printf '%s\n' "$_rule"
    done <<EOF
$_after
EOF
)

magicnet_kernel_route_state_capture() (
    _mode="$(magicnet_transparent_mode)" || return 2
    case "$_mode" in ebpf) return 0 ;; tun) ;; *) return 2 ;; esac
    magicnet_hotspot_tun_route_table_ready || return $?
    _state="$(magicnet_kernel_route_state_file)"
    # No pre-start evidence: do not manufacture ownership from current state.
    [ -f "$_state" ] && [ ! -L "$_state" ] || return 2
    _boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || return 2
    grep -Fqx 'schema=2' "$_state" && grep -Fqx "boot=$_boot" "$_state" || return 2
    if grep -Fqx 'phase=active' "$_state"; then return 0; fi
    grep -Fqx 'phase=prepared' "$_state" || return 2
    _rules4="$(magicnet_kernel_route_new_rules 4)" || return 2
    _rules6="$(magicnet_kernel_route_new_rules 6)" || return 2
    magicnet_kernel_route_state_write active "$_rules4" "$_rules6"
)

# A bounded private recovery ledger records full selectors, not ownership of
# every rule sharing a priority/table number. It is never a public status API.
magicnet_kernel_route_rules() (
    case "$1" in
    4) _rules="$(ip rule show 2>/dev/null)" || return 2 ;;
    6)
        # No IPv6 stack means no IPv6 policy resources can exist.
        [ -e /proc/net/if_inet6 ] || return 0
        _rules="$(ip -6 rule show 2>/dev/null)" || return 2
        ;;
    *) return 2 ;;
    esac
    [ "${#_rules}" -le 65536 ] || return 2
    printf '%s\n' "$_rules" | awk '
        $1 ~ /^[0-9]+:$/ {
            priority = $1; sub(/:$/, "", priority)
            table = ""
            for (i = 2; i < NF; i++) if ($i == "lookup") table = $(i + 1)
            if (table == "2022" && ((priority >= 9000 && priority <= 9099) || priority == 32768)) {
                $1 = $1; print
            }
        }
    '
)

magicnet_kernel_route_delete_exact_rule() (
    _family="$1"
    _record="$2"
    # No eval, expansion of filenames, shell syntax or arbitrary table selection.
    case "$_record" in '' | *[!a-zA-Z0-9_.,:/\ -]*) return 2 ;; esac
    _current="$(magicnet_kernel_route_rules "$_family")" || return 2
    printf '%s\n' "$_current" | grep -Fqx -- "$_record" || return 0
    _before="$(printf '%s\n' "$_current" | grep -Fxc -- "$_record")"
    # Netlink treats omitted/zero-valued selectors as wildcards when deleting.
    # Full printed tokens alone cannot disambiguate a second rule at this index.
    _priority="${_record%%:*}"
    printf '%s\n' "$_current" | awk -v priority="${_priority}:" -v exact="$_record" '
        $1 == priority && $0 != exact { ambiguous = 1 }
        END { exit ambiguous ? 1 : 0 }
    ' || return 2
    if magicnet_kernel_running; then return 2; else _kernel_rc=$?; fi
    [ "$_kernel_rc" -eq 1 ] || return 2
    set -f
    # The ledger contains normalized ip-rule tokens only (validated above).
    # shellcheck disable=SC2086
    set -- $_record
    _priority="${1%:}"
    shift
    case "$_family" in
    4) ip rule del priority "$_priority" "$@" >/dev/null 2>&1 || return 1 ;;
    6) ip -6 rule del priority "$_priority" "$@" >/dev/null 2>&1 || return 1 ;;
    esac
    _current="$(magicnet_kernel_route_rules "$_family")" || return 2
    _after="$(printf '%s\n' "$_current" | grep -Fxc -- "$_record" || true)"
    [ "$_after" -eq "$((_before - 1))" ]
)

magicnet_kernel_route_cleanup_rule_family() (
    _family="$1"
    _state="$(magicnet_kernel_route_state_file)"
    _current="$(magicnet_kernel_route_rules "$_family")" || return 2
    [ -n "$_current" ] || return 0
    # Legacy markers prove neither the full rule nor its generation. Keep
    # recovery evidence and report uncertainty rather than deleting by priority.
    grep -Fqx 'schema=2' "$_state" 2>/dev/null || return 2
    _boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || return 2
    grep -Fqx "boot=$_boot" "$_state" || return 2
    if grep -Fqx 'phase=prepared' "$_state"; then
        # Startup never proved which generation installed these rules. Report
        # unresolved state instead of claiming or deleting a newly seen rule.
        _unverified="$(magicnet_kernel_route_new_rules "$_family")" || return 2
        [ -z "$_unverified" ]
        return $?
    fi
    grep -Fqx 'phase=active' "$_state" || return 2
    _recorded="$(sed -n "s/^rule${_family}=//p" "$_state")" || return 2
    while IFS= read -r _record; do
        [ -n "$_record" ] || continue
        magicnet_kernel_route_delete_exact_rule "$_family" "$_record" || return $?
    done <<EOF
$_recorded
EOF
)

magicnet_kernel_route_table_snapshot() (
    _family="$1"
    case "$_family" in
    4) set -- route show table 2022 ;;
    6)
        [ -e /proc/net/if_inet6 ] || return 0
        set -- -6 route show table 2022
        ;;
    *) return 2 ;;
    esac
    _rc=0
    _output="$(LC_ALL=C LANG=C ip "$@" 2>&1)" || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        # iproute2 distinguishes a nonexistent FIB table from denied/unknown.
        case "$_output" in *"FIB table does not exist"*) return 0 ;; esac
        return 2
    fi
    printf '%s\n' "$_output"
)

magicnet_kernel_route_flush_family() (
    _family="$1"
    _routes="$(magicnet_kernel_route_table_snapshot "$_family")" || return 2
    printf '%s\n' "$_routes" | awk '
        { for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == "magicnet0") found = 1 }
        END { exit !found }
    ' || return 0
    if magicnet_kernel_running; then return 2; else _kernel_rc=$?; fi
    [ "$_kernel_rc" -eq 1 ] || return 2
    # Never flush a whole table: 2022 can contain another owner's routes.
    case "$_family" in
    4) ip route flush table 2022 dev magicnet0 >/dev/null 2>&1 || return 1 ;;
    6) ip -6 route flush table 2022 dev magicnet0 >/dev/null 2>&1 || return 1 ;;
    esac
    _routes="$(magicnet_kernel_route_table_snapshot "$_family")" || return 2
    printf '%s\n' "$_routes" | awk '
        { for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == "magicnet0") found = 1 }
        END { exit found ? 1 : 0 }
    '
)

magicnet_kernel_route_cleanup_after_stop() (
    if magicnet_kernel_running; then
        magicnet_warn "Refusing to remove MagicNet routes while the core is still running."
        return 1
    else
        _kernel_rc=$?
    fi
    [ "$_kernel_rc" -eq 1 ] || {
        magicnet_warn "Kernel state is indeterminate; route cleanup was not attempted."
        return 2
    }
    _state="$(magicnet_kernel_route_state_file)"
    # Read everything needed before the first mutation. An unavailable netlink
    # query is not an empty table, even if a previous stop left a marker behind.
    for _family in 4 6; do
        magicnet_kernel_route_rules "$_family" >/dev/null || return 2
        magicnet_kernel_route_table_snapshot "$_family" >/dev/null || return 2
    done
    magicnet_hotspot_route_cleanup || return 1
    if [ -e "$_state" ]; then
        [ -f "$_state" ] && [ ! -L "$_state" ] || return 2
        grep -Fqx 'table=2022' "$_state" && grep -Fqx 'interface=magicnet0' "$_state" || return 2
        magicnet_kernel_route_cleanup_rule_family 4 2022 || return 2
        magicnet_kernel_route_cleanup_rule_family 6 2022 || return 2
    fi
    # No orphan scan by interface-name/priority heuristics. Hotspot rules are
    # removed by their own ledger; newly observed foreign rules are left alone.
    magicnet_kernel_route_flush_family 4 2022 || return 2
    magicnet_kernel_route_flush_family 6 2022 || return 2
    rm -f "$_state" || return 1
)

# Reuse the existing private error input; canonical transparent.recent_error
# is published by the CLI after both successful and failed control commands.
# Never clear an error written by the transparent-mode transaction itself.
magicnet_kernel_route_report_result() (
    _file="${MODDIR}/.state/transparent-recent-error"
    if [ "$1" -eq 0 ]; then
        if [ -f "$_file" ] && [ ! -L "$_file" ] &&
            [ "$(cat "$_file")" = network-route-ownership ]; then
            rm -f "$_file" || return 1
        fi
    elif [ ! -e "$_file" ]; then
        _temp="${_file}.new.$$"
        umask 077
        mkdir -p "${_file%/*}" || return 1
        if ! printf 'network-route-ownership\n' >"$_temp" || ! mv -f "$_temp" "$_file"; then
            rm -f "$_temp"
            return 1
        fi
    fi
)

magicnet_lifecycle_after_start() (
    _rc=0
    magicnet_kernel_route_state_capture || _rc=$?
    magicnet_kernel_route_report_result "$_rc" || _rc=2
    [ "$_rc" -eq 0 ] || magicnet_warn "Route ownership is unverified; recovery evidence was retained."
    magicnet_refresh_status || magicnet_warn "Failed to synchronize the module description after core start."
    return "$_rc"
)

magicnet_lifecycle_after_stop() (
    # No final restoration against a still-live or indeterminate generation.
    if magicnet_kernel_running; then
        magicnet_kernel_route_report_result 1 || true
        return 1
    else
        _stopped_rc=$?
    fi
    if [ "$_stopped_rc" -ne 1 ]; then
        magicnet_kernel_route_report_result 2 || true
        return 2
    fi
    _rc=0
    # Do not short-circuit independent cleanup when one subsystem fails. A
    # crashed/failed start may leave DNS capture even without a live core.
    magicnet_disable_dns_capture || _rc=2
    magicnet_disable_dns_leak_guard || _rc=2
    magicnet_kernel_route_cleanup_after_stop || _rc=2
    # Restoring offload belongs to service stop too, not just hotspot disable.
    # Keep the user's persisted hotspot selection; replay re-enables it on start.
    magicnet_hotspot_offload_restore || _rc=2
    magicnet_kernel_route_report_result "$_rc" || _rc=2
    [ "$_rc" -eq 0 ] || magicnet_warn "Network cleanup is incomplete; recovery evidence was retained."
    magicnet_refresh_status || magicnet_warn "Failed to synchronize the module description after core stop."
    return "$_rc"
)

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
