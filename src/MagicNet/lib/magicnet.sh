# shellcheck shell=ash
#
# MagicNet module runtime.
# This file owns MagicNet-specific lifecycle handlers and keeps entry scripts
# thin while using kamfw's phase dispatcher as the runtime boundary.

import wait
import rich

magicnet_log() {
    info "$1"
}

magicnet_warn() {
    warn "$1"
}

magicnet_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

magicnet_iface_exists() {
    [ -n "$1" ] && [ -d "/sys/class/net/$1" ]
}

magicnet_get_mihomo_tun() {
    [ -f "${MODDIR}/.config/mihomo/config.yaml" ] || return 0
    awk -F: '
        /^[[:space:]]*device[[:space:]]*:/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            gsub(/["'\'']/, "", $2)
            if ($2 != "") {
                print $2
                exit
            }
        }
    ' "${MODDIR}/.config/mihomo/config.yaml" 2>/dev/null
}

magicnet_get_singbox_tun() {
    [ -f "${MODDIR}/.config/sing-box/config.json" ] || return 0
    sed -n 's/.*"interface_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${MODDIR}/.config/sing-box/config.json" | head -n 1
}

magicnet_collect_tun_ifaces() {
    _magicnet_tun_ifaces="${MAGIC_TUN_IFACES:-}"
    _mihomo_tun=$(magicnet_get_mihomo_tun)
    _singbox_tun=$(magicnet_get_singbox_tun)

    [ -n "$_mihomo_tun" ] && _magicnet_tun_ifaces="$_magicnet_tun_ifaces $_mihomo_tun"
    [ -n "$_singbox_tun" ] && _magicnet_tun_ifaces="$_magicnet_tun_ifaces $_singbox_tun"

    _magicnet_tun_ifaces="$_magicnet_tun_ifaces Meta mihoyo utun magicnet0"
    for _iface in $_magicnet_tun_ifaces; do
        magicnet_iface_exists "$_iface" && printf '%s\n' "$_iface"
    done | awk '!seen[$0]++'
}

magicnet_iface_has_hotspot_addr() {
    magicnet_cmd_exists ip || return 1
    ip -o -4 addr show dev "$1" 2>/dev/null |
        grep -Eq 'inet (192\.168\.[0-9]+\.1|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.1|10\.[0-9]+\.[0-9]+\.1)/'
}

magicnet_iface_has_private_addr() {
    magicnet_cmd_exists ip || return 1
    ip -o -4 addr show dev "$1" 2>/dev/null |
        grep -Eq 'inet (10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)'
}

magicnet_iface_has_local_network_route() {
    magicnet_cmd_exists ip || return 1
    ip route show table local_network 2>/dev/null |
        grep -Eq "[[:space:]]dev[[:space:]]+$1([[:space:]]|$)"
}

magicnet_collect_hotspot_ifaces() {
    if [ -n "${MAGIC_HOTSPOT_IFACES:-}" ]; then
        for _iface in $MAGIC_HOTSPOT_IFACES; do
            printf '%s\n' "$_iface"
        done | awk '!seen[$0]++'
        return 0
    fi

    for _path in /sys/class/net/*; do
        [ -d "$_path" ] || continue
        _iface=${_path##*/}
        case "$_iface" in
            ap[0-9]*|swlan[0-9]*|softap[0-9]*|rndis[0-9]*|usb[0-9]*|bt-pan)
                printf '%s\n' "$_iface"
                ;;
            wlan[0-9]*|wifi[0-9]*)
                if magicnet_iface_has_hotspot_addr "$_iface" ||
                    { magicnet_iface_has_private_addr "$_iface" && magicnet_iface_has_local_network_route "$_iface"; }; then
                    printf '%s\n' "$_iface"
                fi
                ;;
        esac
    done | awk '!seen[$0]++'
}

