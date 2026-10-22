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

magicnet_hotspot_source_cidrs() (
    magicnet_hotspot_proxy_enabled || return 0
    _hotspot_networks="$(magicnet_hotspot_active_networks)" || return 2
    printf '%s\n' "$_hotspot_networks" |
        awk -F'|' 'NF == 2 { print $2 }' |
        LC_ALL=C sort -u
)

magicnet_hotspot_jq() {
    magicnet_jq
}

magicnet_hotspot_source_cidrs_json() (
    _hotspot_json_jq="$1"
    _hotspot_cidrs="$(magicnet_hotspot_source_cidrs)" || return 2
    printf '%s\n' "$_hotspot_cidrs" | "$_hotspot_json_jq" -Rsc '
        split("\n") | map(select(length > 0))
    '
)

magicnet_hotspot_interface_allowed() {
    _hotspot_allowed_iface="$1"
    case "$_hotspot_allowed_iface" in
    "" | *[!A-Za-z0-9_.-]*)
        unset _hotspot_allowed_iface
        return 1
        ;;
    esac
    case "$_hotspot_allowed_iface" in
    wlan[0-9]* | ap[0-9]* | softap[0-9]* | ap_br_ap[0-9]* | ap_br_wlan[0-9]* | ap_br_softap[0-9]* | \
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
magicnet_hotspot_discover_interfaces() (
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
        return 0
    fi
    if magicnet_cmd_exists ip; then
        _hotspot_links="$(ip -o link show 2>/dev/null)" || return 2
        printf '%s\n' "$_hotspot_links" | awk -F': ' '
            {
                name = $2
                sub(/@.*/, "", name)
                if (name ~ /^(wlan[1-9][0-9]*|ap[0-9]+|softap[0-9]+|ap_br_(ap|wlan|softap)[0-9]+|swlan[0-9]+|rndis[0-9]+|usb[0-9]+|bt-pan[0-9]*|p2p[0-9]+|p2p-.+)$/ && !seen[name]++) {
                    print name
                }
            }
        '
        return $?
    fi
    return 2
)

magicnet_hotspot_active_networks_uncached() (
    _hotspot_interfaces="$(magicnet_hotspot_discover_interfaces)" || return 2
    for _hotspot_iface in $_hotspot_interfaces; do
        magicnet_hotspot_interface_allowed "$_hotspot_iface" || continue
        magicnet_iface_exists "$_hotspot_iface" || return 2
        # A failed query says nothing about whether the hotspot disappeared.
        # Keep this status outside pipelines so callers retain the live config.
        _hotspot_route_output="$(ip route show dev "$_hotspot_iface" scope link 2>/dev/null)" || return 2
        # Android also uses per-interface routing tables for tethered networks.
        if [ -z "$_hotspot_route_output" ]; then
            _hotspot_route_output="$(ip route show table all dev "$_hotspot_iface" scope link 2>/dev/null)" || return 2
        fi
        _hotspot_routes="$(printf '%s\n' "$_hotspot_route_output" | awk '
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
    return 0
)

magicnet_hotspot_active_networks() {
    if [ -n "${MAGICNET_HOTSPOT_STARTUP_SNAPSHOT:-}" ] &&
        [ -f "$MAGICNET_HOTSPOT_STARTUP_SNAPSHOT" ]; then
        cat "$MAGICNET_HOTSPOT_STARTUP_SNAPSHOT"
        return $?
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
    if (
        umask 077
        magicnet_hotspot_active_networks_uncached >"$_hotspot_snapshot_tmp"
    ) &&
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

magicnet_hotspot_rule_present() (
    _check_priority="$1"
    _check_iface="$2"
    _check_rules="$(ip rule show 2>/dev/null)" || return 2
    printf '%s\n' "$_check_rules" | awk \
        -v expected_priority="${_check_priority}:" -v expected_iface="$_check_iface" '
        # Match only the exact tuple we install. Extra selectors, a different
        # table (including 20220), or a reused priority do not prove ownership.
        NF == 7 && $1 == expected_priority && $2 == "from" && $3 == "all" &&
            $4 == "iif" && $5 == expected_iface && $6 == "lookup" && $7 == "2022" { found = 1 }
        END { exit !found }
    '
)

# Observe only the exact ingress tuple used by this module. Callers choose the
# interface scope: discovery is enough for status, but cleanup requires a valid
# ownership journal. Never infer ownership from the table/priority alone.
magicnet_hotspot_observed_rules() (
    _observed_ifaces="$1"
    _observed_rules="$(ip rule show 2>/dev/null)" || return 2
    printf '%s\n' "$_observed_rules" | awk -v ifaces="$_observed_ifaces" '
        BEGIN { n = split(ifaces, names, "\n"); for (i = 1; i <= n; i++) wanted[names[i]] = 1 }
        NF == 7 && $1 ~ /^[1-9][0-9]*:$/ && $1 + 0 <= 4294967295 &&
            $2 == "from" && $3 == "all" && $4 == "iif" && wanted[$5] &&
            $6 == "lookup" && $7 == "2022" {
            priority = $1; sub(/:$/, "", priority); print priority "|" $5
        }
    '
)

magicnet_hotspot_delete_rule() (
    _delete_priority="$1"
    _delete_iface="$2"
    _delete_attempt=0
    while [ "$_delete_attempt" -lt 8 ]; do
        _present_rc=0
        magicnet_hotspot_rule_present "$_delete_priority" "$_delete_iface" || _present_rc=$?
        case "$_present_rc" in
        0) ;;
        1) return 0 ;;
        *) return 2 ;;
        esac
        _delete_rules="$(ip rule show 2>/dev/null)" || return 2
        printf '%s\n' "$_delete_rules" | awk -v priority="${_delete_priority}:" -v iface="$_delete_iface" '
            $1 == priority {
                iif = table = ""
                for (i = 2; i < NF; i++) {
                    if ($i == "iif") iif = $(i + 1)
                    if ($i == "lookup") table = $(i + 1)
                }
                if (iif == iface && table == "2022" &&
                    !(NF == 7 && $2 == "from" && $3 == "all" && $4 == "iif" && $6 == "lookup")) ambiguous = 1
            }
            END { exit ambiguous ? 1 : 0 }
        ' || return 2
        ip rule del priority "$_delete_priority" iif "$_delete_iface" lookup 2022 \
            >/dev/null 2>&1 || return 1
        _delete_attempt=$((_delete_attempt + 1))
    done
    _present_rc=0
    magicnet_hotspot_rule_present "$_delete_priority" "$_delete_iface" || _present_rc=$?
    [ "$_present_rc" -eq 1 ]
)

