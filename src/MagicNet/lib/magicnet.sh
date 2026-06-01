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
    magicnet_enable_hotspot_forward
    magicnet_enable_vpn_coexist
}

magicnet_singbox_disabled() {
    [ -f "${MODDIR}/.disable_sing_box" ]
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

magicnet_start_kernel() {
    if magicnet_start_singbox; then
        magicnet_after_kernel_start
        return 0
    fi

    if [ "${MAGIC_SINGBOX:-1}" -ne 0 ] && ! magicnet_singbox_disabled; then
        magicnet_warn "sing-box failed to start; attempting mihomo fallback..."
    fi

    if magicnet_start_mihomo; then
        magicnet_after_kernel_start
        return 0
    fi

    magicnet_warn "No supported kernel found or starting disabled (mihomo or sing-box)."
    return 1
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