magicnet_pick_forward_chain() {
    if iptables -nL tetherctrl_FORWARD >/dev/null 2>&1; then
        printf '%s\n' "tetherctrl_FORWARD"
    else
        printf '%s\n' "FORWARD"
    fi
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

magicnet_enable_hotspot_forward() {
    [ "${MAGIC_HOTSPOT_FORWARD:-1}" != "0" ] || return 0

    if ! magicnet_cmd_exists iptables; then
        magicnet_warn "iptables not found; hotspot forwarding fix skipped"
        return 0
    fi

    _forward_chain=$(magicnet_pick_forward_chain)
    _tun_ifaces=$(magicnet_collect_tun_ifaces)
    _hotspot_ifaces=$(magicnet_collect_hotspot_ifaces)

    if [ -z "$_tun_ifaces" ]; then
        magicnet_warn "No active TUN interface found; hotspot forwarding fix skipped"
        return 0
    fi
    if [ -z "$_hotspot_ifaces" ]; then
        magicnet_warn "No hotspot interface candidate found; hotspot forwarding fix skipped"
        return 0
    fi

    for _tun in $_tun_ifaces; do
        for _hotspot in $_hotspot_ifaces; do
            [ "$_tun" != "$_hotspot" ] || continue
            magicnet_iptables_ensure "$_forward_chain" -i "$_hotspot" -o "$_tun" -j ACCEPT || true
            magicnet_iptables_ensure "$_forward_chain" -i "$_tun" -o "$_hotspot" -m state --state RELATED,ESTABLISHED -j ACCEPT ||
                magicnet_iptables_ensure "$_forward_chain" -i "$_tun" -o "$_hotspot" -j ACCEPT || true
        done
        magicnet_iptables_ensure -t nat POSTROUTING -o "$_tun" -j MASQUERADE || true
    done

    magicnet_log "Hotspot forwarding rules applied via $_forward_chain"
}

magicnet_is_magic_iface() {
    _candidate="$1"
    for _magic_iface in $_magicnet_magic_ifaces; do
        [ "$_candidate" = "$_magic_iface" ] && return 0
    done
    return 1
}

magicnet_collect_external_vpn_ifaces() {
    if [ -n "${MAGIC_VPN_COEXIST_IFACES:-}" ]; then
        for _iface in $MAGIC_VPN_COEXIST_IFACES; do
            magicnet_iface_exists "$_iface" && printf '%s\n' "$_iface"
        done | awk '!seen[$0]++'
        return 0
    fi

    for _path in /sys/class/net/*; do
        [ -d "$_path" ] || continue
        _iface=${_path##*/}
        magicnet_is_magic_iface "$_iface" && continue
        case "$_iface" in
            tun[0-9]*|wg[0-9]*|tailscale[0-9]*|zt[0-9]*|zerotier[0-9]*|warp[0-9]*)
                printf '%s\n' "$_iface"
                ;;
        esac
    done | awk '!seen[$0]++'
}

magicnet_ip_rule_exists() {
    ip rule show 2>/dev/null | grep -F "$1" | grep -F "$2" >/dev/null 2>&1
}

magicnet_ip_rule_ensure() {
    _priority="$1"
    shift
    _needle="$*"
    magicnet_ip_rule_exists "$_priority:" "$_needle" || ip rule add priority "$_priority" "$@" >/dev/null 2>&1 || true
}

magicnet_enable_vpn_coexist() {
    [ "${MAGIC_VPN_COEXIST:-1}" = "1" ] || return 0

    if ! magicnet_cmd_exists ip; then
        magicnet_warn "ip command not found; VPN coexistence rules skipped"
        return 0
    fi

    _magicnet_magic_ifaces=$(magicnet_collect_tun_ifaces)
    _external_ifaces=$(magicnet_collect_external_vpn_ifaces)

    if [ -z "$_external_ifaces" ]; then
        magicnet_log "VPN coexistence enabled; no external VPN interface found"
        return 0
    fi

    _priority4=${MAGIC_VPN_COEXIST_RULE_PRIORITY4:-8900}
    _priority6=${MAGIC_VPN_COEXIST_RULE_PRIORITY6:-8950}

    for _iface in $_external_ifaces; do
        magicnet_ip_rule_ensure "$_priority4" iif "$_iface" lookup main
        magicnet_ip_rule_ensure "$_priority6" iif "$_iface" lookup main

        ip -o -4 addr show dev "$_iface" 2>/dev/null | while read -r _line; do
            _cidr=$(printf '%s\n' "$_line" | awk '{print $4}')
            [ -n "$_cidr" ] || continue
            magicnet_ip_rule_ensure "$_priority4" from "$_cidr" lookup main
            magicnet_ip_rule_ensure "$((_priority4 + 1))" to "$_cidr" lookup main
        done

        ip -o -6 addr show dev "$_iface" scope global 2>/dev/null | while read -r _line; do
            _cidr=$(printf '%s\n' "$_line" | awk '{print $4}')
            [ -n "$_cidr" ] || continue
            magicnet_ip_rule_ensure "$_priority6" from "$_cidr" lookup main
            magicnet_ip_rule_ensure "$((_priority6 + 1))" to "$_cidr" lookup main
        done
    done

    magicnet_log "VPN coexistence route rules applied for: $_external_ifaces"
}

magicnet_after_kernel_start() {
    magicnet_singbox_apply_zashboard
    magicnet_singbox_apply_app_policy
    magicnet_capture_apply
    magicnet_enable_hotspot_forward
    magicnet_enable_vpn_coexist
}

