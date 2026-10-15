magicnet_action_update_singbox_subscription() {
    if ! magicnet_cmd_exists sing-box; then
        panel_error "$(i18n MAGICNET_SINGBOX_MISSING)"
        return 1
    fi

    if "${MODDIR}/cli" sub update sing-box; then
        _action_update_status=0
    else
        _action_update_status=$?
    fi
    if [ "${_action_update_status}" -eq 0 ]; then
        rm -f "${MODDIR}/.tmp/magicnet-node-list.cache"
    fi
    magicnet_refresh_status || true
    return "${_action_update_status}"
}

magicnet_action_toggle_singbox() {
    # Keep Magisk action semantics identical to WebUI/CLI lifecycle handling.
    # The Rust command owns supervisor quiescing, fail-open network cleanup,
    # process discovery, rollback, and bounded startup retries.
    "$MODDIR/cli" service toggle sing-box
    _status=$?
    magicnet_refresh_status || true
    return "$_status"
}

magicnet_diag_http() {
    _name="$1"
    _url="$2"
    _proxy="${3:-}"
    _format='HTTP %{http_code} connect=%{time_connect} start=%{time_starttransfer} total=%{time_total}'
    if [ -n "$_proxy" ]; then
        if _result=$(magicnet_trusted_curl_exec -sS -o /dev/null --connect-timeout 5 --max-time 10 -w "$_format" -x "$_proxy" "$_url" 2>/dev/null); then
            _curl_rc=0
        else
            _curl_rc=$?
        fi
    else
        if _result=$(magicnet_trusted_curl_exec -sS -o /dev/null --connect-timeout 5 --max-time 10 -w "$_format" "$_url" 2>/dev/null); then
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

magicnet_diag_api_endpoint() {
    "${MODDIR}/cli" api endpoint 2>/dev/null
}

magicnet_diag_proxy_now() {
    _name="$1"
    _endpoint="$(magicnet_diag_api_endpoint 2>/dev/null || true)"
    if [ -n "$_endpoint" ]; then
        _api=$(magicnet_trusted_curl_exec -sS --max-time 3 "${_endpoint}/proxies/${_name}" 2>/dev/null || true)
    else
        _api=''
    fi
    _now=$(printf '%s' "$_api" | sed -n 's/.*"now":[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$_now" ] || _now="$(i18n MAGICNET_UNAVAILABLE)"
    panel_row "$_name" "$_now"
    unset _name _endpoint _api _now
}

magicnet_diag_module_version() {
    _version=$(sed -n 's/^version=//p' "${MODDIR}/module.prop" 2>/dev/null | head -n 1)
    [ -n "$_version" ] || _version="$(i18n MAGICNET_UNAVAILABLE)"
    printf '%s\n' "$_version"
    unset _version
}

magicnet_diag_transparent_mode() {
    if _mode=$(magicnet_transparent_mode 2>/dev/null); then
        :
    else
        _mode="invalid"
    fi
    printf '%s\n' "$_mode"
    unset _mode
}

magicnet_action_diagnose() {
    panel "$(i18n MAGICNET_DIAGNOSE_TITLE)"
    panel_row "Version" "$(magicnet_diag_module_version)"
    panel_row "Mode" "$(magicnet_diag_transparent_mode)"
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        panel_row "sing-box" "$(magicnet_display_status "$(magicnet_status_text is_singbox_running)")"
    else
        panel_row "sing-box" "$(i18n MAGICNET_NOT_INSTALLED)"
    fi
    _fswatch_pid=$(magicnet_fswatch_status)
    panel_row "fswatch" "$(magicnet_display_status "${_fswatch_pid:-Stopped}")"
    _diag_api="$(magicnet_diag_api_endpoint 2>/dev/null || true)"
    if [ -n "$_diag_api" ] && magicnet_trusted_curl_exec -sS --max-time 3 "${_diag_api}/proxies" >/dev/null 2>&1; then
        panel_row "sing-box API" "OK"
    else
        panel_row "sing-box API" "FAIL"
    fi
    unset _diag_api
    magicnet_diag_proxy_now proxy
    magicnet_diag_proxy_now ai-proxy
    magicnet_diag_proxy_now final
    magicnet_diag_http "Baidu" "https://www.baidu.com"
    magicnet_diag_http "Google" "https://www.google.com" "http://127.0.0.1:7892"
    magicnet_diag_http "ChatGPT" "https://chatgpt.com" "http://127.0.0.1:7892"
    panel_end

    if [ -f "${MODDIR}/.log/sing-box.log" ]; then
        panel "$(i18n MAGICNET_RECENT_ERRORS)"
        tail -n 80 "${MODDIR}/.log/sing-box.log" 2>/dev/null |
            grep -Ei 'error|fatal|warn|chatgpt|openai|dns|timeout|reset|forbidden' |
            tail -n 20 || true
        panel_end
    fi
}

magicnet_action_network_acceptance() {
    if [ ! -r "${MODDIR}/network-check.sh" ]; then
        panel_error "network-check.sh: $(i18n MAGICNET_UNAVAILABLE)"
        return 1
    fi
    sh "${MODDIR}/network-check.sh" --rounds 1 --jobs 4
}

set_i18n "MAGICNET_ACTION_MENU" \
    "zh" "MagicNet 操作菜单" \
    "en" "MagicNet action menu" \
    "ru" "Меню действий MagicNet" \
    "ja" "MagicNet 操作メニュー" \
    "ko" "MagicNet 작업 메뉴"
set_i18n "MAGICNET_UPDATE_SINGBOX_SUBSCRIPTION" \
    "zh" "更新 sing-box 订阅节点" \
    "en" "Update sing-box subscription nodes" \
    "ru" "Обновить узлы подписки sing-box" \
    "ja" "sing-box 購読ノードを更新" \
    "ko" "sing-box 구독 노드 업데이트"
set_i18n "MAGICNET_TOGGLE_SINGBOX" \
    "zh" "启动/停止 sing-box" \
    "en" "Start/stop sing-box" \
    "ru" "Запустить/остановить sing-box" \
    "ja" "sing-box を開始/停止" \
    "ko" "sing-box 시작/중지"
set_i18n "MAGICNET_REFRESH_STATUS" \
    "zh" "刷新模块状态描述" \
    "en" "Refresh module status description" \
    "ru" "Обновить описание состояния модуля" \
    "ja" "モジュール状態説明を更新" \
    "ko" "모듈 상태 설명 새로고침"
set_i18n "MAGICNET_DIAGNOSE" \
    "zh" "诊断网络状态" \
    "en" "Diagnose network status" \
    "ru" "Диагностика сети" \
    "ja" "ネットワーク状態を診断" \
    "ko" "네트워크 상태 진단"
set_i18n "MAGICNET_NETWORK_ACCEPTANCE" \
    "zh" "完整网络验收" \
    "en" "Run full network acceptance" \
    "ru" "Полная проверка сети" \
    "ja" "完全なネットワーク検証" \
    "ko" "전체 네트워크 검증"
set_i18n "MAGICNET_EXIT" \
    "zh" "退出" \
    "en" "Exit" \
    "ru" "Выход" \
    "ja" "終了" \
    "ko" "종료"

set_i18n "MAGICNET_START_SINGBOX" \
    "zh" "启动 sing-box" \
    "en" "Start sing-box" \
    "ru" "Запустить sing-box" \
    "ja" "sing-box を起動" \
    "ko" "sing-box 시작"
set_i18n "MAGICNET_STOP_SINGBOX" \
    "zh" "停止 sing-box" \
    "en" "Stop sing-box" \
    "ru" "Остановить sing-box" \
    "ja" "sing-box を停止" \
    "ko" "sing-box 중지"
set_i18n "MAGICNET_ACTION_CANCEL" \
    "zh" "取消，保持现状" \
    "en" "Cancel and keep current state" \
    "ru" "Отменить, ничего не менять" \
    "ja" "キャンセルして現状を維持" \
    "ko" "취소하고 현재 상태 유지"
set_i18n "MAGICNET_ACTION_PROCEED" \
    "zh" "确认执行" \
    "en" "Confirm action" \
    "ru" "Подтвердить действие" \
    "ja" "実行を確認" \
    "ko" "실행 확인"
set_i18n "MAGICNET_ACTION_STOP_CONFIRM" \
    "zh" "停止 sing-box 并释放网络接管？设备流量将回到系统网络。" \
    "en" "Stop sing-box and release network interception? Device traffic will return to the system network." \
    "ru" "Остановить sing-box и отключить перехват? Трафик вернётся в системную сеть." \
    "ja" "sing-box を停止し、ネットワーク制御を解除しますか？端末の通信はシステムネットワークに戻ります。" \
    "ko" "sing-box를 중지하고 네트워크 제어를 해제할까요? 기기 트래픽이 시스템 네트워크로 돌아갑니다."
set_i18n "MAGICNET_ACTION_UPDATE_CONFIRM" \
    "zh" "更新订阅会下载并校验节点，成功后替换配置，可能短暂中断连接。继续？" \
    "en" "Updating downloads and validates nodes, then replaces the configuration on success. Connections may briefly pause. Continue?" \
    "ru" "Обновление загрузит и проверит узлы, затем заменит конфигурацию. Возможен краткий перерыв связи. Продолжить?" \
    "ja" "購読をダウンロード・検証し、成功後に設定を置き換えます。接続が一時中断する場合があります。続行しますか？" \
    "ko" "구독을 다운로드하고 검증한 후 성공하면 설정을 교체합니다. 연결이 잠시 끊길 수 있습니다. 계속할까요?"
set_i18n "MAGICNET_ACTION_INPUT" \
    "zh" "输入 0–6 后回车；直接回车退出。" \
    "en" "Enter 0–6; press Enter without a number to exit." \
    "ru" "Введите 0–6; пустой ввод — выход." \
    "ja" "0〜6 を入力して Enter。空欄で終了。" \
    "ko" "0–6을 입력하고 Enter를 누르세요. 빈 입력은 종료합니다."
set_i18n "MAGICNET_ACTION_CONFIRM_INPUT" \
    "zh" "输入 y 确认；其他输入或直接回车取消。" \
    "en" "Enter y to confirm; any other input cancels." \
    "ru" "Введите y для подтверждения; любой другой ввод отменяет действие." \
    "ja" "確認するには y を入力。それ以外はキャンセル。" \
    "ko" "확인하려면 y를 입력하세요. 다른 입력은 취소합니다."
set_i18n "MAGICNET_ACTION_INVALID" \
    "zh" "请输入 0–6；没有执行任何操作。" \
    "en" "Enter a number from 0 to 6. No action was performed." \
    "ru" "Введите число от 0 до 6. Действие не выполнено." \
    "ja" "0〜6 を入力してください。操作は実行されていません。" \
    "ko" "0–6 사이의 숫자를 입력하세요. 아무 작업도 실행하지 않았습니다."
set_i18n "MAGICNET_ACTION_INPUT_MISSING" \
    "zh" "无法读取音量键。请从终端运行 action.sh，或使用 WebUI。" \
    "en" "Volume-key input is unavailable. Run action.sh in a terminal or use WebUI." \
    "ru" "Ввод клавишами громкости недоступен. Запустите action.sh в терминале или используйте WebUI." \
    "ja" "音量キーを読み取れません。端末で action.sh を実行するか WebUI を使用してください。" \
    "ko" "음량 키를 읽을 수 없습니다. 터미널에서 action.sh를 실행하거나 WebUI를 사용하세요."
set_i18n "MAGICNET_ACTION_NONINTERACTIVE" \
    "zh" "非交互模式：仅显示状态，不执行操作。请使用 cli 或 WebUI 选择操作。" \
    "en" "Noninteractive mode: showing status only. Choose an action through cli or WebUI." \
    "ru" "Неинтерактивный режим: показан только статус. Выберите действие через cli или WebUI." \
    "ja" "非対話モード: 状態のみを表示します。cli または WebUI で操作を選んでください。" \
    "ko" "비대화형 모드: 상태만 표시합니다. cli 또는 WebUI에서 작업을 선택하세요."
set_i18n "MAGICNET_ACTION_CLI_MISSING" \
    "zh" "cli 入口不可执行。请重新安装模块后重试。" \
    "en" "The cli entry is not executable. Reinstall the module and try again." \
    "ru" "Файл cli недоступен для выполнения. Переустановите модуль." \
    "ja" "cli を実行できません。モジュールを再インストールしてください。" \
    "ko" "cli를 실행할 수 없습니다. 모듈을 다시 설치하세요."

# ask is a rendering/selection API; it does not preserve the selected command's
# exit status. Select a fixed token first, then dispatch outside ask.
magicnet_action_confirm() (
    if [ -t 0 ]; then
        panel_warn "$(i18n "$1")"
        print "$(i18n MAGICNET_ACTION_CONFIRM_INPUT)"
        IFS= read -r _action_answer || return 1
        [ "$_action_answer" = y ] || [ "$_action_answer" = Y ]
        return $?
    fi
    _action_confirmed=0
    ask "$1" \
        "MAGICNET_ACTION_CANCEL" ':' \
        "MAGICNET_ACTION_PROCEED" '_action_confirmed=1' 0
    [ "$_action_confirmed" = 1 ]
)

magicnet_action_service() {
    case "$1" in start | stop) ;; *) return 64 ;; esac
    if [ ! -x "$MODDIR/cli" ]; then
        panel_error "$(i18n MAGICNET_ACTION_CLI_MISSING)"
        return 1
    fi
    if "$MODDIR/cli" service "$1" sing-box; then
        _action_service_status=0
    else
        _action_service_status=$?
    fi
    magicnet_refresh_status || true
    return "$_action_service_status"
}

