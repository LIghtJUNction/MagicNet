magicnet_route_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_route_list_file() {
    printf '%s\n' "$(magicnet_route_dir)/route-$1-domain-suffix.list"
}

magicnet_route_list_values() {
    magicnet_list_file_values "$1"
}

magicnet_route_has_rules() {
    for _target in proxy direct block warp; do
        if magicnet_route_list_values "$(magicnet_route_list_file "$_target")" | grep -q .; then
            unset _target
            return 0
        fi
    done
    unset _target
    return 1
}

magicnet_hotspot_offload_state_file() {
    printf '%s\n' "${MODDIR}/.state/hotspot/tether-offload.previous"
}

magicnet_hotspot_route_state_file() {
    printf '%s\n' "${MODDIR}/.state/hotspot/tun-rules.list"
}

magicnet_hotspot_proxy_enabled() {
    [ -f "$(magicnet_hotspot_offload_state_file)" ]
}

magicnet_hotspot_source_cidrs() {
    magicnet_hotspot_proxy_enabled || return 0
    magicnet_hotspot_active_networks |
        awk -F'|' 'NF == 2 { print $2 }' |
        LC_ALL=C sort -u
}

magicnet_hotspot_jq() {
    magicnet_jq
}

magicnet_hotspot_source_cidrs_json() {
    _hotspot_json_jq="$1"
    magicnet_hotspot_source_cidrs | "$_hotspot_json_jq" -Rsc '
        split("\n") | map(select(length > 0))
    '
    _hotspot_json_rc=$?
    unset _hotspot_json_jq
    return "$_hotspot_json_rc"
}

magicnet_hotspot_interface_allowed() {
    _hotspot_allowed_iface="$1"
    case "$_hotspot_allowed_iface" in
        "" | *[!A-Za-z0-9_.-]*)
            unset _hotspot_allowed_iface
            return 1
            ;;
    esac
    case "$_hotspot_allowed_iface" in
        wlan[0-9]* | softap[0-9]* | ap_br_wlan[0-9]* | ap_br_softap[0-9]* | \
        swlan[0-9]* | rndis[0-9]* | usb[0-9]* | bt-pan | bt-pan[0-9]* | \
        p2p[0-9]* | p2p-*)
            unset _hotspot_allowed_iface
            return 0
            ;;
        *)
            unset _hotspot_allowed_iface
            return 1
            ;;
    esac
}

magicnet_hotspot_dumpsys_tethering() {
    _hotspot_dumpsys_timeout="${MAGICNET_HOTSPOT_DUMPSYS_TIMEOUT:-2}"
    case "$_hotspot_dumpsys_timeout" in
        '' | *[!0-9]* | 0) _hotspot_dumpsys_timeout=2 ;;
    esac
    [ "$_hotspot_dumpsys_timeout" -le 5 ] || _hotspot_dumpsys_timeout=5
    if [ -x "${MODDIR}/bin/busybox" ]; then
        "${MODDIR}/bin/busybox" timeout "$_hotspot_dumpsys_timeout" dumpsys tethering
    elif magicnet_cmd_exists timeout; then
        timeout "$_hotspot_dumpsys_timeout" dumpsys tethering
    else
        dumpsys tethering
    fi
    _hotspot_dumpsys_rc=$?
    set -- "$_hotspot_dumpsys_rc"
    unset _hotspot_dumpsys_timeout _hotspot_dumpsys_rc
    return "$1"
}

