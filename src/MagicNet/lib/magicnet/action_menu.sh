magicnet_action_update_singbox_subscription() {
    if ! magicnet_cmd_exists sing-box; then
        panel_error "sing-box is not installed"
        return 1
    fi

    . "${MODDIR}/lib/magicnet_singbox_subscribe.sh"
    magicnet_singbox_update_subscription
    magicnet_refresh_status
}

magicnet_action_singbox_webui() {
    import __singbox__
    singbox_ask_webui
}

magicnet_action_toggle_singbox() {
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