magicnet_hotspot_return_peer_valid() {
    printf '%s\n' "$1" | awk -F/ '
        NF != 2 || $2 != "32" { exit 1 }
        {
            if (split($1, octets, ".") != 4) exit 1
            for (i = 1; i <= 4; i++)
                if (octets[i] !~ /^[0-9]+$/ || length(octets[i]) > 3 ||
                    (length(octets[i]) > 1 && substr(octets[i], 1, 1) == "0") || octets[i] + 0 > 255) exit 1
            if (octets[1] + 0 == 0 || octets[1] + 0 == 127 || octets[1] + 0 >= 224) exit 1
        }
        END { if (NR != 1) exit 1 }
    '
}

# Observe the live TUN, never the desired config or a hard-coded subnet.
# sing-tun's system TCP path (also used by mixed) maps to local address + 1.
# Return local|peer|peer/32 only when one address and its connected main route
# agree. 1 means missing evidence, 2 means an unreadable/ambiguous observation.
magicnet_hotspot_return_path() (
    _return_addresses="$(ip -4 -o addr show dev magicnet0 2>/dev/null)" || return 2
    _return_address="$(printf '%s\n' "$_return_addresses" | awk '
        function ip(number, a, b, c, d) {
            a = int(number / 16777216); b = int(number / 65536) % 256
            c = int(number / 256) % 256; d = number % 256
            return a "." b "." c "." d
        }
        NF {
            if ($2 != "magicnet0" || $3 != "inet") { bad = 1; next }
            count++
            if (split($4, cidr, "/") != 2 || cidr[2] !~ /^[1-9][0-9]*$/ ||
                length(cidr[2]) > 2 || cidr[2] + 0 < 8 || cidr[2] + 0 > 30 ||
                split(cidr[1], octets, ".") != 4) { bad = 1; next }
            number = 0
            for (i = 1; i <= 4; i++) {
                if (octets[i] !~ /^[0-9]+$/ || length(octets[i]) > 3 ||
                    (length(octets[i]) > 1 && substr(octets[i], 1, 1) == "0") || octets[i] + 0 > 255) bad = 1
                number = number * 256 + octets[i]
            }
            if (octets[1] + 0 == 0 || octets[1] + 0 == 127 || octets[1] + 0 >= 224) bad = 1
            # BusyBox awk can omit libm/pow support; this bounded integer loop
            # works on those Android-style builds as well.
            size = 1
            for (bit = cidr[2] + 0; bit < 32; bit++) size *= 2
            if (number % size >= size - 2) bad = 1
            local = cidr[1]; peer = ip(number + 1)
            network = ip(int(number / size) * size) "/" cidr[2]
        }
        END {
            if (bad || count > 1) exit 2
            if (!count) exit 1
            print local "|" peer "|" peer "/32|" network
        }
    ')" || return $?
    _return_network="${_return_address##*|}"
    _return_tuple="${_return_address%|*}"
    _return_local="${_return_tuple%%|*}"
    _return_routes="$(ip -4 route show table main dev magicnet0 scope link 2>/dev/null)" || return 2
    printf '%s\n' "$_return_routes" | awk -v network="$_return_network" -v local="$_return_local" '
        $1 == network {
            count++; valid = 1
            # Some iproute2 versions omit selectors already supplied on the
            # command line. If printed, they must still match exactly.
            for (i = 2; i <= NF; i++) {
                if ($i == "via") valid = 0
                if ($i == "dev" && $(i + 1) != "magicnet0") valid = 0
                if ($i == "scope" && $(i + 1) != "link") valid = 0
                if ($i == "src" && $(i + 1) != local) valid = 0
            }
            if (valid) found++
        }
        END { if (count > 1) exit 2; exit found == 1 ? 0 : 1 }
    ' || return $?
    printf '%s\n' "$_return_tuple"
)

magicnet_hotspot_return_path_ready() (
    _return_local="$1"
    _return_peer="$2"
    magicnet_hotspot_return_peer_valid "${_return_local}/32" &&
        magicnet_hotspot_return_peer_valid "${_return_peer}/32" || return 2
    # Do not force oif: that would hide the Android RPDB decision we need to
    # verify. UID 0 remains excluded from general TUN interception.
    _return_lookup="$(ip -4 route get "$_return_peer" from "$_return_local" uid 0 2>/dev/null)" || return 2
    printf '%s\n' "$_return_lookup" | awk -v peer="$_return_peer" -v local="$_return_local" '
        $1 == peer || ($1 == "local" && $2 == peer) {
            count++; dev = source = ""; via = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") dev = $(i + 1)
                if ($i == "from") source = $(i + 1)
                if ($i == "via") via = 1
            }
            if (dev == "magicnet0" && source == local && !via && $1 == peer) ready++
        }
        END { if (count != 1) exit 2; exit ready == 1 ? 0 : 1 }
    '
)

magicnet_hotspot_return_rule_present() (
    _check_priority="$1"
    _check_peer="$2"
    magicnet_hotspot_return_peer_valid "$_check_peer" || return 2
    _check_rules="$(ip -4 rule show 2>/dev/null)" || return 2
    printf '%s\n' "$_check_rules" | awk \
        -v priority="${_check_priority}:" -v cidr="$_check_peer" -v peer="${_check_peer%/32}" '
        NF == 7 && $1 == priority && $2 == "from" && $3 == "all" &&
            $4 == "to" && ($5 == cidr || $5 == peer) && $6 == "lookup" &&
            ($7 == "main" || $7 == "254") { found = 1 }
        END { exit !found }
    '
)