# Android exposes the active tethering interfaces through dumpsys, but OEMs
# differ in which command output is available to a root shell. Prefer the
# authoritative tethering state and fall back to the standard SoftAP/USB/Bt
# interface names only when dumpsys returns no active interface. OEM dumpsys
# implementations are bounded because this discovery sits on the core startup
# path and `ip link` remains a safe fallback.
magicnet_hotspot_discover_interfaces() {
    _hotspot_tethered=
    if magicnet_cmd_exists dumpsys; then
        _hotspot_tethered="$(magicnet_hotspot_dumpsys_tethering 2>/dev/null | awk '
            $2 == "-" && $3 == "TetheredState" && $1 !~ /[^A-Za-z0-9_.-]/ {
                print $1
            }
        ' | awk '!seen[$0]++' || true)"
    fi
    if [ -n "$_hotspot_tethered" ]; then
        printf '%s\n' "$_hotspot_tethered" | while IFS= read -r _hotspot_iface; do
            magicnet_hotspot_interface_allowed "$_hotspot_iface" &&
                printf '%s\n' "$_hotspot_iface"
        done
        unset _hotspot_tethered _hotspot_iface
        return 0
    fi
    if magicnet_cmd_exists ip; then
        ip -o link show 2>/dev/null | awk -F': ' '
            {
                name = $2
                sub(/@.*/, "", name)
                if (name ~ /^(wlan[1-9][0-9]*|softap[0-9]+|ap_br_(wlan|softap)[0-9]+|swlan[0-9]+|rndis[0-9]+|usb[0-9]+|bt-pan[0-9]*|p2p[0-9]+|p2p-.+)$/ && !seen[name]++) {
                    print name
                }
            }
        '
    fi
    unset _hotspot_tethered _hotspot_iface
}

magicnet_hotspot_active_networks_uncached() {
    _hotspot_iface=
    _hotspot_routes=
    for _hotspot_iface in $(magicnet_hotspot_discover_interfaces); do
        magicnet_hotspot_interface_allowed "$_hotspot_iface" || continue
        magicnet_iface_exists "$_hotspot_iface" || continue
        _hotspot_routes="$(ip route show dev "$_hotspot_iface" scope link 2>/dev/null | awk '
            function valid_octet(value) {
                return value ~ /^[0-9]+$/ && length(value) <= 3 &&
                    (length(value) == 1 || substr(value, 1, 1) != "0") &&
                    value + 0 <= 255
            }
            {
                count = split($1, cidr, "/")
                if (count != 2 || cidr[2] !~ /^[0-9]+$/ || cidr[2] + 0 > 32) next
                octets = split(cidr[1], address, ".")
                if (octets != 4) next
                for (octet_index = 1; octet_index <= octets; octet_index++) {
                    if (!valid_octet(address[octet_index])) next
                }
                print $1
            }
        ' | awk '!seen[$0]++')"
        for _hotspot_cidr in $_hotspot_routes; do
            printf '%s|%s\n' "$_hotspot_iface" "$_hotspot_cidr"
        done
    done
    unset _hotspot_iface _hotspot_routes _hotspot_cidr
}

magicnet_hotspot_active_networks() {
    if [ -n "${MAGICNET_HOTSPOT_STARTUP_SNAPSHOT:-}" ] &&
        [ -f "$MAGICNET_HOTSPOT_STARTUP_SNAPSHOT" ]; then
        cat "$MAGICNET_HOTSPOT_STARTUP_SNAPSHOT"
        return 0
    fi
    magicnet_hotspot_active_networks_uncached
}

magicnet_hotspot_startup_snapshot_prepare() {
    magicnet_hotspot_startup_snapshot_clear
    magicnet_hotspot_proxy_enabled || return 0
    _hotspot_snapshot_dir="${MODDIR}/.state/hotspot"
    _hotspot_snapshot="${_hotspot_snapshot_dir}/startup-networks.$$"
    _hotspot_snapshot_tmp="${_hotspot_snapshot}.tmp"
    mkdir -p "$_hotspot_snapshot_dir" || return 1
    if (umask 077; magicnet_hotspot_active_networks_uncached >"$_hotspot_snapshot_tmp") &&
        mv -f "$_hotspot_snapshot_tmp" "$_hotspot_snapshot"; then
        MAGICNET_HOTSPOT_STARTUP_SNAPSHOT="$_hotspot_snapshot"
        export MAGICNET_HOTSPOT_STARTUP_SNAPSHOT
        unset _hotspot_snapshot_dir _hotspot_snapshot _hotspot_snapshot_tmp
        return 0
    fi
    rm -f "$_hotspot_snapshot_tmp" "$_hotspot_snapshot" 2>/dev/null || true
    unset _hotspot_snapshot_dir _hotspot_snapshot _hotspot_snapshot_tmp
    return 1
}

magicnet_hotspot_startup_snapshot_clear() {
    case "${MAGICNET_HOTSPOT_STARTUP_SNAPSHOT:-}" in
        "${MODDIR}/.state/hotspot/startup-networks."*)
            rm -f "$MAGICNET_HOTSPOT_STARTUP_SNAPSHOT" 2>/dev/null || true
            ;;
    esac
    unset MAGICNET_HOTSPOT_STARTUP_SNAPSHOT
}

