magicnet_action_update_singbox_subscription() {
    if ! magicnet_cmd_exists sing-box; then
        panel_error "sing-box is not installed"
        return 1
    fi

    "${MODDIR}/cli" sub update sing-box
    _status=$?
    if [ "${_status}" -eq 0 ]; then
        rm -f "${MODDIR}/.tmp/magicnet-node-list.cache"
    fi
    magicnet_refresh_status
    return "${_status}"
}

magicnet_action_toggle_singbox() {
    import __singbox__
    if is_singbox_running >/dev/null 2>&1; then
        _running_status=0
    else
        _running_status=$?
    fi
    case "$_running_status" in
    0)
        singbox_stop
        _status=$?
        if [ "$_status" -eq 0 ]; then
            magicnet_disable_dns_capture || true
            magicnet_disable_dns_leak_guard || true
        fi
        ;;
    1)
        magicnet_start_kernel
        _status=$?
        ;;
    *)
        panel_error "sing-box process discovery is indeterminate"
        _status=2
        ;;
    esac
    magicnet_refresh_status || true
    return "$_status"
}

magicnet_diag_http() {
    _name="$1"
    _url="$2"
    _proxy="${3:-}"
    _format='HTTP %{http_code} connect=%{time_connect} start=%{time_starttransfer} total=%{time_total}'
    if [ -n "$_proxy" ]; then
        if _result=$(curl -sS -o /dev/null --connect-timeout 5 --max-time 10 -w "$_format" -x "$_proxy" "$_url" 2>/dev/null); then
            _curl_rc=0
        else
            _curl_rc=$?
        fi
    else
        if _result=$(curl -sS -o /dev/null --connect-timeout 5 --max-time 10 -w "$_format" "$_url" 2>/dev/null); then
            _curl_rc=0
        else
            _curl_rc=$?
        fi
    fi
    [ -n "$_result" ] || _result="HTTP 000 connect=n/a start=n/a total=n/a"
    [ "$_curl_rc" -eq 0 ] || _result="${_result} rc=${_curl_rc}"
    panel_row "$_name" "$_result"
    unset _name _url _proxy _format _result _curl_rc
    return 0
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
set_i18n "MAGICNET_TOGGLE_SINGBOX" \
    "zh" "启动/停止 sing-box" \
    "en" "Start/stop sing-box" \
    "ja" "sing-box を開始/停止" \
    "ko" "sing-box 시작/중지"
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
        "MAGICNET_TOGGLE_SINGBOX" \
        'magicnet_action_toggle_singbox' \
        "MAGICNET_DIAGNOSE" \
        'magicnet_action_diagnose' \
        "MAGICNET_REFRESH_STATUS" \
        'magicnet_refresh_status' \
        "MAGICNET_EXIT" \
        'exit 0' \
        0
}