magicnet_hotspot_delete_return_rule() (
    _delete_priority="$1"
    _delete_peer="$2"
    _delete_attempt=0
    while [ "$_delete_attempt" -lt 8 ]; do
        _present_rc=0
        magicnet_hotspot_return_rule_present "$_delete_priority" "$_delete_peer" || _present_rc=$?
        case "$_present_rc" in 0) ;; 1) return 0 ;; *) return 2 ;; esac
        _delete_rules="$(ip -4 rule show 2>/dev/null)" || return 2
        printf '%s\n' "$_delete_rules" | awk \
            -v priority="${_delete_priority}:" -v cidr="$_delete_peer" -v peer="${_delete_peer%/32}" '
            $1 == priority {
                destination = table = ""
                for (i = 2; i < NF; i++) {
                    if ($i == "to") destination = $(i + 1)
                    if ($i == "lookup") table = $(i + 1)
                }
                if ((destination == cidr || destination == peer) && (table == "main" || table == "254") &&
                    !(NF == 7 && $2 == "from" && $3 == "all" && $4 == "to" && $6 == "lookup")) ambiguous = 1
            }
            END { exit ambiguous ? 1 : 0 }
        ' || return 2
        ip -4 rule del priority "$_delete_priority" to "$_delete_peer" lookup main >/dev/null 2>&1 || return 1
        _delete_attempt=$((_delete_attempt + 1))
    done
    _present_rc=0
    magicnet_hotspot_return_rule_present "$_delete_priority" "$_delete_peer" || _present_rc=$?
    [ "$_present_rc" -eq 1 ]
)

magicnet_hotspot_choose_return_rule_priority() (
    _return_reserved="${1:-}"
    _return_rules="$(ip -4 rule show 2>/dev/null)" || return 2
    _return_priority="$(printf '%s\n' "$_return_rules" | awk '
        NF {
            if ($1 !~ /^[0-9]+:$/ || $1 + 0 > 4294967295) { bad = 1; next }
            priority = $1 + 0
            if (priority > 0 && (!found || priority < first)) { first = priority; found = 1 }
        }
        END { if (bad) exit 2; print found ? first - 1 : 8999 }
    ')" || return $?
    [ "$_return_priority" != "$_return_reserved" ] || _return_priority=$((_return_priority - 1))
    [ "$_return_priority" -gt 0 ] || return 1
    printf '%s\n' "$_return_priority"
)

# sing-box auto_redirect installs a global IPv6 TPROXY in mangle PREROUTING.
# Hotspot clients arrive on PREROUTING of the tether iface, not local OUTPUT.
# Insert an interface-scoped ACCEPT so downstream IPv6 is forwarded natively
# instead of being half-hijacked into the core. This is an exemption only;
# it does not install TPROXY, Redirect, or netd ALLOW_MULTI rules.
magicnet_hotspot_ipv6_exempt() (
    _mode=$1
    _iface=$2
    magicnet_hotspot_interface_allowed "$_iface" || return 1
    if ! magicnet_cmd_exists ip6tables; then
        return 0
    fi
    # Cleanup must share the capability check: an absent table cannot contain
    # our exemption, and probing its rules would turn a safe skip into failure.
    if command -v magicnet_xtables_table_probe >/dev/null 2>&1; then
        _probe_rc=0
        magicnet_xtables_table_probe ip6tables mangle || _probe_rc=$?
        case "$_probe_rc" in
        0) ;;
        2) return 0 ;;
        *) return "$_probe_rc" ;;
        esac
    fi
    if ! command -v magicnet_ip6tables_cmd >/dev/null 2>&1; then
        return 2
    fi
    set -- PREROUTING -i "$_iface" -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT
    case "$_mode" in
    ensure)
        # Membership is not priority. After a sing-box restart the global
        # TPROXY can sit above a leftover ACCEPT; always re-prepend.
        magicnet_hotspot_ipv6_exempt cleanup "$_iface" || return $?
        magicnet_ip6tables_cmd -t mangle -I "$@" || return 1
        ;;
    status)
        _rc=0
        magicnet_ip6tables_cmd -t mangle -C "$@" >/dev/null 2>&1 || _rc=$?
        case "$_rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
        # auto_redirect may rebuild its hooks without restarting the core.
        # An exemption that still exists below those hooks is not effective.
        # Other exact interface-scoped exemptions are harmless predecessors,
        # so several downstreams can converge without reinstalling each poll.
        _rules="$(magicnet_ip6tables_cmd -t mangle -S PREROUTING 2>/dev/null)" || return 2
        printf '%s\n' "$_rules" | awk -v iface="$_iface" '
            $1 != "-A" || $2 != "PREROUTING" { next }
            {
                gsub(/"/, "")
                if (NF == 10 && $3 == "-i" && $5 == "-m" && $6 == "comment" &&
                    $7 == "--comment" && $8 == "magicnet-hotspot-ipv6-exempt" &&
                    $9 == "-j" && $10 == "ACCEPT") {
                    if ($4 == iface && !found) {
                        found = 1
                        effective = !preceded
                    }
                    next
                }
                if (!found) preceded = 1
            }
            END {
                if (!found) exit 2
                exit effective ? 0 : 1
            }
        '
        ;;
    cleanup)
        # The journal predates the all-protocol exemption. Remove both exact
        # module-owned tuples so upgrading cannot strand its TCP-only rule.
        # Extra selectors or a different interface/comment remain untouched.
        for _protocol in all tcp; do
            set -- PREROUTING -i "$_iface"
            [ "$_protocol" != tcp ] || set -- "$@" -p tcp
            set -- "$@" -m comment --comment magicnet-hotspot-ipv6-exempt -j ACCEPT
            _attempt=0
            while :; do
                _rc=0
                magicnet_ip6tables_cmd -t mangle -C "$@" >/dev/null 2>&1 || _rc=$?
                case "$_rc" in 0) ;; 1) break ;; *) return 2 ;; esac
                [ "$_attempt" -lt 8 ] || return 1
                magicnet_ip6tables_cmd -t mangle -D "$@" >/dev/null 2>&1 || return 1
                _attempt=$((_attempt + 1))
            done
        done ;;
    *) return 1 ;;
    esac
)

magicnet_hotspot_forward_access() (
    _mode=$1
    _iface=$2
    magicnet_hotspot_interface_allowed "$_iface" || return 1
    for _direction in outbound return; do
        if [ "$_direction" = outbound ]; then
            set -- FORWARD -i "$_iface" -o magicnet0 -m comment --comment magicnet-hotspot -j ACCEPT
        else
            set -- FORWARD -i magicnet0 -o "$_iface" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment magicnet-hotspot -j ACCEPT
        fi
        case "$_mode" in
        ensure)
            magicnet_iptables_ensure "$@" || {
                magicnet_hotspot_forward_access cleanup "$_iface" || true
                return 1
            } ;;
        status)
            _rc=0
            magicnet_iptables_cmd -C "$@" >/dev/null 2>&1 || _rc=$?
            case "$_rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac ;;
        cleanup)
            _attempt=0
            while :; do
                _rc=0
                magicnet_iptables_cmd -C "$@" >/dev/null 2>&1 || _rc=$?
                case "$_rc" in 0) ;; 1) break ;; *) return 2 ;; esac
                [ "$_attempt" -lt 8 ] || return 1
                magicnet_iptables_cmd -D "$@" >/dev/null 2>&1 || return 1
                _attempt=$((_attempt + 1))
            done ;;
        *) return 1 ;;
        esac
    done
    _ipv6_rc=0
    magicnet_hotspot_ipv6_exempt "$_mode" "$_iface" || _ipv6_rc=$?
    if [ "$_ipv6_rc" -ne 0 ]; then
        if [ "$_mode" = ensure ]; then
            magicnet_hotspot_forward_access cleanup "$_iface" || true
        fi
        return "$_ipv6_rc"
    fi
)