magicnet_action_choose() {
    _action_choice='exit'
    if [ -t 0 ]; then
        panel "$(i18n MAGICNET_ACTION_MENU)"
        panel_row 1 "$(i18n MAGICNET_DIAGNOSE)"
        panel_row 2 "$(i18n MAGICNET_START_SINGBOX)"
        panel_row 3 "$(i18n MAGICNET_STOP_SINGBOX)"
        panel_row 4 "$(i18n MAGICNET_UPDATE_SINGBOX_SUBSCRIPTION)"
        panel_row 5 "$(i18n MAGICNET_NETWORK_ACCEPTANCE)"
        panel_row 6 "$(i18n MAGICNET_REFRESH_STATUS)"
        panel_row 0 "$(i18n MAGICNET_EXIT)"
        while :; do
            print "$(i18n MAGICNET_ACTION_INPUT)"
            IFS= read -r _action_input || return 0
            case "$_action_input" in
                1) _action_choice=diagnose; break ;;
                2) _action_choice=start; break ;;
                3) _action_choice=stop; break ;;
                4) _action_choice=update; break ;;
                5) _action_choice=acceptance; break ;;
                6) _action_choice=refresh; break ;;
                0 | '') break ;;
                *) panel_warn "$(i18n MAGICNET_ACTION_INVALID)" ;;
            esac
        done
    else
        command -v getevent >/dev/null 2>&1 || {
            panel_error "$(i18n MAGICNET_ACTION_INPUT_MISSING)"
            return 1
        }
        ask "MAGICNET_ACTION_MENU" \
            "MAGICNET_DIAGNOSE" '_action_choice=diagnose' \
            "MAGICNET_START_SINGBOX" '_action_choice=start' \
            "MAGICNET_STOP_SINGBOX" '_action_choice=stop' \
            "MAGICNET_UPDATE_SINGBOX_SUBSCRIPTION" '_action_choice=update' \
            "MAGICNET_NETWORK_ACCEPTANCE" '_action_choice=acceptance' \
            "MAGICNET_REFRESH_STATUS" '_action_choice=refresh' \
            "MAGICNET_EXIT" '_action_choice=exit' 0
    fi
}

magicnet_action() (
    magicnet_show_dashboard
    # Explicit automation never waits for volume keys or changes the device.
    if [ "${MAGICNET_NONINTERACTIVE:-0}" = 1 ]; then
        panel_note "$(i18n MAGICNET_ACTION_NONINTERACTIVE)"
        return 0
    fi
    magicnet_action_choose || return $?
    case "$_action_choice" in
        start) magicnet_action_service start ;;
        stop)
            magicnet_action_confirm MAGICNET_ACTION_STOP_CONFIRM || return 0
            magicnet_action_service stop ;;
        update)
            magicnet_action_confirm MAGICNET_ACTION_UPDATE_CONFIRM || return 0
            magicnet_action_update_singbox_subscription ;;
        diagnose) magicnet_action_diagnose ;;
        acceptance) magicnet_action_network_acceptance ;;
        refresh) magicnet_refresh_status ;;
        exit) return 0 ;;
        *) return 64 ;;
    esac
)