magicnet_hotspot_rule_present() {
    _hotspot_rule_check_priority="$1"
    _hotspot_rule_check_iface="$2"
    ip rule show 2>/dev/null | awk \
        -v expected_priority="${_hotspot_rule_check_priority}:" \
        -v expected_iface="$_hotspot_rule_check_iface" '
        $1 == expected_priority && index($0, "iif " expected_iface " ") > 0 &&
            index($0, "lookup 2022") > 0 { found = 1 }
        END { exit found ? 0 : 1 }
    '
    _hotspot_rule_rc=$?
    unset _hotspot_rule_check_priority _hotspot_rule_check_iface
    return "$_hotspot_rule_rc"
}

magicnet_hotspot_delete_rule() {
    _hotspot_priority="$1"
    _hotspot_iface="$2"
    magicnet_hotspot_rule_present "$_hotspot_priority" "$_hotspot_iface" || {
        unset _hotspot_priority _hotspot_iface
        return 0
    }
    _hotspot_delete_attempt=0
    while [ "$_hotspot_delete_attempt" -lt 8 ]; do
        if ip rule del priority "$_hotspot_priority" iif "$_hotspot_iface" lookup 2022 \
            >/dev/null 2>&1; then
            _hotspot_delete_attempt=$((_hotspot_delete_attempt + 1))
        else
            break
        fi
    done
    if magicnet_hotspot_rule_present "$_hotspot_priority" "$_hotspot_iface"; then
        _hotspot_rule_rc=1
    else
        _hotspot_rule_rc=0
    fi
    unset _hotspot_priority _hotspot_iface _hotspot_delete_attempt
    return "$_hotspot_rule_rc"
}

magicnet_hotspot_route_cleanup() {
    _hotspot_state_file="$(magicnet_hotspot_route_state_file)"
    _hotspot_cleanup_rc=0
    if [ -f "$_hotspot_state_file" ]; then
        while IFS='|' read -r _hotspot_priority _hotspot_iface; do
            case "$_hotspot_priority" in
                "" | *[!0-9]*)
                    _hotspot_cleanup_rc=1
                    continue
                    ;;
            esac
            magicnet_hotspot_interface_allowed "$_hotspot_iface" || {
                _hotspot_cleanup_rc=1
                continue
            }
            magicnet_hotspot_delete_rule "$_hotspot_priority" "$_hotspot_iface" ||
                _hotspot_cleanup_rc=1
        done <"$_hotspot_state_file"
    fi
    if [ "$_hotspot_cleanup_rc" -eq 0 ]; then
        rm -f "$_hotspot_state_file" 2>/dev/null || true
    fi
    _hotspot_cleanup_result="$_hotspot_cleanup_rc"
    unset _hotspot_state_file _hotspot_cleanup_rc _hotspot_priority _hotspot_iface
    return "$_hotspot_cleanup_result"
}

magicnet_hotspot_android_tether_priority() {
    _hotspot_iface="$1"
    ip rule show 2>/dev/null | awk -v expected_iface="$_hotspot_iface" '
        $1 ~ /^[0-9]+:$/ && index($0, "iif " expected_iface " ") > 0 &&
            index($0, "iif lo") == 0 && index($0, "lookup ") > 0 {
            priority = $1
            sub(/:/, "", priority)
            if (priority + 0 > 1 && (!found || priority + 0 < found)) found = priority + 0
        }
        END { if (found) print found - 1 }
    ' | sed -n '1p'
    unset _hotspot_iface
}

magicnet_hotspot_choose_rule_priority() {
    _hotspot_iface="$1"
    _hotspot_upper="$(magicnet_hotspot_android_tether_priority "$_hotspot_iface" 2>/dev/null || true)"
    case "$_hotspot_upper" in
        '' | *[!0-9]*) _hotspot_upper=8999 ;;
    esac
    _hotspot_candidate="$_hotspot_upper"
    _hotspot_rules="$(ip rule show 2>/dev/null || true)"
    while [ "$_hotspot_candidate" -gt 0 ]; do
        if ! printf '%s\n' "$_hotspot_rules" | awk -v expected="${_hotspot_candidate}:" \
            '$1 == expected { found = 1 } END { exit found ? 0 : 1 }'; then
            printf '%s\n' "$_hotspot_candidate"
            unset _hotspot_iface _hotspot_upper _hotspot_candidate _hotspot_rules
            return 0
        fi
        _hotspot_candidate=$((_hotspot_candidate - 1))
    done
    unset _hotspot_iface _hotspot_upper _hotspot_candidate _hotspot_rules
    return 1
}