# Private write-ahead journal: publication of tun-rules.list alone is the
# commit point. Interrupted installs retain .pending and never look active.
magicnet_hotspot_route_pending_file() {
    printf '%s.pending\n' "$(magicnet_hotspot_route_state_file)"
}

magicnet_hotspot_route_journal_valid() (
    _journal="$1"
    [ -f "$_journal" ] && [ ! -L "$_journal" ] && [ -r "$_journal" ] || return 2
    [ "$(wc -c <"$_journal")" -le 8192 ] || return 2
    awk -F'|' '
        function priority(value) { return value ~ /^[1-9][0-9]*$/ && value + 0 <= 4294967295 }
        NF == 2 && priority($1) { next }
        NF == 3 && $1 == "return4" && priority($2) { returns++; next }
        { bad = 1 }
        END { exit bad || returns > 1 ? 2 : 0 }
    ' "$_journal" || return 2
    while IFS='|' read -r _kind _value _peer || [ -n "$_kind$_value$_peer" ]; do
        if [ "$_kind" = return4 ]; then
            magicnet_hotspot_return_peer_valid "$_peer" || return 2
        else
            magicnet_hotspot_interface_allowed "$_value" || return 2
        fi
    done <"$_journal"
)

magicnet_hotspot_route_cleanup() {
    magicnet_with_config_lock magicnet_hotspot_route_cleanup_locked
}

magicnet_hotspot_route_cleanup_locked() (
    _state="$(magicnet_hotspot_route_state_file)"
    _pending="$(magicnet_hotspot_route_pending_file)"
    [ -e "$_state" ] || [ -e "$_pending" ] || [ -L "$_state" ] || [ -L "$_pending" ] || return 0
    # Validate every journal before removing the first resource.
    for _file in "$_state" "$_pending"; do
        [ -e "$_file" ] || [ -L "$_file" ] || continue
        magicnet_hotspot_route_journal_valid "$_file" || return 2
    done
    # A partial cleanup must stop advertising an earlier installation as active.
    if [ -f "$_state" ] && [ ! -e "$_pending" ]; then
        _tmp="${_pending}.new.$$"
        if ! (umask 077; cat "$_state" >"$_tmp") || ! mv -f "$_tmp" "$_pending"; then
            rm -f "$_tmp"
            return 1
        fi
    fi
    # Older concurrent writers could overwrite each other's priority in the
    # journal. Recover all exact ingress copies for journal-owned interfaces,
    # recording them before deletion so an interrupted cleanup can retry.
    set --
    for _file in "$_state" "$_pending"; do
        [ ! -f "$_file" ] || set -- "$@" "$_file"
    done
    _owned_ifaces="$(awk -F'|' 'NF == 2 && !seen[$2]++ { print $2 }' "$@")" || return 2
    _observed="$(magicnet_hotspot_observed_rules "$_owned_ifaces")" || return 2
    _tmp="${_pending}.new.$$"
    if ! (
        umask 077
        { cat "$_pending"; printf '%s\n' "$_observed"; } |
            awk 'NF && !seen[$0]++' >"$_tmp"
    ) || ! magicnet_hotspot_route_journal_valid "$_tmp" || ! mv -f "$_tmp" "$_pending"; then
        rm -f "$_tmp"
        return 1
    fi
    _cleanup_records="$(awk 'NF && !seen[$0]++' "$@")" || return 2
    _rc=0
    for _iface in $_owned_ifaces; do
        magicnet_hotspot_forward_access cleanup "$_iface" || _rc=1
    done
    while IFS='|' read -r _priority _iface _peer || [ -n "$_priority$_iface$_peer" ]; do
        if [ "$_priority" = return4 ]; then
            magicnet_hotspot_delete_return_rule "$_iface" "$_peer" || _rc=1
        else
            magicnet_hotspot_delete_rule "$_priority" "$_iface" || _rc=1
        fi
    done <<EOF
$_cleanup_records
EOF
    [ "$_rc" -eq 0 ] || return "$_rc"
    rm -f "$_state" "$_pending"
)

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
    _hotspot_rules="$(ip rule show 2>/dev/null)" || return 2
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

magicnet_hotspot_tun_route_table_ready() (
    magicnet_iface_exists magicnet0 || return 1
    _route_table=2022
    if command -v magicnet_kernel_route_table >/dev/null 2>&1; then
        _route_table="$(magicnet_kernel_route_table)" || return 2
    fi
    _route_output="$(ip route show table "$_route_table" 2>/dev/null)" || return 2
    # Token match only. A substring such as magicnet0-extra is not magicnet0.
    printf '%s\n' "$_route_output" | awk '
        { for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == "magicnet0") found = 1 }
        END { exit !found }
    '
)

