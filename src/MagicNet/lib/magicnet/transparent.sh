# shellcheck shell=ash

magicnet_ebpf_active_networks() {
    magicnet_hotspot_proxy_enabled || return 0
    magicnet_hotspot_active_networks |
        while IFS='|' read -r _ebpf_iface _ebpf_cidr _ebpf_extra; do
            [ -n "$_ebpf_iface" ] && [ -n "$_ebpf_cidr" ] && [ -z "$_ebpf_extra" ] || continue
            case "$_ebpf_iface" in
            *[!A-Za-z0-9_.:-]* | '') continue ;;
            esac
            magicnet_hotspot_interface_allowed "$_ebpf_iface" || continue
            magicnet_iface_exists "$_ebpf_iface" || continue
            if printf '%s\n' "$_ebpf_cidr" | awk '
                function octet(value) {
                    return value ~ /^[0-9]+$/ && length(value) <= 3 &&
                        (length(value) == 1 || substr(value, 1, 1) != "0") &&
                        value + 0 <= 255
                }
                {
                    if (split($0, cidr, "/") != 2 || cidr[2] !~ /^[0-9]+$/ || cidr[2] + 0 > 32) exit 1
                    if (split(cidr[1], address, ".") != 4) exit 1
                    for (i = 1; i <= 4; i++) if (!octet(address[i])) exit 1
                }
            '; then
                printf '%s|%s\n' "$_ebpf_iface" "$_ebpf_cidr"
            fi
        done | LC_ALL=C sort -u
}

magicnet_ebpf_state_dir() {
    printf '%s\n' "${MODDIR}/.state/transparent-ebpf"
}

magicnet_ebpf_probe_report() {
    printf '%s\n' "$(magicnet_ebpf_state_dir)/probe.json"
}

magicnet_ebpf_publish_state() {
    _ebpf_state_mode="$1"
    _ebpf_state_pairs="$2"
    _ebpf_state_dir="$(magicnet_ebpf_state_dir)"
    mkdir -p "$_ebpf_state_dir" || return 1
    _ebpf_state_interfaces_tmp="${_ebpf_state_dir}/shared-interfaces.list.tmp.$$"
    if [ "$_ebpf_state_mode" = ebpf ]; then
        awk -F'|' 'NF == 2 && !seen[$1]++ { print $1 }' "$_ebpf_state_pairs" >"$_ebpf_state_interfaces_tmp" || return 1
    else
        : >"$_ebpf_state_interfaces_tmp" || return 1
    fi
    if ! chmod 600 "$_ebpf_state_interfaces_tmp" ||
        ! mv -f "$_ebpf_state_interfaces_tmp" "${_ebpf_state_dir}/shared-interfaces.list"; then
        rm -f "$_ebpf_state_interfaces_tmp" 2>/dev/null || true
        return 1
    fi
    if [ "$_ebpf_state_mode" = ebpf ] && magicnet_hotspot_proxy_enabled && [ ! -s "$_ebpf_state_pairs" ]; then
        _ebpf_pending_tmp="${_ebpf_state_dir}/shared.pending.tmp.$$"
        if ! (
            umask 077
            printf '%s\n' pending >"$_ebpf_pending_tmp"
        ) || ! mv -f "$_ebpf_pending_tmp" "${_ebpf_state_dir}/shared.pending"; then
            rm -f "$_ebpf_pending_tmp" 2>/dev/null || true
            return 1
        fi
    else
        rm -f "${_ebpf_state_dir}/shared.pending" 2>/dev/null || true
    fi
    if [ "$_ebpf_state_mode" != ebpf ]; then
        rm -f "${_ebpf_state_dir}/capability" "${_ebpf_state_dir}/probe.json" 2>/dev/null || true
    fi
    unset _ebpf_state_mode _ebpf_state_pairs _ebpf_state_dir _ebpf_state_interfaces_tmp _ebpf_pending_tmp
}