magicnet_app_policy_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_app_policy_mode() {
    _mode_file="$(magicnet_app_policy_dir)/app-mode.conf"
    if [ -f "$_mode_file" ]; then
        . "$_mode_file"
    fi
    case "${MAGICNET_APP_MODE:-blacklist}" in
        whitelist) printf '%s\n' "whitelist" ;;
        *) printf '%s\n' "blacklist" ;;
    esac
}

magicnet_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

magicnet_package_array_block() {
    _key="$1"
    _file="$2"
    _comma="${3:-,}"
    [ -s "$_file" ] || return 0

    _items=$(sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++')
    [ -n "$_items" ] || return 0

    printf '      "%s": [\n' "$_key"
    _count=$(printf '%s\n' "$_items" | wc -l | tr -d ' ')
    _idx=0
    printf '%s\n' "$_items" | while read -r _pkg; do
        [ -n "$_pkg" ] || continue
        _idx=$((_idx + 1))
        _line_comma=","
        [ "$_idx" -eq "$_count" ] && _line_comma=""
        printf '        "%s"%s\n' "$(magicnet_json_escape "$_pkg")" "$_line_comma"
    done
    printf '      ]%s\n' "$_comma"
}

magicnet_singbox_apply_app_policy() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0

    _dir="$(magicnet_app_policy_dir)"
    _mode="$(magicnet_app_policy_mode)"
    _proxy_file="${_dir}/app-proxy.list"
    _bypass_file="${_dir}/app-bypass.list"

    _include_block=""
    _exclude_block=""
    if [ "$_mode" = "whitelist" ]; then
        _include_block="$(magicnet_package_array_block include_package "$_proxy_file" ",")"
    else
        _exclude_block="$(magicnet_package_array_block exclude_package "$_bypass_file" ",")"
    fi

    _tmp="${_config}.app-policy.new"
    if awk -v include_block="$_include_block" -v exclude_block="$_exclude_block" '
        BEGIN {
            in_tun = 0
            skip_package_array = 0
        }
        skip_package_array {
            if ($0 ~ /^[[:space:]]*][[:space:]]*,?[[:space:]]*$/) {
                skip_package_array = 0
            }
            next
        }
        {
            if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"tun"/) {
                in_tun = 1
            }
            if (in_tun && $0 ~ /^[[:space:]]*"(include_package|exclude_package)"[[:space:]]*:/) {
                skip_package_array = 1
                next
            }
            if (in_tun && $0 ~ /^[[:space:]]*"stack"[[:space:]]*:/) {
                if (include_block != "") {
                    print include_block
                }
                if (exclude_block != "") {
                    print exclude_block
                }
            }
            print
            if (in_tun && $0 ~ /^    }[,]?[[:space:]]*$/) {
                in_tun = 0
            }
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_singbox_apply_zashboard() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0

    _tmp="${_config}.zashboard.new"
    if awk '
        /"external_ui"[[:space:]]*:/ {
            sub(/"external_ui"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"external_ui\": \"zashboard\"")
        }
        /"external_ui_download_url"[[:space:]]*:/ {
            sub(/"external_ui_download_url"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"external_ui_download_url\": \"https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip\"")
        }
        { print }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_capture_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_capture_conf() {
    _conf="$(magicnet_capture_dir)/capture.conf"
    if [ -f "$_conf" ]; then
        . "$_conf"
    fi
    MAGICNET_CAPTURE_ENABLED="${MAGICNET_CAPTURE_ENABLED:-0}"
    MAGICNET_CAPTURE_HOST="${MAGICNET_CAPTURE_HOST:-192.168.1.100}"
    MAGICNET_CAPTURE_PORT="${MAGICNET_CAPTURE_PORT:-8888}"
    MAGICNET_CAPTURE_NAME="${MAGICNET_CAPTURE_NAME:-MagicNet-Capture}"
}

magicnet_capture_list_values() {
    _file="$1"
    [ -f "$_file" ] || return 0
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++'
}

magicnet_capture_yaml_rules() {
    _apps_file="$(magicnet_capture_dir)/capture-app.list"
    _domains_file="$(magicnet_capture_dir)/capture-domain-suffix.list"
    _name="$1"
    magicnet_capture_list_values "$_apps_file" | while read -r _pkg; do
        [ -n "$_pkg" ] && printf '  - PROCESS-NAME,%s,%s\n' "$_pkg" "$_name"
    done
    magicnet_capture_list_values "$_domains_file" | while read -r _domain; do
        [ -n "$_domain" ] && printf '  - DOMAIN-SUFFIX,%s,%s\n' "$_domain" "$_name"
    done
}