# A saved file is recovery evidence, not proof that the kernel still matches.
magicnet_hotspot_routes_current() (
    _current_pairs="$1"
    _current_file="$(magicnet_hotspot_route_state_file)"
    [ ! -e "$(magicnet_hotspot_route_pending_file)" ] &&
        [ ! -L "$(magicnet_hotspot_route_pending_file)" ] || return 1
    [ -f "$_current_file" ] || return 1
    magicnet_hotspot_route_journal_valid "$_current_file" || return 2
    _current_saved="$(cat "$_current_file")" || return 2
    _current_expected="$(printf '%s\n' "$_current_pairs" | awk -F'|' 'NF == 2 {print $1}' | sort -u)"
    _current_ifaces="$(printf '%s\n' "$_current_saved" | awk -F'|' 'NF == 2 {print $2}' | sort -u)"
    [ -n "$_current_expected" ] && [ "$_current_ifaces" = "$_current_expected" ] || return 1
    _current_observed="$(magicnet_hotspot_observed_rules "$_current_ifaces")" || return 2
    _current_duplicates="$(printf '%s\n' "$_current_observed" | awk -F'|' 'NF == 2 && seen[$2]++ { n++ } END { print n+0 }')"
    [ "$_current_duplicates" -eq 0 ] || return 1
    _current_return="$(magicnet_hotspot_return_path)" || return $?
    _current_return_local="${_current_return%%|*}"
    _current_return_cidr="${_current_return##*|}"
    _current_return_count=0
    while IFS='|' read -r _current_priority _current_iface _current_peer; do
        if [ "$_current_priority" = return4 ]; then
            [ "$_current_peer" = "$_current_return_cidr" ] || return 1
            magicnet_hotspot_return_rule_present "$_current_iface" "$_current_peer" || return $?
            _current_return_count=$((_current_return_count + 1))
        else
            magicnet_hotspot_rule_present "$_current_priority" "$_current_iface" || return $?
            magicnet_hotspot_forward_access status "$_current_iface" || return $?
        fi
    done <<EOF
$_current_saved
EOF
    [ "$_current_return_count" -eq 1 ] || return 1
    magicnet_hotspot_return_path_ready "$_current_return_local" "${_current_return_cidr%/32}"
)

magicnet_hotspot_reconcile() {
    magicnet_with_config_lock magicnet_hotspot_reconcile_locked
}

magicnet_hotspot_reconcile_locked() (
    if ! magicnet_hotspot_proxy_enabled; then
        magicnet_hotspot_route_cleanup
        return $?
    fi
    _hotspot_transparent_mode="$(magicnet_transparent_mode)" || return 1
    if [ "$_hotspot_transparent_mode" = ebpf ]; then
        # Shared-network TC owns downstream interception in eBPF mode. Never
        # retain the TUN-only table 2022 policy rules across a mode switch.
        magicnet_hotspot_route_cleanup
        _hotspot_ebpf_reconcile_rc=$?
        unset _hotspot_transparent_mode
        return "$_hotspot_ebpf_reconcile_rc"
    fi
    [ "$_hotspot_transparent_mode" = tun ] || return 2
    unset _hotspot_transparent_mode

    # The selector can be enabled before sing-box has created magicnet0. That
    # is a valid pending state; the post-start pass and the watcher will retry
    # once the TUN route table exists. A present but incomplete TUN is a real
    # failure and must remain visible to the caller/status output.
    _hotspot_ready_rc=0
    magicnet_hotspot_tun_route_table_ready || _hotspot_ready_rc=$?
    case "$_hotspot_ready_rc" in
    0) ;;
    1)
        magicnet_hotspot_route_cleanup || return 1
        magicnet_iface_exists magicnet0 || return 0
        magicnet_warn "magicnet0 route table 2022 is unavailable; hotspot forwarding is not intercepted"
        return 1
        ;;
    *) return 2 ;;
    esac

    _hotspot_pairs="$(magicnet_hotspot_active_networks)" || return 2
    _hotspot_pairs="$(printf '%s\n' "$_hotspot_pairs" | awk -F'|' 'NF == 2 && !seen[$1]++')"
    if [ -n "$_hotspot_pairs" ]; then
        # Read all address evidence before replacing any existing resources.
        # A failed/ambiguous observation must not become an empty topology.
        _hotspot_return_path="$(magicnet_hotspot_return_path)" || return $?
        _hotspot_return_local="${_hotspot_return_path%%|*}"
        _hotspot_return_cidr="${_hotspot_return_path##*|}"
    fi
    _hotspot_current_rc=0
    magicnet_hotspot_routes_current "$_hotspot_pairs" || _hotspot_current_rc=$?
    case "$_hotspot_current_rc" in
    0) unset _hotspot_pairs; return 0 ;;
    1) ;;
    *) unset _hotspot_pairs; return 2 ;;
    esac
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
    _hotspot_return_priority="$(magicnet_hotspot_choose_return_rule_priority "$_hotspot_priority")" || return $?
    _hotspot_state_file="$(magicnet_hotspot_route_state_file)"
    _hotspot_pending="$(magicnet_hotspot_route_pending_file)"
    _hotspot_state_tmp="${_hotspot_pending}.new.$$"
    # Record the exact planned tuples BEFORE either iptables or ip rule writes.
    if ! mkdir -p "${_hotspot_pending%/*}" || ! (
        umask 077
        printf '%s\n' "$_hotspot_pairs" | awk -F'|' -v priority="$_hotspot_priority" \
            'NF == 2 { print priority "|" $1 }' >"$_hotspot_state_tmp" &&
        printf 'return4|%s|%s\n' "$_hotspot_return_priority" "$_hotspot_return_cidr" >>"$_hotspot_state_tmp"
    ) || ! mv -f "$_hotspot_state_tmp" "$_hotspot_pending"; then
        rm -f "$_hotspot_state_tmp"
        return 1
    fi
    _hotspot_add_rc=0
    if ! ip -4 rule add priority "$_hotspot_return_priority" to "$_hotspot_return_cidr" lookup main >/dev/null 2>&1; then
        _hotspot_add_rc=1
    else
        magicnet_hotspot_return_rule_present "$_hotspot_return_priority" "$_hotspot_return_cidr" || _hotspot_add_rc=$?
    fi
    while [ "$_hotspot_add_rc" -eq 0 ] && IFS='|' read -r _hotspot_iface _hotspot_cidr; do
        [ -n "$_hotspot_iface" ] || continue
        if ! magicnet_hotspot_forward_access ensure "$_hotspot_iface" ||
            ! ip rule add priority "$_hotspot_priority" iif "$_hotspot_iface" lookup 2022 >/dev/null 2>&1 ||
            ! magicnet_hotspot_rule_present "$_hotspot_priority" "$_hotspot_iface" ||
            ! magicnet_hotspot_forward_access status "$_hotspot_iface"; then
            _hotspot_add_rc=1
            break
        fi
    done <<EOF