magicnet_singbox_apply_transparent_mode() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _mode="$(magicnet_transparent_mode)" || {
        magicnet_warn "transparent mode configuration is invalid"
        return 1
    }
    _dns_strategy="$(magicnet_singbox_dns_strategy_for_mode "$_config" "tun")"
    _tun_mtu="$(magicnet_tun_mtu)"
    _udp_timeout="$(magicnet_udp_timeout)"
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || {
        magicnet_warn "packaged jq is unavailable; transparent config apply rejected"
        return 1
    }
    _pairs="${_config}.ebpf-networks.$$"
    : >"$_pairs" || return 1
    if [ "$_mode" = ebpf ]; then
        magicnet_ebpf_active_networks >"$_pairs" || {
            rm -f "$_pairs" 2>/dev/null || true
            return 1
        }
    fi
    _interfaces_json="$(awk -F'|' 'NF == 2 && !seen[$1]++ { print $1 }' "$_pairs" | "$_jq" -Rsc 'split("\n") | map(select(length > 0))')" || {
        rm -f "$_pairs" 2>/dev/null || true
        return 1
    }
    _sources_json="$(awk -F'|' 'NF == 2 && !seen[$2]++ { print $2 }' "$_pairs" | "$_jq" -Rsc 'split("\n") | map(select(length > 0))')" || {
        rm -f "$_pairs" 2>/dev/null || true
        return 1
    }
    _tmp="${_config}.transparent-mode.new"
    # shellcheck disable=SC2016
    if (
        umask 077
        "$_jq" \
            --arg mode "$_mode" \
            --arg dns_strategy "$_dns_strategy" \
            --argjson tun_mtu "$_tun_mtu" \
            --arg udp_timeout "$_udp_timeout" \
            --argjson shared_interfaces "$_interfaces_json" \
            --argjson shared_sources "$_sources_json" '
        def mixed_in:
          {"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":7892};
        def dns_in:
          {"type":"direct","tag":"magicnet-dns-in","listen":"127.0.0.1","listen_port":1053};
        def tun_in:
          {
            "type":"tun","tag":"tun-in","interface_name":"magicnet0",
            "address":(if $dns_strategy == "ipv4_only" then ["172.19.0.1/30"] else ["172.19.0.1/30","fdfe:dcba:9876::1/126"] end),
            "auto_route":true,"auto_redirect":true,"strict_route":true,
            "exclude_uid":[0],
            "route_exclude_address":[
              "192.168.0.0/16","10.0.0.0/8","172.16.0.0/12","100.64.0.0/10",
              "127.0.0.0/8","169.254.0.0/16","224.0.0.0/4","::1/128",
              "fc00::/7","fe80::/10","ff00::/8","fd7a:115c:a1e0::/48"
            ],
            "stack":"mixed","mtu":$tun_mtu,"udp_timeout":$udp_timeout
          };
        def ebpf_in:
          ({
            "type":"ebpf","tag":"tun-in",
            "mode":(if ($shared_interfaces | length) > 0 then "hybrid" else "local" end),
            "network":["tcp","udp"],"udp_timeout":$udp_timeout,
            "local":{
              "dns_mode":"hijack",
              "ipv6":($dns_strategy != "ipv4_only"),
              "bypass_private_address":true,
              "exclude_uid":[0]
            }
          } | if ($shared_interfaces | length) > 0 then
            .shared = {
              "dns_mode":"respect_policy",
              "interface":$shared_interfaces,
              "ipv6":($dns_strategy != "ipv4_only"),
              "bypass_private_address":true,
              "include_source_cidr":$shared_sources,
              "advanced":{"tc_priority":1}
            }
          else . end);
        def managed_inbound:
          ((.type // "") as $type | ($type == "tun" or $type == "ebpf" or $type == "tproxy" or $type == "redirect"))
          or ((.tag // "") == "mixed-in")
          or ((.tag // "") | startswith("magicnet-"));
        def references_managed_inbound:
          (.inbound // []) as $inbound
          | (if ($inbound | type) == "array" then $inbound else [$inbound] end)
          | map(select(type == "string" and startswith("magicnet-")))
          | length > 0;
        def dns_hijack_rule: {"inbound":["magicnet-dns-in"],"action":"hijack-dns"};
        def ebpf_dns_hijack_rule: {"inbound":["tun-in"],"port":53,"action":"hijack-dns"};
        def is_ebpf_dns_hijack_rule:
          (.action // "") == "hijack-dns" and (.port // null) == 53 and
          (((.inbound // []) | if type == "array" then . else [.] end) | index("tun-in") != null);
        def ipv6_reject_rule: {"ip_version":6,"action":"reject","method":"default","no_drop":true};
        def legacy_ipv6_block_rule: {"ip_version":6,"outbound":"block"};
        def normalized_ipv6_reject_rule: {"ip_version":6,"action":"reject","no_drop":true};
        def is_managed_ipv6_guard: . == legacy_ipv6_block_rule or . == normalized_ipv6_reject_rule or . == ipv6_reject_rule;
        def is_dns_hijack_rule: (.action // "") == "hijack-dns";
        def is_icmp_block_rule: (.protocol // "") == "icmp" and (.outbound // "") == "block";
        def is_sniff_rule: (.action // "") == "sniff";
        def normalize_sniff_rule: if (.action // "") == "sniff" then .inbound = ["mixed-in","tun-in"] else . end;
        def sniff_rule: {"inbound":["mixed-in","tun-in"],"action":"sniff"};
        .inbounds = (((.inbounds // []) | map(select(managed_inbound | not))) + [mixed_in,dns_in,(if $mode == "ebpf" then ebpf_in else tun_in end)])
        | .route.rules = (
          ((.route.rules // [])
            | map(select(references_managed_inbound | not))
            | map(select(is_managed_ipv6_guard | not))
            | map(select(is_ebpf_dns_hijack_rule | not))
            | map(normalize_sniff_rule)) as $rules
          | ([dns_hijack_rule] + (if $mode == "ebpf" then [ebpf_dns_hijack_rule] else [] end)
              + (if any($rules[]?; is_sniff_rule) then $rules else [sniff_rule] + $rules end)) as $managed_rules
          | if $dns_strategy == "ipv4_only" then
              [$managed_rules[] | select(is_sniff_rule)]
              + [dns_hijack_rule]
              + (if $mode == "ebpf" then [ebpf_dns_hijack_rule] else [] end)
              + [$managed_rules[] | select(is_icmp_block_rule)]
              + [ipv6_reject_rule]
              + [$managed_rules[] | select((is_sniff_rule or is_dns_hijack_rule or is_icmp_block_rule or is_managed_ipv6_guard) | not)]
            else $managed_rules end
        )
        | if $dns_strategy != "" then .dns.strategy = $dns_strategy else . end
    ' "$_config" >"$_tmp"
    ) && chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config"; then
        magicnet_ebpf_publish_state "$_mode" "$_pairs" || {
            rm -f "$_pairs" 2>/dev/null || true
            return 1
        }
    else
        rm -f "$_tmp" "$_pairs" 2>/dev/null || true
        unset _config _mode _dns_strategy _tun_mtu _udp_timeout _jq _tmp _pairs _interfaces_json _sources_json
        return 1
    fi
    rm -f "$_pairs" 2>/dev/null || true
    import __singbox__
    singbox_prepare_route_config "$_config" || true
    unset _config _mode _dns_strategy _tun_mtu _udp_timeout _jq _tmp _pairs _interfaces_json _sources_json
}

magicnet_transparent_capability_file() {
    printf '%s\n' "$(magicnet_ebpf_state_dir)/capability"
}

magicnet_transparent_capability_set() {
    _capability_value="$1"
    _capability_file="$(magicnet_transparent_capability_file)"
    mkdir -p "${_capability_file%/*}" || return 1
    _capability_tmp="${_capability_file}.tmp.$$"
    if ! (
        umask 077
        printf '%s\n' "$_capability_value" >"$_capability_tmp"
    ) || ! mv -f "$_capability_tmp" "$_capability_file"; then
        rm -f "$_capability_tmp" 2>/dev/null || true
        return 1
    fi
    unset _capability_value _capability_file _capability_tmp
}

magicnet_ebpf_publish_probe_report() {
    _probe_tmp="$1"
    _probe_report="$(magicnet_ebpf_probe_report)"
    if [ ! -s "$_probe_tmp" ] || ! chmod 600 "$_probe_tmp" ||
        ! mv -f "$_probe_tmp" "$_probe_report"; then
        rm -f "$_probe_tmp" 2>/dev/null || true
        return 1
    fi
    unset _probe_tmp _probe_report
}

magicnet_ebpf_status_with_timeout() {
    _ebpf_probe_timeout="${MAGICNET_EBPF_PROBE_TIMEOUT:-5}"
    case "$_ebpf_probe_timeout" in
    '' | *[!0-9]*) _ebpf_probe_timeout=5 ;;
    *)
        if [ "$_ebpf_probe_timeout" -lt 1 ] || [ "$_ebpf_probe_timeout" -gt 15 ]; then
            _ebpf_probe_timeout=5
        fi
        ;;
    esac
    if magicnet_cmd_exists timeout; then
        timeout "$_ebpf_probe_timeout" sing-box "$@"
    elif [ -x "${MODDIR}/bin/busybox" ]; then
        "${MODDIR}/bin/busybox" timeout "$_ebpf_probe_timeout" sing-box "$@"
    else
        unset _ebpf_probe_timeout
        return 1
    fi
    _ebpf_probe_rc=$?
    unset _ebpf_probe_timeout
    set -- "$_ebpf_probe_rc"
    unset _ebpf_probe_rc
    return "$1"
}

magicnet_probe_ebpf_config() {
    _probe_config="$1"
    _probe_jq="$2"
    _probe_mode="$("$_probe_jq" -r '.inbounds[]? | select(.tag == "tun-in" and .type == "ebpf") | .mode' "$_probe_config")" || return 1
    case "$_probe_mode" in
    local)
        set -- tools ebpf status --mode local --network tcp,udp --json
        ;;
    hybrid)
        _probe_interfaces="$("$_probe_jq" -r '.inbounds[]? | select(.tag == "tun-in" and .type == "ebpf") | .shared.interface[]?' "$_probe_config")" || return 1
        [ -n "$_probe_interfaces" ] || return 1
        set -- tools ebpf status --mode all --network tcp,udp --json
        while IFS= read -r _probe_iface; do
            case "$_probe_iface" in
            *[!A-Za-z0-9_.:-]* | '') return 1 ;;
            esac
            magicnet_hotspot_interface_allowed "$_probe_iface" || return 1
            magicnet_iface_exists "$_probe_iface" || return 1
            set -- "$@" --interface "$_probe_iface"
        done <<EOF
$_probe_interfaces
EOF
        ;;
    *) return 1 ;;
    esac
    _probe_report="$(magicnet_ebpf_probe_report)"
    mkdir -p "${_probe_report%/*}" || return 1
    _probe_tmp="${_probe_report}.tmp.$$"
    if (
        umask 077
        magicnet_ebpf_status_with_timeout "$@" >"$_probe_tmp" 2>/dev/null
    ) && magicnet_ebpf_publish_probe_report "$_probe_tmp"; then
        _probe_rc=0
    else
        _probe_rc=$?
        [ "$_probe_rc" -ne 0 ] || _probe_rc=1
        rm -f "$_probe_tmp" "$_probe_report" 2>/dev/null || true
    fi
    unset _probe_config _probe_jq _probe_mode _probe_interfaces _probe_iface _probe_report _probe_tmp
    return "$_probe_rc"
}

magicnet_ebpf_refresh_active_report() {
    _active_report="$(magicnet_ebpf_probe_report)"
    _active_jq="${MODDIR}/bin/jq"
    [ -x "$_active_jq" ] || return 1
    mkdir -p "${_active_report%/*}" || return 1
    _active_raw="${_active_report}.raw.$$"
    _active_tmp="${_active_report}.tmp.$$"
    if (
        umask 077
        magicnet_ebpf_status_with_timeout tools ebpf status --mode local --network tcp,udp --json >"$_active_raw" 2>/dev/null &&
            "$_active_jq" -e '
              if ((.active_programs | type) == "array")
                and (((.active_state_error // "") | type) == "string")
              then {
                active_programs: .active_programs,
                active_state_error: (.active_state_error // ""),
                result: (.result // "unknown")
              }
              else error("invalid eBPF active program report")
              end
            ' "$_active_raw" >"$_active_tmp"
    ) && magicnet_ebpf_publish_probe_report "$_active_tmp"; then
        _active_rc=0
    else
        _active_rc=$?
        [ "$_active_rc" -ne 0 ] || _active_rc=1
        rm -f "$_active_tmp" "$_active_report" 2>/dev/null || true
    fi
    rm -f "$_active_raw" 2>/dev/null || true
    unset _active_report _active_jq _active_raw _active_tmp
    return "$_active_rc"
}

magicnet_validate_singbox_transparent_config() {
    _validate_config="${MODDIR}/.config/sing-box/config.json"
    _validate_mode="$(magicnet_transparent_mode)" || return 1
    [ -f "$_validate_config" ] || return 1
    magicnet_cmd_exists sing-box || return 1
    if ! sing-box check -c "$_validate_config" -D "${_validate_config%/*}" >/dev/null 2>&1; then
        [ "$_validate_mode" != ebpf ] || magicnet_transparent_capability_set failed >/dev/null 2>&1 || true
        magicnet_warn "sing-box rejected the final generated configuration"
        return 1
    fi
    if [ "$_validate_mode" = tun ]; then
        magicnet_transparent_capability_set not-required >/dev/null 2>&1 || true
        unset _validate_config _validate_mode
        return 0
    fi
    _validate_jq="${MODDIR}/bin/jq"
    [ -x "$_validate_jq" ] || return 1
    if ! magicnet_probe_ebpf_config "$_validate_config" "$_validate_jq"; then
        magicnet_transparent_capability_set failed >/dev/null 2>&1 || true
        magicnet_warn "eBPF capability probe failed"
        return 1
    fi
    magicnet_transparent_capability_set ok || return 1
    unset _validate_config _validate_mode _validate_jq
}

magicnet_transparent_verify_running() {
    magicnet_kernel_running || return $?
    # Catch immediate loader/attach failures that can briefly leave a process
    # visible after singbox_start reports success.
    sleep 1
    magicnet_kernel_running || return $?
    _verify_mode="$(magicnet_transparent_mode)" || return 1
    _verify_config="${MODDIR}/.config/sing-box/config.json"
    _verify_jq="${MODDIR}/bin/jq"
    [ -x "$_verify_jq" ] && [ -f "$_verify_config" ] || return 1
    case "$_verify_mode" in
    tun) _verify_type=tun ;;
    ebpf) _verify_type=ebpf ;;
    *) return 1 ;;
    esac
    "$_verify_jq" -e --arg type "$_verify_type" 'any(.inbounds[]?; .tag == "tun-in" and .type == $type)' "$_verify_config" >/dev/null 2>&1 || return 1
    if [ "$_verify_mode" = ebpf ]; then
        [ "$(cat "$(magicnet_transparent_capability_file)" 2>/dev/null)" = ok ] || return 1
        magicnet_ebpf_refresh_active_report || return 1
    fi
    unset _verify_mode _verify_config _verify_jq _verify_type
    return 0
}

magicnet_ebpf_hotspot_config_current() {
    # Some focused route-policy harnesses source this module without common.sh.
    # The production loader always provides the parser; absent it, there is no
    # configured eBPF mode to compare.
    command -v magicnet_transparent_mode >/dev/null 2>&1 || return 0
    _current_mode="$(magicnet_transparent_mode)" || return 1
    [ "$_current_mode" = ebpf ] || return 0
    _current_config="${MODDIR}/.config/sing-box/config.json"
    _current_jq="${MODDIR}/bin/jq"
    [ -f "$_current_config" ] && [ -x "$_current_jq" ] || return 1
    _current_pairs="${_current_config}.ebpf-current.$$"
    magicnet_ebpf_active_networks >"$_current_pairs" || return 1
    _current_pairs_json="$("$_current_jq" -Rsc 'split("\n") | map(select(length > 0) | split("|") | {interface:.[0], cidr:.[1]})' "$_current_pairs")" || {
        rm -f "$_current_pairs" 2>/dev/null || true
        return 1
    }
    if magicnet_hotspot_proxy_enabled; then _current_enabled=true; else _current_enabled=false; fi
    "$_current_jq" -e --argjson active "$_current_pairs_json" --argjson enabled "$_current_enabled" '
      first(.inbounds[]? | select(.tag == "tun-in" and .type == "ebpf")) as $inbound
      | (($inbound.shared.interface // []) | map(.) | unique) as $interfaces
      | (($inbound.shared.include_source_cidr // []) | map(.) | unique) as $cidrs
      | if ($enabled | not) then ($inbound.mode == "local" and ($interfaces | length) == 0)
        elif ($active | length) == 0 then true
        elif $inbound.mode == "local" then false
        else all($active[]; (.interface as $iface | .cidr as $cidr |
          (($interfaces | index($iface)) != null and ($cidrs | index($cidr)) != null)))
        end
    ' "$_current_config" >/dev/null 2>&1
    _current_rc=$?
    rm -f "$_current_pairs" 2>/dev/null || true
    unset _current_mode _current_config _current_jq _current_pairs _current_pairs_json _current_enabled
    return "$_current_rc"
}

magicnet_transparent_transaction_dir() {
    printf '%s\n' "${MODDIR}/.state/transparent-transaction"
}

magicnet_restore_transparent_state_file() {
    _restore_state_transaction="$1"
    _restore_state_name="$2"
    _restore_state_destination="$3"
    _restore_state_present="$(cat "${_restore_state_transaction}/old-ebpf-${_restore_state_name}-present" 2>/dev/null)" || return 1
    case "$_restore_state_present" in
    1)
        _restore_state_source="${_restore_state_transaction}/old-ebpf-${_restore_state_name}"
        [ -f "$_restore_state_source" ] || return 1
        mkdir -p "${_restore_state_destination%/*}" || return 1
        _restore_state_tmp="${_restore_state_destination}.transaction-restore.$$"
        if ! (
            umask 077
            cp "$_restore_state_source" "$_restore_state_tmp"
        ) || ! chmod 600 "$_restore_state_tmp" ||
            ! mv -f "$_restore_state_tmp" "$_restore_state_destination"; then
            rm -f "$_restore_state_tmp" 2>/dev/null || true
            return 1
        fi
        ;;
    0) rm -f "$_restore_state_destination" || return 1 ;;
    *) return 1 ;;
    esac
    unset _restore_state_transaction _restore_state_name _restore_state_destination
    unset _restore_state_present _restore_state_source _restore_state_tmp
}

magicnet_restore_transparent_state_snapshot() {
    _restore_snapshot_transaction="$1"
    _restore_snapshot_version_file="${_restore_snapshot_transaction}/old-ebpf-state-version"
    # Journals published before runtime-state snapshots were introduced remain
    # recoverable; their restored core startup will republish current evidence.
    [ -e "$_restore_snapshot_version_file" ] || {
        unset _restore_snapshot_transaction _restore_snapshot_version_file
        return 0
    }
    [ "$(cat "$_restore_snapshot_version_file" 2>/dev/null)" = 1 ] || return 1
    _restore_snapshot_dir="$(magicnet_ebpf_state_dir)"
    magicnet_restore_transparent_state_file "$_restore_snapshot_transaction" capability "${_restore_snapshot_dir}/capability" || return 1
    magicnet_restore_transparent_state_file "$_restore_snapshot_transaction" probe "${_restore_snapshot_dir}/probe.json" || return 1
    magicnet_restore_transparent_state_file "$_restore_snapshot_transaction" shared-pending "${_restore_snapshot_dir}/shared.pending" || return 1
    magicnet_restore_transparent_state_file "$_restore_snapshot_transaction" shared-interfaces "${_restore_snapshot_dir}/shared-interfaces.list" || return 1
    unset _restore_snapshot_transaction _restore_snapshot_version_file _restore_snapshot_dir
}

magicnet_recover_interrupted_transparent_transaction() {
    _transaction_dir="$(magicnet_transparent_transaction_dir)"
    [ -d "$_transaction_dir" ] || return 0
    _old_mode_present="$(cat "${_transaction_dir}/old-mode-present" 2>/dev/null || true)"
    _old_config_present="$(cat "${_transaction_dir}/old-config-present" 2>/dev/null || true)"
    _old_mode="$(cat "${_transaction_dir}/old-mode" 2>/dev/null || true)"
    case "$_old_mode_present:$_old_config_present:$_old_mode" in
    0:0:tun | 0:0:ebpf | 0:1:tun | 0:1:ebpf | 1:0:tun | 1:0:ebpf | 1:1:tun | 1:1:ebpf) ;;
    *)
        magicnet_warn "transparent transaction journal is invalid"
        return 1
        ;;
    esac
    import __singbox__
    singbox_stop >/dev/null 2>&1 || true
    magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true
    magicnet_disable_dns_capture >/dev/null 2>&1 || true
    magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
    if [ "$_old_mode_present" = 1 ]; then
        magicnet_transparent_set_mode "$_old_mode" || return 1
    else
        rm -f "$(magicnet_transparent_conf)" || return 1
    fi
    _restore_config="${MODDIR}/.config/sing-box/config.json"
    if [ "$_old_config_present" = 1 ]; then
        [ -f "${_transaction_dir}/old-config.json" ] || return 1
        _restore_tmp="${_restore_config}.transaction-restore.$$"
        if ! (
            umask 077
            cp "${_transaction_dir}/old-config.json" "$_restore_tmp"
        ) || ! chmod 600 "$_restore_tmp" || ! mv -f "$_restore_tmp" "$_restore_config"; then
            rm -f "$_restore_tmp" 2>/dev/null || true
            return 1
        fi
    else
        rm -f "$_restore_config" || return 1
    fi
    magicnet_restore_transparent_state_snapshot "$_transaction_dir" || return 1
    rm -rf "$_transaction_dir" || return 1
    magicnet_warn "Recovered an interrupted transparent mode transition to $_old_mode"
    unset _transaction_dir _old_mode_present _old_config_present _old_mode _restore_config _restore_tmp
}

magicnet_transparent_apply_unlocked() {
    _transparent_rc=0
    magicnet_singbox_apply_transparent_mode || _transparent_rc=1
    return "$_transparent_rc"
}

magicnet_transparent_apply() {
    magicnet_with_config_lock magicnet_transparent_apply_unlocked
}