magicnet_hotspot_tun_route_table_ready() {
    magicnet_iface_exists magicnet0 || return 1
    ip route show table 2022 2>/dev/null | awk '
        index($0, "dev magicnet0") > 0 { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

magicnet_hotspot_reconcile() {
    if ! magicnet_hotspot_proxy_enabled; then
        magicnet_hotspot_route_cleanup
        return $?
    fi

    # The selector can be enabled before sing-box has created magicnet0. That
    # is a valid pending state; the post-start pass and the watcher will retry
    # once the TUN route table exists. A present but incomplete TUN is a real
    # failure and must remain visible to the caller/status output.
    if ! magicnet_hotspot_tun_route_table_ready; then
        magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true
        magicnet_iface_exists magicnet0 || return 0
        magicnet_warn "magicnet0 route table 2022 is unavailable; hotspot forwarding is not intercepted"
        return 1
    fi

    _hotspot_pairs="$(magicnet_hotspot_active_networks | awk -F'|' '!seen[$1]++')"
    magicnet_hotspot_route_cleanup || {
        unset _hotspot_pairs
        return 1
    }
    [ -n "$_hotspot_pairs" ] || {
        unset _hotspot_pairs
        return 0
    }

    _hotspot_first_iface="${_hotspot_pairs%%|*}"
    _hotspot_priority="$(magicnet_hotspot_choose_rule_priority "$_hotspot_first_iface")" || {
        unset _hotspot_pairs _hotspot_first_iface
        return 1
    }
    _hotspot_state_file="$(magicnet_hotspot_route_state_file)"
    _hotspot_state_tmp="${_hotspot_state_file}.new.$$"
    mkdir -p "${_hotspot_state_file%/*}" || {
        unset _hotspot_pairs _hotspot_first_iface _hotspot_priority _hotspot_state_file _hotspot_state_tmp
        return 1
    }
    : >"$_hotspot_state_tmp" || {
        unset _hotspot_pairs _hotspot_first_iface _hotspot_priority _hotspot_state_file _hotspot_state_tmp
        return 1
    }
    _hotspot_add_rc=0
    _hotspot_current_added=0
    while IFS='|' read -r _hotspot_iface _hotspot_cidr; do
        [ -n "$_hotspot_iface" ] || continue
        if ! ip rule add priority "$_hotspot_priority" iif "$_hotspot_iface" lookup 2022 \
            >/dev/null 2>&1; then
            _hotspot_add_rc=1
            break
        fi
        _hotspot_current_added=1
        printf '%s|%s\n' "$_hotspot_priority" "$_hotspot_iface" >>"$_hotspot_state_tmp" || {
            _hotspot_add_rc=1
            break
        }
        _hotspot_current_added=0
    done <<EOF
$_hotspot_pairs
EOF
    if [ "$_hotspot_add_rc" -ne 0 ] ||
        ! chmod 600 "$_hotspot_state_tmp" ||
        ! mv -f "$_hotspot_state_tmp" "$_hotspot_state_file"; then
        if [ "$_hotspot_current_added" -eq 1 ]; then
            magicnet_hotspot_delete_rule "$_hotspot_priority" "$_hotspot_iface" || true
        fi
        while IFS='|' read -r _hotspot_cleanup_priority _hotspot_cleanup_iface; do
            [ -n "$_hotspot_cleanup_priority" ] || continue
            magicnet_hotspot_delete_rule "$_hotspot_cleanup_priority" "$_hotspot_cleanup_iface" || true
        done <"$_hotspot_state_tmp" 2>/dev/null || true
        rm -f "$_hotspot_state_tmp" 2>/dev/null || true
        unset _hotspot_pairs _hotspot_first_iface _hotspot_priority _hotspot_state_file _hotspot_state_tmp
        unset _hotspot_add_rc _hotspot_current_added _hotspot_iface _hotspot_cidr
        unset _hotspot_cleanup_priority _hotspot_cleanup_iface
        return 1
    fi
    unset _hotspot_pairs _hotspot_first_iface _hotspot_priority _hotspot_state_file _hotspot_state_tmp
    unset _hotspot_add_rc _hotspot_current_added _hotspot_iface _hotspot_cidr
    unset _hotspot_cleanup_priority _hotspot_cleanup_iface
}

magicnet_hotspot_route_status() {
    _hotspot_state_file="$(magicnet_hotspot_route_state_file)"
    if magicnet_hotspot_tun_route_table_ready; then
        printf 'route_table_ready=1\n'
    else
        printf 'route_table_ready=0\n'
    fi
    _hotspot_pairs="$(magicnet_hotspot_active_networks || true)"
    _hotspot_interfaces="$(printf '%s\n' "$_hotspot_pairs" | awk -F'|' 'NF && !seen[$1]++ { print $1 }' | tr '\n' ',' | sed 's/,$//')"
    _hotspot_networks="$(printf '%s\n' "$_hotspot_pairs" | awk -F'|' 'NF && !seen[$2]++ { print $2 }' | tr '\n' ',' | sed 's/,$//')"
    printf 'downstream_interfaces=%s\n' "${_hotspot_interfaces:-none}"
    printf 'downstream_networks=%s\n' "${_hotspot_networks:-none}"
    _hotspot_rule_count=0
    _hotspot_missing_rule_count=0
    if [ -f "$_hotspot_state_file" ]; then
        while IFS='|' read -r _hotspot_priority _hotspot_iface; do
            case "$_hotspot_priority" in
                '' | *[!0-9]*) continue ;;
            esac
            magicnet_hotspot_interface_allowed "$_hotspot_iface" || continue
            printf 'policy_rule=%s iif=%s table=2022\n' "$_hotspot_priority" "$_hotspot_iface"
            if magicnet_hotspot_rule_present "$_hotspot_priority" "$_hotspot_iface"; then
                _hotspot_rule_count=$((_hotspot_rule_count + 1))
            else
                _hotspot_missing_rule_count=$((_hotspot_missing_rule_count + 1))
            fi
        done <"$_hotspot_state_file"
    fi
    printf 'policy_rule_count=%s\n' "$_hotspot_rule_count"
    printf 'policy_rule_missing=%s\n' "$_hotspot_missing_rule_count"
    if ! magicnet_hotspot_proxy_enabled; then
        printf 'route_status=disabled\n'
    elif [ -z "$_hotspot_pairs" ]; then
        printf 'route_status=waiting-for-hotspot\n'
    elif ! magicnet_hotspot_tun_route_table_ready || [ "$_hotspot_rule_count" -eq 0 ] ||
        [ "$_hotspot_missing_rule_count" -ne 0 ]; then
        printf 'route_status=degraded\n'
    else
        printf 'route_status=ready\n'
    fi
    unset _hotspot_state_file _hotspot_pairs _hotspot_interfaces _hotspot_networks
    unset _hotspot_rule_count _hotspot_missing_rule_count _hotspot_priority _hotspot_iface
}

magicnet_hotspot_offload_value() {
    command -v settings >/dev/null 2>&1 || return 1
    settings get global tether_offload_disabled 2>/dev/null | tr -d '\r' | sed -n '1p'
}

magicnet_hotspot_register_offload_rollback() {
    import prop
    _hotspot_route_rollback_cmd='_mn_rules="${0%/*}/.state/hotspot/tun-rules.list"; if [ -f "$_mn_rules" ] && command -v ip >/dev/null 2>&1; then while IFS="|" read -r _mn_priority _mn_iface; do case "$_mn_priority" in ""|*[!0-9]*) continue;; esac; case "$_mn_iface" in wlan[0-9]*|softap[0-9]*|ap_br_wlan[0-9]*|ap_br_softap[0-9]*|swlan[0-9]*|rndis[0-9]*|usb[0-9]*|bt-pan|bt-pan[0-9]*|p2p[0-9]*|p2p-*) ;; *) continue;; esac; _mn_attempt=0; while [ "$_mn_attempt" -lt 8 ]; do ip rule del priority "$_mn_priority" iif "$_mn_iface" lookup 2022 >/dev/null 2>&1 || break; _mn_attempt=$((_mn_attempt+1)); done; done <"$_mn_rules"; fi; rm -f "$_mn_rules" 2>/dev/null || true'
    register_uninstall_cmd "$_hotspot_route_rollback_cmd" "$MODDIR" >/dev/null 2>&1 || true
    _hotspot_rollback_cmd='_mn_state="${0%/*}/.state/hotspot/tether-offload.previous"; if [ -f "$_mn_state" ]; then _mn_previous="$(sed -n "1p" "$_mn_state" 2>/dev/null)"; if [ "$_mn_previous" = unset ]; then settings delete global tether_offload_disabled >/dev/null 2>&1 || true; else settings put global tether_offload_disabled "${_mn_previous#value=}" >/dev/null 2>&1 || true; fi; rm -f "$_mn_state" 2>/dev/null || true; fi'
    register_uninstall_cmd "$_hotspot_rollback_cmd" "$MODDIR" >/dev/null 2>&1 || true
    unset _hotspot_route_rollback_cmd _hotspot_rollback_cmd
}

magicnet_hotspot_offload_enable() {
    _hotspot_state="$(magicnet_hotspot_offload_state_file)"
    _hotspot_state_created=0
    if [ ! -f "$_hotspot_state" ]; then
        _hotspot_previous="$(magicnet_hotspot_offload_value)" || {
            magicnet_warn "Android settings service is unavailable; cannot disable tether offload"
            unset _hotspot_state _hotspot_state_created _hotspot_previous
            return 1
        }
        case "$_hotspot_previous" in
            "" | null) _hotspot_saved="unset" ;;
            0 | 1) _hotspot_saved="value=$_hotspot_previous" ;;
            *)
                magicnet_warn "Unexpected tether_offload_disabled value; refusing to overwrite it"
                unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved
                return 1
                ;;
        esac
        if ! mkdir -p "${_hotspot_state%/*}"; then
            unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved
            return 1
        fi
        _hotspot_tmp="${_hotspot_state}.new.$$"
        if ! printf '%s\n' "$_hotspot_saved" >"$_hotspot_tmp" ||
            ! mv -f "$_hotspot_tmp" "$_hotspot_state"; then
            rm -f "$_hotspot_tmp" 2>/dev/null || true
            unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved _hotspot_tmp
            return 1
        fi
        _hotspot_state_created=1
        magicnet_hotspot_register_offload_rollback
    fi
    if ! settings put global tether_offload_disabled 1 >/dev/null 2>&1 ||
        [ "$(magicnet_hotspot_offload_value)" != 1 ]; then
        magicnet_warn "Failed to disable Android tether offload"
        if [ "$_hotspot_state_created" -eq 1 ]; then
            magicnet_hotspot_offload_restore >/dev/null 2>&1 || true
        fi
        unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved _hotspot_tmp
        return 1
    fi
    unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved _hotspot_tmp
}