magicnet_capture_singbox_rule_block() {
    _apps_file="$(magicnet_capture_dir)/capture-app.list"
    _domains_file="$(magicnet_capture_dir)/capture-domain-suffix.list"
    _outbound="$1"
    _has_any=0

    _apps="$(magicnet_capture_list_values "$_apps_file")"
    if [ -n "$_apps" ]; then
        _has_any=1
        printf '      {\n'
        printf '        "package_name": [\n'
        _count=$(printf '%s\n' "$_apps" | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_apps" | while read -r _pkg; do
            [ -n "$_pkg" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_pkg")" "$_comma"
        done
        printf '        ],\n'
        printf '        "outbound": "%s"\n' "$_outbound"
        printf '      },\n'
    fi

    _domains="$(magicnet_capture_list_values "$_domains_file")"
    if [ -n "$_domains" ]; then
        _has_any=1
        printf '      {\n'
        printf '        "domain_suffix": [\n'
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
    fi

    [ "$_has_any" -eq 1 ]
}

magicnet_capture_apply_mihomo() {
    _config="${MODDIR}/.config/mihomo/config.yaml"
    [ -f "$_config" ] || return 0
    magicnet_capture_conf
    _tmp="${_config}.capture.new"
    _rules_file="${MODDIR}/.tmp/magicnet-capture-mihomo.rules"
    mkdir -p "${_rules_file%/*}"
    magicnet_capture_yaml_rules "$MAGICNET_CAPTURE_NAME" >"$_rules_file"
    if awk \
        -v enabled="$MAGICNET_CAPTURE_ENABLED" \
        -v name="$MAGICNET_CAPTURE_NAME" \
        -v host="$MAGICNET_CAPTURE_HOST" \
        -v port="$MAGICNET_CAPTURE_PORT" \
        -v rules_file="$_rules_file" '
        BEGIN {
            skip_capture_proxy = 0
            skip_capture_rules = 0
            inserted_proxy = 0
            inserted_rules = 0
        }
        skip_capture_proxy {
            if ($0 ~ /^  # MAGICNET_CAPTURE_PROXY_END/) {
                skip_capture_proxy = 0
            }
            next
        }
        skip_capture_rules {
            if ($0 ~ /^  # MAGICNET_CAPTURE_END/) {
                skip_capture_rules = 0
            }
            next
        }
        $0 ~ /^  # MAGICNET_CAPTURE_PROXY_START/ {
            skip_capture_proxy = 1
            next
        }
        $0 ~ /^  # MAGICNET_CAPTURE_START/ {
            skip_capture_rules = 1
            next
        }
        {
            if (enabled == "1" && !inserted_proxy && $0 ~ /^proxies:[[:space:]]*\[\][[:space:]]*$/) {
                print "proxies:"
                print "  # MAGICNET_CAPTURE_PROXY_START"
                print "  - name: \"" name "\""
                print "    type: http"
                print "    server: " host
                print "    port: " port
                print "  # MAGICNET_CAPTURE_PROXY_END"
                inserted_proxy = 1
                next
            }
            print
            if (enabled == "1" && !inserted_proxy && $0 ~ /^proxies:[[:space:]]*$/) {
                print "  # MAGICNET_CAPTURE_PROXY_START"
                print "  - name: \"" name "\""
                print "    type: http"
                print "    server: " host
                print "    port: " port
                print "  # MAGICNET_CAPTURE_PROXY_END"
                inserted_proxy = 1
            }
            if (enabled == "1" && !inserted_rules && $0 ~ /^rules:[[:space:]]*$/) {
                print "  # MAGICNET_CAPTURE_START"
                while ((getline rule_line < rules_file) > 0) {
                    print rule_line
                }
                close(rules_file)
                print "  # MAGICNET_CAPTURE_END"
                inserted_rules = 1
            }
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_capture_apply_singbox() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    magicnet_capture_conf
    _tmp="${_config}.capture.new"
    _route_rules_file="${MODDIR}/.tmp/magicnet-capture-singbox.rules"
    mkdir -p "${_route_rules_file%/*}"
    magicnet_capture_singbox_rule_block "magicnet-capture" >"$_route_rules_file" || true
    if awk \
        -v enabled="$MAGICNET_CAPTURE_ENABLED" \
        -v host="$MAGICNET_CAPTURE_HOST" \
        -v port="$MAGICNET_CAPTURE_PORT" \
        -v route_rules_file="$_route_rules_file" '
        BEGIN {
            in_outbounds = 0
            in_route = 0
            in_route_rules = 0
            buffering = 0
            mode = ""
            buffer = ""
            is_direct = 0
            is_capture = 0
            inserted_outbound = 0
            inserted_rules = 0
        }
        function reset_buffer() {
            buffer = ""
            is_direct = 0
            is_capture = 0
            buffering = 0
            mode = ""
        }
        function flush_outbound_object() {
            if (!is_capture) {
                if (enabled == "1" && !inserted_outbound && is_direct) {
                    print "    {"
                    print "      \"type\": \"http\","
                    print "      \"tag\": \"magicnet-capture\","
                    print "      \"server\": \"" host "\","
                    print "      \"server_port\": " port
                    print "    },"
                    inserted_outbound = 1
                }
                printf "%s", buffer
            }
            reset_buffer()
        }
        function flush_route_rule_object() {
            if (!is_capture) {
                printf "%s", buffer
                if (enabled == "1" && !inserted_rules && buffer ~ /"action"[[:space:]]*:[[:space:]]*"sniff"/) {
                    while ((getline rule_line < route_rules_file) > 0) {
                        print rule_line
                    }
                    close(route_rules_file)
                    inserted_rules = 1
                }
            }
            reset_buffer()
        }
        {
            if (buffering && mode == "outbound") {
                buffer = buffer $0 "\n"
                if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"direct"/) {
                    is_direct = 1
                }
                if ($0 ~ /"tag"[[:space:]]*:[[:space:]]*"magicnet-capture"/) {
                    is_capture = 1
                }
                if ($0 ~ /^    }[,]?[[:space:]]*$/) {
                    flush_outbound_object()
                }
                next
            }
            if (buffering && mode == "route_rule") {
                buffer = buffer $0 "\n"
                if ($0 ~ /"outbound"[[:space:]]*:[[:space:]]*"magicnet-capture"/) {
                    is_capture = 1
                }
                if ($0 ~ /^      }[,]?[[:space:]]*$/) {
                    flush_route_rule_object()
                }
                next
            }
            if ($0 ~ /^  "outbounds"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_outbounds = 1
                print
                next
            }
            if (in_outbounds && $0 ~ /^  ][,]?[[:space:]]*$/) {
                in_outbounds = 0
                print
                next
            }
            if (in_outbounds && $0 ~ /^    \{[[:space:]]*$/) {
                buffering = 1
                mode = "outbound"
                buffer = $0 "\n"
                is_direct = 0
                is_capture = 0
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
                in_route_rules = 1
                print
                next
            }
            if (in_route_rules && $0 ~ /^    ][,]?[[:space:]]*$/) {
                in_route_rules = 0
                print
                next
            }
            if (in_route_rules && $0 ~ /^      \{[[:space:]]*$/) {
                buffering = 1
                mode = "route_rule"
                buffer = $0 "\n"
                is_capture = 0
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
}

magicnet_capture_apply() {
    magicnet_capture_apply_mihomo
    magicnet_capture_apply_singbox
}

magicnet_apply_runtime_config() {
    magicnet_singbox_apply_zashboard
    magicnet_singbox_apply_app_policy
    magicnet_capture_apply
    magicnet_enable_hotspot_forward
    magicnet_enable_vpn_coexist
}

magicnet_singbox_disabled() {
    [ -f "${MODDIR}/.disable_sing_box" ]
}

magicnet_watchdog_name() {
    printf '%s\n' "magicnet-kernel"
}

magicnet_watchdog_interval() {
    printf '%s\n' "${MAGICNET_WATCHDOG_INTERVAL:-30}"
}

magicnet_watchdog_command() {
    printf '%s\n' "MAGICNET_WATCHDOG=1 MODDIR='$(magicnet_json_escape "$MODDIR")' sh '$(magicnet_json_escape "$MODDIR")/cli' service ensure >/dev/null 2>&1"
}

magicnet_notify() {
    [ "${MAGICNET_NOTIFY_ENABLED:-1}" != "0" ] || return 0
    [ "${MAGICNET_WATCHDOG:-0}" = "1" ] || [ "${MAGICNET_NOTIFY_FORCE:-0}" = "1" ] || return 0
    import notify
    notify post "${1:-magicnet}" "${2:-MagicNet}" "${3:-event}" >/dev/null 2>&1 || true
}

magicnet_watchdog_start() {
    [ "${MAGICNET_WATCHDOG_ENABLED:-1}" != "0" ] || return 0
    [ "${MAGICNET_WATCHDOG:-0}" != "1" ] || return 0
    [ -f "${MODDIR}/cli" ] || return 0
    import watchdog
    _watchdog_notify_arg="--notify"
    [ "${MAGICNET_NOTIFY_ENABLED:-1}" != "0" ] || _watchdog_notify_arg="--no-notify"
    [ "${MAGICNET_WATCHDOG_NOTIFY:-1}" != "0" ] || _watchdog_notify_arg="--no-notify"
    KAM_WATCHDOG_NOTIFY_TITLE="${MAGICNET_WATCHDOG_NOTIFY_TITLE:-MagicNet}" \
        watchdog start "$_watchdog_notify_arg" "$(magicnet_watchdog_name)" "$(magicnet_watchdog_interval)" "$(magicnet_watchdog_command)" >/dev/null 2>&1 || true
    unset _watchdog_notify_arg
}

magicnet_watchdog_stop() {
    import watchdog
    watchdog stop "$(magicnet_watchdog_name)" >/dev/null 2>&1 || true
}

magicnet_watchdog_status() {
    _watchdog_pid_file="${KAM_HOME:-$MODDIR}/.state/watchdog/$(magicnet_watchdog_name).pid"
    [ -f "$_watchdog_pid_file" ] || return 1
    _watchdog_pid="$(sed -n '1p' "$_watchdog_pid_file" 2>/dev/null)"
    if [ -n "$_watchdog_pid" ] && kill -0 "$_watchdog_pid" 2>/dev/null; then
        printf '%s\n' "$_watchdog_pid"
        unset _watchdog_pid_file _watchdog_pid
        return 0
    fi
    unset _watchdog_pid_file _watchdog_pid
    return 1
}

magicnet_fswatch_name() {
    printf '%s\n' "magicnet-config"
}

magicnet_fswatch_interval() {
    printf '%s\n' "${MAGICNET_FSWATCH_INTERVAL:-15}"
}

magicnet_fswatch_path() {
    printf '%s\n' "${MODDIR}/.config"
}

magicnet_fswatch_command() {
    printf '%s\n' "MODDIR='$(magicnet_json_escape "$MODDIR")' sh '$(magicnet_json_escape "$MODDIR")/cli' config apply >/dev/null 2>&1"
}

magicnet_fswatch_start() {
    [ "${MAGICNET_FSWATCH_ENABLED:-1}" != "0" ] || return 0
    [ -d "$(magicnet_fswatch_path)" ] || return 0
    [ -f "${MODDIR}/cli" ] || return 0
    import fswatch
    KAM_FSWATCH_PRUNE_NAMES="${MAGICNET_FSWATCH_PRUNE_NAMES:-ui zashboard}" \
        fswatch start "$(magicnet_fswatch_name)" "$(magicnet_fswatch_path)" "$(magicnet_fswatch_interval)" "$(magicnet_fswatch_command)" >/dev/null 2>&1 || true
}

magicnet_fswatch_stop() {
    import fswatch
    fswatch stop "$(magicnet_fswatch_name)" >/dev/null 2>&1 || true
}

magicnet_fswatch_status() {
    _fswatch_pid_file="${KAM_HOME:-$MODDIR}/.state/fswatch/$(magicnet_fswatch_name).pid"
    [ -f "$_fswatch_pid_file" ] || return 1
    _fswatch_pid="$(sed -n '1p' "$_fswatch_pid_file" 2>/dev/null)"
    if [ -n "$_fswatch_pid" ] && kill -0 "$_fswatch_pid" 2>/dev/null; then
        printf '%s\n' "$_fswatch_pid"
        unset _fswatch_pid_file _fswatch_pid
        return 0
    fi
    unset _fswatch_pid_file _fswatch_pid
    return 1
}

magicnet_supervisors_start() {
    magicnet_watchdog_start
    magicnet_fswatch_start
}

magicnet_supervisors_stop() {
    magicnet_watchdog_stop
    magicnet_fswatch_stop
}

magicnet_status_text() {
    if "$1" >/dev/null 2>&1; then
        printf '%s\n' "Running"
    else
        printf '%s\n' "Stopped"
    fi
}

magicnet_refresh_status() {
    if ! magicnet_singbox_disabled && magicnet_cmd_exists sing-box; then
        import __singbox__
        is_singbox_running >/dev/null 2>&1 && return 0
    fi

    if magicnet_cmd_exists mihomo; then
        import __mihomo__
        is_mihomo_running >/dev/null 2>&1 && return 0
    fi

    config set override.description "[MagicNet]: No kernel running" 2>/dev/null || true
}

magicnet_start_mihomo() {
    [ "${MAGIC_MIHOMO:-1}" -ne 0 ] || return 1
    magicnet_cmd_exists mihomo || return 1
    import __mihomo__
    mihomo_start
}

magicnet_start_singbox() {
    [ "${MAGIC_SINGBOX:-1}" -ne 0 ] || return 1
    ! magicnet_singbox_disabled || return 1
    magicnet_cmd_exists sing-box || return 1
    import __singbox__
    singbox_start
}

magicnet_kernel_running() {
    if ! magicnet_singbox_disabled && magicnet_cmd_exists sing-box; then
        import __singbox__
        is_singbox_running >/dev/null 2>&1 && return 0
    fi

    if magicnet_cmd_exists mihomo; then
        import __mihomo__
        is_mihomo_running >/dev/null 2>&1 && return 0
    fi

    return 1
}

magicnet_start_kernel() {
    if magicnet_kernel_running; then
        magicnet_supervisors_start
        return 0
    fi

    if magicnet_start_singbox; then
        magicnet_after_kernel_start
        magicnet_notify "magicnet_guard" "MagicNet" "sing-box restarted by watchdog"
        magicnet_supervisors_start
        return 0
    fi

    if [ "${MAGIC_SINGBOX:-1}" -ne 0 ] && ! magicnet_singbox_disabled; then
        magicnet_warn "sing-box failed to start; attempting mihomo fallback..."
    fi

    if magicnet_start_mihomo; then
        magicnet_after_kernel_start
        magicnet_notify "magicnet_guard" "MagicNet" "mihomo restarted by watchdog"
        magicnet_supervisors_start
        return 0
    fi

    magicnet_warn "No supported kernel found or starting disabled (mihomo or sing-box)."
    return 1
}

magicnet_ensure_kernel() {
    magicnet_kernel_running && return 0
    MAGICNET_WATCHDOG=1 magicnet_start_kernel
}

magicnet_show_dashboard() {
    panel "MagicNet"
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        if magicnet_singbox_disabled; then
            _singbox_state="Disabled by .disable_sing_box"
        else
            _singbox_state=$(magicnet_status_text is_singbox_running)
        fi
    else
        _singbox_state="Not installed"
    fi

    if magicnet_cmd_exists mihomo; then
        import __mihomo__
        _mihomo_state=$(magicnet_status_text is_mihomo_running)
    else
        _mihomo_state="Not installed"
    fi

    panel_row "sing-box" "$_singbox_state"
    panel_row "mihomo" "$_mihomo_state"
    _watchdog_pid=$(magicnet_watchdog_status)
    panel_row "watchdog" "${_watchdog_pid:-Stopped}"
    _fswatch_pid=$(magicnet_fswatch_status)
    panel_row "fswatch" "${_fswatch_pid:-Stopped}"
    panel_row "WebUI" "http://127.0.0.1:9090/ui/"
    panel_row "sing-box subscription" "${MODDIR}/.config/sing-box/subscription.url"
    panel_end
}

magicnet_action_update_singbox_subscription() {
    if magicnet_singbox_disabled; then
        panel_warn "sing-box is disabled by ${MODDIR}/.disable_sing_box"
        return 0
    fi
    if ! magicnet_cmd_exists sing-box; then
        panel_error "sing-box is not installed"
        return 1
    fi

    . "${MODDIR}/lib/magicnet_singbox_subscribe.sh"
    magicnet_singbox_update_subscription
    magicnet_refresh_status
}

magicnet_action_singbox_webui() {
    if magicnet_singbox_disabled; then
        panel_warn "sing-box is disabled by ${MODDIR}/.disable_sing_box"
        return 0
    fi
    import __singbox__
    singbox_ask_webui
}

magicnet_action_toggle_singbox() {
    if magicnet_singbox_disabled; then
        panel_warn "sing-box is disabled by ${MODDIR}/.disable_sing_box"
        return 0
    fi
    import __singbox__
    toggle_singbox
    magicnet_refresh_status
    magicnet_after_kernel_start
}

magicnet_action_mihomo_webui() {
    import __mihomo__
    ask_webui
}

magicnet_action_toggle_mihomo() {
    import __mihomo__
    toggle_mihomo
    magicnet_refresh_status
    magicnet_after_kernel_start
}

magicnet_diag_http() {
    _name="$1"
    _url="$2"
    _proxy="${3:-}"
    if [ -n "$_proxy" ]; then
        _result=$(curl -fsSI --max-time 10 -x "$_proxy" "$_url" 2>&1 | head -n 1)
    else
        _result=$(curl -fsSI --max-time 10 "$_url" 2>&1 | head -n 1)
    fi
    [ -n "$_result" ] || _result="no response"
    panel_row "$_name" "$_result"
}

magicnet_diag_proxy_now() {
    _name="$1"
    _api=$(curl -sS --max-time 3 "http://127.0.0.1:9090/proxies/${_name}" 2>/dev/null || true)
    _now=$(printf '%s' "$_api" | sed -n 's/.*"now":[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$_now" ] || _now="unavailable"
    panel_row "$_name" "$_now"
}

magicnet_action_diagnose() {
    panel "MagicNet Diagnose"
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        panel_row "sing-box" "$(magicnet_status_text is_singbox_running)"
    else
        panel_row "sing-box" "Not installed"
    fi
    if magicnet_cmd_exists mihomo; then
        import __mihomo__
        panel_row "mihomo" "$(magicnet_status_text is_mihomo_running)"
    else
        panel_row "mihomo" "Not installed"
    fi
    _watchdog_pid=$(magicnet_watchdog_status)
    panel_row "watchdog" "${_watchdog_pid:-Stopped}"
    _fswatch_pid=$(magicnet_fswatch_status)
    panel_row "fswatch" "${_fswatch_pid:-Stopped}"
    panel_row "sing-box API" "$(curl -sS --max-time 3 http://127.0.0.1:9090/proxies >/dev/null 2>&1 && printf OK || printf FAIL)"
    magicnet_diag_proxy_now proxy
    magicnet_diag_proxy_now ai-proxy
    magicnet_diag_proxy_now final
    magicnet_diag_http "Baidu" "https://www.baidu.com"
    magicnet_diag_http "Google" "https://www.google.com" "http://127.0.0.1:7892"
    magicnet_diag_http "ChatGPT" "https://chatgpt.com" "http://127.0.0.1:7892"
    panel_end

    if [ -f "${MODDIR}/.log/sing-box.log" ]; then
        panel "sing-box recent errors"
        tail -n 80 "${MODDIR}/.log/sing-box.log" 2>/dev/null |
            grep -Ei 'error|fatal|warn|chatgpt|openai|dns|timeout|reset|forbidden' |
            tail -n 20 || true
        panel_end
    fi
}

set_i18n "MAGICNET_ACTION_MENU" \
    "zh" "MagicNet 操作菜单" \
    "en" "MagicNet action menu" \
    "ja" "MagicNet 操作メニュー" \
    "ko" "MagicNet 작업 메뉴"
set_i18n "MAGICNET_UPDATE_SINGBOX_SUBSCRIPTION" \
    "zh" "更新 sing-box 订阅节点" \
    "en" "Update sing-box subscription nodes" \
    "ja" "sing-box 購読ノードを更新" \
    "ko" "sing-box 구독 노드 업데이트"
set_i18n "MAGICNET_SINGBOX_WEBUI" \
    "zh" "设置 sing-box WebUI" \
    "en" "Set sing-box WebUI" \
    "ja" "sing-box WebUI を設定" \
    "ko" "sing-box WebUI 설정"
set_i18n "MAGICNET_TOGGLE_SINGBOX" \
    "zh" "启动/停止 sing-box" \
    "en" "Start/stop sing-box" \
    "ja" "sing-box を開始/停止" \
    "ko" "sing-box 시작/중지"
set_i18n "MAGICNET_MIHOMO_WEBUI" \
    "zh" "设置 mihomo WebUI" \
    "en" "Set mihomo WebUI" \
    "ja" "mihomo WebUI を設定" \
    "ko" "mihomo WebUI 설정"
set_i18n "MAGICNET_TOGGLE_MIHOMO" \
    "zh" "启动/停止 mihomo" \
    "en" "Start/stop mihomo" \
    "ja" "mihomo を開始/停止" \
    "ko" "mihomo 시작/중지"
set_i18n "MAGICNET_REFRESH_STATUS" \
    "zh" "刷新模块状态描述" \
    "en" "Refresh module status description" \
    "ja" "モジュール状態説明を更新" \
    "ko" "모듈 상태 설명 새로고침"
set_i18n "MAGICNET_DIAGNOSE" \
    "zh" "诊断网络状态" \
    "en" "Diagnose network status" \
    "ja" "ネットワーク状態を診断" \
    "ko" "네트워크 상태 진단"
set_i18n "MAGICNET_EXIT" \
    "zh" "退出" \
    "en" "Exit" \
    "ja" "終了" \
    "ko" "종료"

magicnet_action() {
    magicnet_show_dashboard
    ask "MAGICNET_ACTION_MENU" \
        "MAGICNET_UPDATE_SINGBOX_SUBSCRIPTION" \
        'magicnet_action_update_singbox_subscription' \
        "MAGICNET_SINGBOX_WEBUI" \
        'magicnet_action_singbox_webui' \
        "MAGICNET_TOGGLE_SINGBOX" \
        'magicnet_action_toggle_singbox' \
        "MAGICNET_MIHOMO_WEBUI" \
        'magicnet_action_mihomo_webui' \
        "MAGICNET_TOGGLE_MIHOMO" \
        'magicnet_action_toggle_mihomo' \
        "MAGICNET_DIAGNOSE" \
        'magicnet_action_diagnose' \
        "MAGICNET_REFRESH_STATUS" \
        'magicnet_refresh_status' \
        "MAGICNET_EXIT" \
        'exit 0' \
        0
}

kamfw_phase_boot_completed() {
    wait_boot_if_magisk
    sleep 3
    magicnet_start_kernel
}

kamfw_phase_service() {
    kamfw_phase_boot_completed "$@"
}

kamfw_phase_action() {
    magicnet_action
}
