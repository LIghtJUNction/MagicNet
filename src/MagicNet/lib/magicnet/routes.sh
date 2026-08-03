magicnet_route_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_route_list_file() {
    printf '%s\n' "$(magicnet_route_dir)/route-$1-domain-suffix.list"
}

magicnet_route_list_values() {
    _file="$1"
    [ -f "$_file" ] || return 0
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++'
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

magicnet_hotspot_offload_value() {
    command -v settings >/dev/null 2>&1 || return 1
    settings get global tether_offload_disabled 2>/dev/null | tr -d '\r' | sed -n '1p'
}

magicnet_hotspot_register_offload_rollback() {
    import prop
    _hotspot_rollback_cmd='_mn_state="${0%/*}/.state/hotspot/tether-offload.previous"; if [ -f "$_mn_state" ]; then _mn_previous="$(sed -n "1p" "$_mn_state" 2>/dev/null)"; if [ "$_mn_previous" = unset ]; then settings delete global tether_offload_disabled >/dev/null 2>&1 || true; else settings put global tether_offload_disabled "${_mn_previous#value=}" >/dev/null 2>&1 || true; fi; rm -f "$_mn_state" 2>/dev/null || true; fi'
    register_uninstall_cmd "$_hotspot_rollback_cmd" "$MODDIR" >/dev/null 2>&1 || true
    unset _hotspot_rollback_cmd
}

magicnet_hotspot_offload_enable() {
    _hotspot_state="$(magicnet_hotspot_offload_state_file)"
    if [ ! -f "$_hotspot_state" ]; then
        _hotspot_previous="$(magicnet_hotspot_offload_value)" || {
            magicnet_warn "Android settings service is unavailable; cannot disable tether offload"
            unset _hotspot_state _hotspot_previous
            return 1
        }
        case "$_hotspot_previous" in
            "" | null) _hotspot_saved=unset ;;
            0 | 1) _hotspot_saved="value=$_hotspot_previous" ;;
            *)
                magicnet_warn "Unexpected tether_offload_disabled value; refusing to overwrite it"
                unset _hotspot_state _hotspot_previous _hotspot_saved
                return 1
                ;;
        esac
        mkdir -p "${_hotspot_state%/*}" || return 1
        _hotspot_tmp="${_hotspot_state}.new.$$"
        if ! printf '%s\n' "$_hotspot_saved" >"$_hotspot_tmp" ||
            ! mv -f "$_hotspot_tmp" "$_hotspot_state"; then
            rm -f "$_hotspot_tmp" 2>/dev/null || true
            unset _hotspot_state _hotspot_previous _hotspot_saved _hotspot_tmp
            return 1
        fi
        magicnet_hotspot_register_offload_rollback
    fi
    if ! settings put global tether_offload_disabled 1 >/dev/null 2>&1 ||
        [ "$(magicnet_hotspot_offload_value)" != 1 ]; then
        magicnet_warn "Failed to disable Android tether offload"
        unset _hotspot_state _hotspot_previous _hotspot_saved _hotspot_tmp
        return 1
    fi
    unset _hotspot_state _hotspot_previous _hotspot_saved _hotspot_tmp
}

magicnet_hotspot_offload_restore() {
    _hotspot_state="$(magicnet_hotspot_offload_state_file)"
    [ -f "$_hotspot_state" ] || {
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

magicnet_singbox_apply_hotspot_policy() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || _jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_jq" ] || {
        magicnet_warn "jq not found; cannot apply hotspot proxy policy"
        unset _config _jq
        return 1
    }
    _tmp="${_config}.hotspot-policy.new"
    # Forwarded Android tethering clients retain their LAN source address when
    # entering the TUN. Device-local TUN traffic uses 172.19.0.1 and therefore
    # does not match these hotspot source ranges.
    if "$_jq" '
        def hotspot_sources:
          ["192.168.0.0/16", "10.42.0.0/16", "172.20.10.0/28"];
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
            "source_ip_cidr": hotspot_sources,
            "outbound": "hotspot"
          };
        def is_hotspot_rule:
          (.inbound // []) == ["tun-in"]
            and (.source_ip_cidr // []) == hotspot_sources
            and (.outbound // "") == "hotspot";
        .outbounds = (
          ((.outbounds // []) | map(select((.tag // "") != "hotspot")))
          + [hotspot_selector]
        )
        | ((.route.rules // []) | map(select(is_hotspot_rule | not))) as $rules
        | (
            [$rules | to_entries[] | select((.value.outbound // "") == "dns-guard") | .key]
            | last
          ) as $dns_guard_anchor
        | (
            [$rules | to_entries[] | select(.value.action != null) | .key]
            | last
          ) as $action_anchor
        | (($dns_guard_anchor // $action_anchor // -1) + 1) as $insert_at
        | .route.rules = (
            $rules[:$insert_at] + [hotspot_rule] + $rules[$insert_at:]
          )
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        unset _config _jq _tmp
        return 1
    fi
    unset _config _jq _tmp
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
    mkdir -p "${_rules_file%/*}"
    magicnet_route_singbox_rules >"$_rules_file"
    if awk -v rules_file="$_rules_file" '
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
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    if magicnet_route_has_rules; then
        grep -q '"__magicnet_route__"' "$_config" || {
            magicnet_warn "sing-box custom route rules were not inserted"
            return 1
        }
    else
        if grep -q '"__magicnet_route__"' "$_config"; then
            magicnet_warn "sing-box custom route marker was not removed"
            return 1
        fi
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