magicnet_hotspot_offload_restore() {
    _hotspot_state="$(magicnet_hotspot_offload_state_file)"
    [ -f "$_hotspot_state" ] || {
        magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true
        unset _hotspot_state
        return 0
    }
    _hotspot_previous="$(sed -n '1p' "$_hotspot_state" 2>/dev/null)"
    case "$_hotspot_previous" in
        unset) settings delete global tether_offload_disabled >/dev/null 2>&1 ;;
        value=0 | value=1)
            settings put global tether_offload_disabled "${_hotspot_previous#value=}" >/dev/null 2>&1
            ;;
        *)
            magicnet_warn "Invalid saved tether offload state; refusing to restore it"
            unset _hotspot_state _hotspot_previous
            return 1
            ;;
    esac
    _hotspot_rc=$?
    if [ "$_hotspot_rc" -eq 0 ]; then
        rm -f "$_hotspot_state" 2>/dev/null || true
        magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true
    fi
    unset _hotspot_state _hotspot_previous
    return "$_hotspot_rc"
}

magicnet_hotspot_offload_status() {
    _hotspot_value="$(magicnet_hotspot_offload_value 2>/dev/null || true)"
    case "$_hotspot_value" in
        1) printf 'offload_disabled=1\n' ;;
        *) printf 'offload_disabled=0\n' ;;
    esac
    if [ -f "$(magicnet_hotspot_offload_state_file)" ]; then
        printf 'offload_owned=1\n'
    else
        printf 'offload_owned=0\n'
    fi
    unset _hotspot_value
}