$_hotspot_pairs
EOF
    if [ "$_hotspot_add_rc" -eq 0 ]; then
        magicnet_hotspot_return_path_ready "$_hotspot_return_local" "${_hotspot_return_cidr%/32}" || _hotspot_add_rc=$?
    fi
    if [ "$_hotspot_add_rc" -ne 0 ] || ! mv -f "$_hotspot_pending" "$_hotspot_state_file"; then
        # Cleanup deletes the journal ONLY after all recorded resources are
        # verified absent. Failure is visible and a subsequent stop can retry.
        magicnet_hotspot_route_cleanup || magicnet_warn "Hotspot rollback incomplete; pending journal retained."
        [ "$_hotspot_add_rc" -ne 0 ] || _hotspot_add_rc=1
        return "$_hotspot_add_rc"
    fi
    unset _hotspot_pairs _hotspot_first_iface _hotspot_priority _hotspot_state_file _hotspot_state_tmp
    unset _hotspot_add_rc _hotspot_pending _hotspot_iface _hotspot_cidr
)

magicnet_hotspot_route_status() (
    _hotspot_mode="$(magicnet_transparent_mode 2>/dev/null)" || {
        printf 'route_status=unknown\n'
        return 0
    }
    if [ "$_hotspot_mode" = ebpf ]; then
        # TUN state cannot prove TC attachment; transparent status verifies it.
        if magicnet_hotspot_proxy_enabled; then printf 'route_status=shared-tc-unverified\n'; else printf 'route_status=disabled\n'; fi
        return 0
    fi
    [ "$_hotspot_mode" = tun ] || { printf 'route_status=unknown\n'; return 0; }
    _hotspot_state_file="$(magicnet_hotspot_route_state_file)"
    _hotspot_pending_file="$(magicnet_hotspot_route_pending_file)"
    _hotspot_ready_rc=0
    magicnet_hotspot_tun_route_table_ready || _hotspot_ready_rc=$?
    case "$_hotspot_ready_rc" in
    0) printf 'route_table_ready=1\n' ;;
    1) printf 'route_table_ready=0\n' ;;
    *) printf 'route_table_ready=unknown\n' ;;
    esac
    _hotspot_discovery_error=0
    _hotspot_pairs="$(magicnet_hotspot_active_networks)" || _hotspot_discovery_error=1
    _hotspot_expected_rule_count="$(printf '%s\n' "$_hotspot_pairs" | awk -F'|' 'NF == 2 && !seen[$1]++ { n++ } END { print n+0 }')"
    _hotspot_interfaces="$(printf '%s\n' "$_hotspot_pairs" | awk -F'|' 'NF && !seen[$1]++ { print $1 }' | tr '\n' ',' | sed 's/,$//')"
    _hotspot_networks="$(printf '%s\n' "$_hotspot_pairs" | awk -F'|' 'NF && !seen[$2]++ { print $2 }' | tr '\n' ',' | sed 's/,$//')"
    printf 'downstream_interfaces=%s\n' "${_hotspot_interfaces:-none}"
    printf 'downstream_networks=%s\n' "${_hotspot_networks:-none}"
    _hotspot_return_rc=1
    _hotspot_return_path=
    _hotspot_inventory_present=0
    if [ -e "$_hotspot_state_file" ] || [ -L "$_hotspot_state_file" ]; then
        _hotspot_inventory_present=1
    fi
    # Enabling the selector before a hotspot/TUN exists is a normal wait. Do
    # not turn that into a failed address query; retained ownership still needs
    # observation so a stale or interrupted installation cannot look clean.
    if [ -n "$_hotspot_pairs" ] || [ "$_hotspot_inventory_present" -ne 0 ] ||
        [ -e "$_hotspot_pending_file" ] || [ -L "$_hotspot_pending_file" ]; then
        _hotspot_return_rc=0
        _hotspot_return_path="$(magicnet_hotspot_return_path)" || _hotspot_return_rc=$?
    fi
    _hotspot_return_cidr="${_hotspot_return_path##*|}"
    if [ "$_hotspot_return_rc" -eq 0 ]; then
        magicnet_hotspot_return_path_ready "${_hotspot_return_path%%|*}" "${_hotspot_return_cidr%/32}" || _hotspot_return_rc=$?
    fi
    case "$_hotspot_return_rc" in
    0) printf 'return_route_ready=1\n' ;;
    1) printf 'return_route_ready=0\n' ;;
    *) printf 'return_route_ready=unknown\n' ;;
    esac
    _hotspot_rule_count=0
    _hotspot_missing_rule_count=0
    _hotspot_return_rule_count=0
    _hotspot_rule_unknown=0
    _hotspot_observed_ifaces="$(printf '%s\n' "$_hotspot_pairs" | awk -F'|' 'NF == 2 {print $1}')"
    if [ -e "$_hotspot_state_file" ] || [ -L "$_hotspot_state_file" ]; then
        if magicnet_hotspot_route_journal_valid "$_hotspot_state_file"; then
            while IFS='|' read -r _hotspot_priority _hotspot_iface _hotspot_peer ||
                [ -n "$_hotspot_priority$_hotspot_iface$_hotspot_peer" ]; do
                _hotspot_rule_rc=0
                if [ "$_hotspot_priority" = return4 ]; then
                    printf 'return_rule=%s to=%s table=main\n' "$_hotspot_iface" "$_hotspot_peer"
                    magicnet_hotspot_return_rule_present "$_hotspot_iface" "$_hotspot_peer" || _hotspot_rule_rc=$?
                    if [ "$_hotspot_rule_rc" -eq 0 ] && [ "$_hotspot_peer" = "$_hotspot_return_cidr" ]; then
                        _hotspot_return_rule_count=$((_hotspot_return_rule_count + 1))
                    fi
                else
                    _hotspot_observed_ifaces="${_hotspot_observed_ifaces}
${_hotspot_iface}"
                    printf 'policy_rule=%s iif=%s table=2022\n' "$_hotspot_priority" "$_hotspot_iface"
                    magicnet_hotspot_rule_present "$_hotspot_priority" "$_hotspot_iface" || _hotspot_rule_rc=$?
                    if [ "$_hotspot_rule_rc" -eq 0 ]; then
                        magicnet_hotspot_forward_access status "$_hotspot_iface" || _hotspot_rule_rc=$?
                    fi
                    if [ "$_hotspot_rule_rc" -eq 0 ]; then
                        if printf '%s\n' "$_hotspot_pairs" | awk -F'|' -v iface="$_hotspot_iface" '$1 == iface {found=1} END {exit !found}'; then
                            _hotspot_rule_count=$((_hotspot_rule_count + 1))
                        else
                            _hotspot_missing_rule_count=$((_hotspot_missing_rule_count + 1))
                        fi
                    else
                        _hotspot_missing_rule_count=$((_hotspot_missing_rule_count + 1))
                    fi
                fi
                [ "$_hotspot_rule_rc" -le 1 ] || _hotspot_rule_unknown=1
            done <"$_hotspot_state_file"
        else
            _hotspot_rule_unknown=1
        fi
    fi
    printf 'policy_rule_count=%s\n' "$_hotspot_rule_count"
    printf 'policy_rule_missing=%s\n' "$_hotspot_missing_rule_count"
    _hotspot_pending_present=0
    if [ -e "$_hotspot_pending_file" ] || [ -L "$_hotspot_pending_file" ]; then
        _hotspot_pending_present=1
        if magicnet_hotspot_route_journal_valid "$_hotspot_pending_file"; then
            # A vanished downstream can still have rules from an interrupted
            # install. The pending journal scopes observation, not active state.
            _hotspot_pending_ifaces="$(awk -F'|' 'NF == 2 {print $2}' "$_hotspot_pending_file")"
            _hotspot_observed_ifaces="${_hotspot_observed_ifaces}