magicnet_singbox_render_hotspot_policy() {
    _hotspot_render_source="$1"
    _hotspot_render_target="$2"
    _jq="$(magicnet_hotspot_jq)"
    [ -n "$_jq" ] || {
        magicnet_warn "jq not found; cannot apply hotspot proxy policy"
        unset _hotspot_render_source _hotspot_render_target _jq
        return 1
    }
    _hotspot_sources_json="$(magicnet_hotspot_source_cidrs_json "$_jq")" || {
        unset _hotspot_render_source _hotspot_render_target _jq _hotspot_sources_json
        return 1
    }
    # Forwarded clients retain an address from the active downstream subnet
    # when entering the TUN. Match only those discovered subnets: matching all
    # RFC1918 space also catches the phone's own Wi-Fi traffic whenever process
    # attribution or domain sniffing is unavailable.
    if (umask 077; "$_jq" --argjson hotspot_sources "$_hotspot_sources_json" '
        def hotspot_selector:
          {
            "type": "selector",
            "tag": "hotspot",
            "outbounds": ["direct", "proxy"],
            "default": "direct"
          };
        def hotspot_rule:
          {
            "inbound": ["tun-in"],
            "source_ip_cidr": $hotspot_sources,
            "outbound": "hotspot"
          };
        def is_managed_hotspot_rule:
          type == "object"
            and (keys | sort) == ["inbound", "outbound", "source_ip_cidr"]
            and (.inbound // []) == ["tun-in"]
            and (.outbound // "") == "hotspot"
            and (.source_ip_cidr | type) == "array";
        def insertion_index($rules):
          (
            [$rules | to_entries[] | select((.value.outbound // "") == "dns-guard") | .key]
            | last
          ) as $dns_guard_anchor
          | (
              [$rules | to_entries[] | select(.value.action != null) | .key]
              | last
            ) as $action_anchor
          | (($dns_guard_anchor // $action_anchor // -1) + 1);
        .outbounds = (
          ((.outbounds // []) | map(select((.tag // "") != "hotspot")))
          + [hotspot_selector]
        )
        | (.route.rules // []) as $original_rules
        | insertion_index($original_rules) as $managed_index
        | (
            if (($original_rules[$managed_index] // {}) | is_managed_hotspot_rule)
            then $original_rules[:$managed_index] + $original_rules[($managed_index + 1):]
            else $original_rules
            end
          ) as $rules
        | insertion_index($rules) as $insert_at
        | .route.rules = (
            if ($hotspot_sources | length) > 0
            then $rules[:$insert_at] + [hotspot_rule] + $rules[$insert_at:]
            else $rules
            end
          )
    ' "$_hotspot_render_source" >"$_hotspot_render_target") && chmod 600 "$_hotspot_render_target"; then
        _hotspot_render_rc=0
    else
        rm -f "$_hotspot_render_target" 2>/dev/null || true
        _hotspot_render_rc=1
    fi
    unset _hotspot_render_source _hotspot_render_target _jq _hotspot_sources_json
    return "$_hotspot_render_rc"
}

magicnet_singbox_apply_hotspot_policy() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _tmp="${_config}.hotspot-policy.new"
    if ! magicnet_singbox_render_hotspot_policy "$_config" "$_tmp" ||
        ! mv -f "$_tmp" "$_config" || ! chmod 600 "$_config"; then
        rm -f "$_tmp" 2>/dev/null || true
        unset _config _tmp
        return 1
    fi
    unset _config _tmp
}

magicnet_singbox_hotspot_policy_current() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _tmp="${_config}.hotspot-policy.check.$$"
    if magicnet_singbox_render_hotspot_policy "$_config" "$_tmp" && cmp -s "$_config" "$_tmp"; then
        _hotspot_policy_rc=0
    else
        _hotspot_policy_rc=1
    fi
    rm -f "$_tmp" 2>/dev/null || true
    unset _config _tmp
    return "$_hotspot_policy_rc"
}

magicnet_route_singbox_rules() {
    for _target in proxy direct block warp; do
        case "$_target" in
            proxy) _outbound="proxy-rule" ;;
            direct) _outbound="direct" ;;
            block) _outbound="block" ;;
            warp) _outbound="warp" ;;
        esac
        _domains="$(magicnet_route_list_values "$(magicnet_route_list_file "$_target")")"
        [ -n "$_domains" ] || continue
        printf '      {\n'
        printf '        "domain_suffix": [\n'
        printf '          "__magicnet_route__",\n'
        _count=$(printf '%s\n' "$_domains" | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_domains" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_domain")" "$_comma"
        done
        printf '        ],\n'
        printf '        "outbound": "%s"\n' "$_outbound"
        printf '      },\n'
    done
    unset _target _outbound _domains _count _idx _comma _domain
}

magicnet_route_apply_singbox() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _tmp="${_config}.magicnet-route.new"
    _rules_file="${MODDIR}/.tmp/magicnet-route-singbox.rules"
    if ! mkdir -p "${_rules_file%/*}" ||
        ! magicnet_route_singbox_rules >"$_rules_file"; then
        rm -f "$_rules_file" "$_tmp" 2>/dev/null || true
        return 1
    fi
    if magicnet_route_has_rules &&
        ! grep -q '"__magicnet_route__"' "$_rules_file"; then
        magicnet_warn "sing-box custom route rules were not generated"
        rm -f "$_rules_file" "$_tmp" 2>/dev/null || true
        return 1
    fi
    if ! (umask 077; awk -v rules_file="$_rules_file" '
        BEGIN {
            in_route = 0
            in_rules = 0
            buffering = 0
            buffer = ""
            skip_custom = 0
            inserted = 0
        }
        function reset_buffer() {
            buffer = ""
            buffering = 0
            skip_custom = 0
        }
        function flush_rule() {
            if (!skip_custom) {
                if (!inserted && buffer ~ /"action"[[:space:]]*:[[:space:]]*"sniff"/) {
                    while ((getline rule_line < rules_file) > 0) {
                        print rule_line
                    }
                    close(rules_file)
                    inserted = 1
                }
                printf "%s", buffer
            }
            reset_buffer()
        }
        {
            if (buffering) {
                buffer = buffer $0 "\n"
                if ($0 ~ /"domain_suffix"[[:space:]]*:/) {
                    getline next_line
                    buffer = buffer next_line "\n"
                    if (next_line ~ /"__magicnet_route__"/) {
                        skip_custom = 1
                    }
                }
                if ($0 ~ /^      }[,]?[[:space:]]*$/) {
                    flush_rule()
                }
                next
            }
            if ($0 ~ /^  "route"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/) {
                in_route = 1
                print
                next
            }
            if (in_route && $0 ~ /^  }[,]?[[:space:]]*$/) {
                in_route = 0
                print
                next
            }
            if (in_route && $0 ~ /^    "rules"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_rules = 1
                print
                next
            }
            if (in_rules && $0 ~ /^    ][,]?[[:space:]]*$/) {
                in_rules = 0
                print
                next
            }
            if (in_rules && $0 ~ /^      \{[[:space:]]*$/) {
                buffering = 1
                buffer = $0 "\n"
                skip_custom = 0
                next
            }
            print
        }
    ' "$_config" >"$_tmp"); then
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi

    # Validate the candidate before publishing it. The old order moved the
    # snapshot first and only then noticed that a failed rule generation had
    # removed the managed marker, leaving the live config damaged even though
    # the function returned failure.
    if magicnet_route_has_rules; then
        grep -q '"__magicnet_route__"' "$_tmp" || {
            magicnet_warn "sing-box custom route rules were not inserted"
            rm -f "$_tmp" 2>/dev/null || true
            return 1
        }
    else
        if grep -q '"__magicnet_route__"' "$_tmp"; then
            magicnet_warn "sing-box custom route marker was not removed"
            rm -f "$_tmp" 2>/dev/null || true
            return 1
        fi
    fi
    if ! chmod 600 "$_tmp" || ! mv -f "$_tmp" "$_config" || ! chmod 600 "$_config"; then
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_route_apply_unlocked() {
    _route_rc=0
    magicnet_route_apply_singbox || _route_rc=1
    magicnet_singbox_apply_hotspot_policy || _route_rc=1
    return "$_route_rc"
}

magicnet_route_apply() {
    magicnet_with_config_lock magicnet_route_apply_unlocked
}