${_hotspot_pending_ifaces}"
        else
            _hotspot_rule_unknown=1
        fi
    fi
    _hotspot_observed_count=0
    _hotspot_duplicate_count=0
    if _hotspot_observed="$(magicnet_hotspot_observed_rules "$_hotspot_observed_ifaces")"; then
        _hotspot_observed_count="$(printf '%s\n' "$_hotspot_observed" | awk 'NF {n++} END {print n+0}')"
        _hotspot_duplicate_count="$(printf '%s\n' "$_hotspot_observed" | awk -F'|' 'NF == 2 && seen[$2]++ {n++} END {print n+0}')"
        printf 'policy_rule_observed=%s\npolicy_rule_duplicates=%s\n' "$_hotspot_observed_count" "$_hotspot_duplicate_count"
    else
        _hotspot_rule_unknown=1
        printf 'policy_rule_observed=unknown\npolicy_rule_duplicates=unknown\n'
    fi
    if ! magicnet_hotspot_proxy_enabled; then
        if [ "$_hotspot_rule_unknown" -ne 0 ] || [ "$_hotspot_discovery_error" -ne 0 ]; then
            printf 'route_status=unknown\n'
        elif [ "$_hotspot_pending_present" -ne 0 ]; then
            printf 'route_status=pending\n'
        elif [ "$_hotspot_inventory_present" -ne 0 ] || [ "$_hotspot_observed_count" -ne 0 ]; then
            printf 'route_status=degraded\n'
        else
            printf 'route_status=disabled\n'
        fi
    elif [ "$_hotspot_rule_unknown" -ne 0 ]; then
        printf 'route_status=unknown\n'
    elif [ "$_hotspot_pending_present" -ne 0 ]; then
        printf 'route_status=pending\n'
    elif [ "$_hotspot_ready_rc" -gt 1 ] ||
        [ "$_hotspot_return_rc" -gt 1 ]; then
        printf 'route_status=unknown\n'
    elif [ "$_hotspot_discovery_error" -ne 0 ]; then
        printf 'route_status=degraded\n'
    elif [ -z "$_hotspot_pairs" ]; then
        if [ "$_hotspot_inventory_present" -ne 0 ]; then
            printf 'route_status=pending\n'
        else
            printf 'route_status=waiting-for-hotspot\n'
        fi
    elif [ "$_hotspot_ready_rc" -ne 0 ] || [ "$_hotspot_rule_count" -ne "$_hotspot_expected_rule_count" ] ||
        [ "$_hotspot_observed_count" -ne "$_hotspot_expected_rule_count" ] || [ "$_hotspot_duplicate_count" -ne 0 ] ||
        [ "$_hotspot_missing_rule_count" -ne 0 ] || [ "$_hotspot_return_rule_count" -ne 1 ] ||
        [ "$_hotspot_return_rc" -ne 0 ]; then
        printf 'route_status=degraded\n'
    else
        printf 'route_status=ready\n'
    fi
)

magicnet_hotspot_offload_value() (
    command -v settings >/dev/null 2>&1 || return 1
    # Preserve the producer exit status; tr/sed success cannot prove a read.
    _value="$(settings get global tether_offload_disabled 2>/dev/null)" || return 1
    _value="$(printf '%s' "$_value" | tr -d '\r')"
    case "$_value" in '' | null | 0 | 1) printf '%s\n' "$_value" ;; *) return 1 ;; esac
)

# Service stop restores Android offload and removes only our ownership
# evidence. Before the next core snapshots its policy, recover the user's
# existing selector intent; replaying the API selector alone is too late.
magicnet_hotspot_offload_prepare() (
    _selections="${MODDIR}/.config/magicnet/selector-selections.json"
    if [ ! -e "$_selections" ] && [ ! -L "$_selections" ]; then
        _selections="${MODDIR}/.state/sing-box/selector-selections.json"
        # Preserve the migration-era enable path if no selector was ever saved.
        [ -e "$_selections" ] || [ -L "$_selections" ] || return 0
    fi
    [ -f "$_selections" ] && [ ! -L "$_selections" ] || return 2
    _size="$(wc -c <"$_selections")" || return 2
    [ "$_size" -le 4194304 ] 2>/dev/null || return 2
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || return 2
    _member="$("$_jq" -er '
        select(type == "object" and all(.[]; type == "string"))
        | if has("hotspot") then .hotspot else "direct" end
        | select(. == "direct" or . == "proxy")
    ' "$_selections" 2>/dev/null)" || return 2
    case "$_member" in
    proxy) magicnet_hotspot_offload_enable ;;
    direct) magicnet_hotspot_offload_restore ;;
    *) return 2 ;;
    esac
)

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
        if ! (umask 077; printf '%s\n' "$_hotspot_saved" >"$_hotspot_tmp") ||
            ! mv -f "$_hotspot_tmp" "$_hotspot_state"; then
            rm -f "$_hotspot_tmp" 2>/dev/null || true
            unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved _hotspot_tmp _hotspot_current
            return 1
        fi
        _hotspot_state_created=1
        # The shipped uninstall hook uses the same locked lifecycle cleanup.
        # Never append a second, unverified rule deleter to uninstall.sh.
    fi
    _hotspot_current="$(magicnet_hotspot_offload_value)" || {
        magicnet_warn "Android settings state is unknown; offload was not changed"
        unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved _hotspot_tmp _hotspot_current
        return 1
    }
    if [ "$_hotspot_current" = 1 ]; then
        unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved _hotspot_tmp _hotspot_current
        return 0
    fi
    if ! settings put global tether_offload_disabled 1 >/dev/null 2>&1 ||
        ! _hotspot_current="$(magicnet_hotspot_offload_value)" ||
        [ "$_hotspot_current" != 1 ]; then
        magicnet_warn "Failed to disable Android tether offload"
        if [ "$_hotspot_state_created" -eq 1 ]; then
            magicnet_hotspot_offload_restore >/dev/null 2>&1 || true
        fi
        unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved _hotspot_tmp _hotspot_current
        return 1
    fi
    unset _hotspot_state _hotspot_state_created _hotspot_previous _hotspot_saved _hotspot_tmp _hotspot_current
}

magicnet_hotspot_offload_restore() {
    magicnet_hotspot_offload_restore_impl required
}

# Only stopped lifecycle finalization may reuse cleanup completed in the same
# locked operation. Independent callers always use the full restore above.
magicnet_hotspot_offload_restore_after_route_cleanup() {
    magicnet_hotspot_offload_restore_impl complete
}

magicnet_hotspot_offload_restore_impl() (
    _hotspot_cleanup="${1:-}"
    case "$_hotspot_cleanup" in required | complete) ;; *) return 2 ;; esac
    _hotspot_state="$(magicnet_hotspot_offload_state_file)"
    [ ! -L "$_hotspot_state" ] || return 1
    [ -e "$_hotspot_state" ] || {
        [ "$_hotspot_cleanup" != complete ] || return 0
        magicnet_hotspot_route_cleanup
        return $?
    }
    [ -f "$_hotspot_state" ] && [ -r "$_hotspot_state" ] || return 1
    [ "$(wc -c <"$_hotspot_state")" -le 32 ] || return 1
    _hotspot_previous="$(cat "$_hotspot_state")" || return 1
    case "$_hotspot_previous" in
    unset) _hotspot_expected=null ;;
    value=0 | value=1) _hotspot_expected="${_hotspot_previous#value=}" ;;
    *)
        magicnet_warn "Invalid saved tether offload state; refusing to restore it"
        return 1 ;;
    esac
    _hotspot_current="$(magicnet_hotspot_offload_value)" || return 1
    [ -n "$_hotspot_current" ] || _hotspot_current=null
    # An external writer may have changed the setting while MagicNet ran.
    # Restore only our installed value, or recognize an already-restored value.
    if [ "$_hotspot_current" != "$_hotspot_expected" ] && [ "$_hotspot_current" != 1 ]; then
        magicnet_warn "Tether offload ownership changed; rollback state retained."
        return 1
    fi
    if [ "$_hotspot_cleanup" = required ]; then
        magicnet_hotspot_route_cleanup || return 1
    fi
    if [ "$_hotspot_current" != "$_hotspot_expected" ]; then
        case "$_hotspot_previous" in
        unset) settings delete global tether_offload_disabled >/dev/null 2>&1 || return 1 ;;
        *) settings put global tether_offload_disabled "$_hotspot_expected" >/dev/null 2>&1 || return 1 ;;
        esac
    fi
    _hotspot_current="$(magicnet_hotspot_offload_value)" || return 1
    [ -n "$_hotspot_current" ] || _hotspot_current=null
    [ "$_hotspot_current" = "$_hotspot_expected" ] || return 1
    rm -f "$_hotspot_state"
)

magicnet_hotspot_offload_status() {
    if _hotspot_value="$(magicnet_hotspot_offload_value 2>/dev/null)"; then
        case "$_hotspot_value" in
        1) printf 'offload_disabled=1\n' ;;
        *) printf 'offload_disabled=0\n' ;;
        esac
    else
        printf 'offload_disabled=unknown\n'
    fi
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
    if (
        umask 077
        "$_jq" --argjson hotspot_sources "$_hotspot_sources_json" '
        def hotspot_selector:
          # Standalone configs need not contain the managed proxy/direct tags.
          # Never publish a selector member that the core cannot resolve.
          ([.outbounds[]? | .tag | select(type == "string" and . != "hotspot")]) as $tags
          | (["direct", "proxy"] | map(select(. as $tag | $tags | index($tag) != null))) as $managed
          | (if ($managed | length) > 0 then $managed
             elif (.route.final as $final | $tags | index($final)) != null then [.route.final]
             elif ($tags | length) > 0 then [$tags[0]]
             else error("hotspot selector requires an existing outbound")
             end) as $members
          |
          {
            "type": "selector",
            "tag": "hotspot",
            "outbounds": $members,
            "default": $members[0],
            "interrupt_exist_connections": true
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
    ' "$_hotspot_render_source" >"$_hotspot_render_target"
    ) && chmod 600 "$_hotspot_render_target"; then
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

# Predicate status: 0=current, 1=confirmed change, 2=indeterminate.
magicnet_singbox_hotspot_policy_current() (
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _tmp="$(magicnet_config_staging_file "$_config" hotspot-policy.check)" || return 2
    if magicnet_singbox_render_hotspot_policy "$_config" "$_tmp"; then
        _hotspot_policy_rc=0
        magicnet_ebpf_hotspot_config_current || _hotspot_policy_rc=$?
        if [ "$_hotspot_policy_rc" -eq 0 ]; then
            # Config editors and override materialization may use compact JSON
            # or reorder object keys. Only semantic changes require a restart.
            _hotspot_compare_jq="$(magicnet_hotspot_jq)"
            if "$_hotspot_compare_jq" -e -s '.[0] == .[1]' "$_config" "$_tmp" >/dev/null; then
                _hotspot_policy_rc=0
            else
                _hotspot_policy_rc=$?
                [ "$_hotspot_policy_rc" -eq 1 ] || _hotspot_policy_rc=2
            fi
        fi
    else
        _hotspot_policy_rc=2
    fi
    rm -f "$_tmp" 2>/dev/null || true
    return "$_hotspot_policy_rc"
)

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
    type magicnet_singbox_insert_route_rules >/dev/null 2>&1 || {
        _route_rules_lib="${MODDIR}/lib/magicnet/singbox_route_rules.sh"
        if [ ! -f "$_route_rules_lib" ] && type magicnet_lib_dir >/dev/null 2>&1; then
            _route_rules_lib="$(magicnet_lib_dir)/singbox_route_rules.sh"
        fi
        . "$_route_rules_lib"
        unset _route_rules_lib
    }
    if ! magicnet_singbox_insert_route_rules "$_config" "$_tmp" "$_rules_file" route; then
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
