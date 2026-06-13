magicnet_watchdog_name() {
    printf '%s\n' "magicnet-kernel"
}

magicnet_watchdog_interval() {
    printf '%s\n' "${MAGICNET_WATCHDOG_INTERVAL:-30}"
}

magicnet_watchdog_command() {
    printf '%s\n' "MAGICNET_WATCHDOG=1 MODDIR='$(magicnet_json_escape "$MODDIR")' '$(magicnet_json_escape "$MODDIR")/cli' service ensure >/dev/null 2>&1"
}

magicnet_supervisor_orphan_pids() {
    return 1
}

magicnet_supervisor_kill_orphans() {
    _msko_target="$1"
    case "$_msko_target" in
        watchdog)
            pkill -f "${MODDIR}/cli.*service ensure" 2>/dev/null || true
            ;;
        fswatch)
            pkill -f "${MODDIR}/cli.*config apply" 2>/dev/null || true
            ;;
    esac
    sleep 1
    case "$_msko_target" in
        watchdog)
            pkill -9 -f "${MODDIR}/cli.*service ensure" 2>/dev/null || true
            ;;
        fswatch)
            pkill -9 -f "${MODDIR}/cli.*config apply" 2>/dev/null || true
            ;;
    esac
    unset _msko_target
}

set_i18n "MAGICNET_WATCHDOG_START_FAILED" \
    "zh" "watchdog 启动失败 (rc=\$_1)；请查看 \$_2" \
    "en" "watchdog failed to start (rc=\$_1); see \$_2"
set_i18n "MAGICNET_FSWATCH_START_FAILED" \
    "zh" "fswatch 启动失败 (rc=\$_1)；请查看 \$_2" \
    "en" "fswatch failed to start (rc=\$_1); see \$_2"

magicnet_supervisor_status_with_orphans() {
    _msswo_pid="$1"
    _msswo_target="$2"
    if [ -n "$_msswo_pid" ]; then
        printf '%s\n' "$_msswo_pid"
        unset _msswo_pid _msswo_target
        return 0
    fi
    _msswo_orphan="$(magicnet_supervisor_orphan_pids "$_msswo_target" | sed -n '1p')"
    if [ -n "$_msswo_orphan" ]; then
        printf '%s\n' "orphan:${_msswo_orphan}"
        unset _msswo_pid _msswo_target _msswo_orphan
        return 0
    fi
    unset _msswo_pid _msswo_target _msswo_orphan
    return 1
}

magicnet_notify() {
    [ "${MAGICNET_NOTIFY_ENABLED:-1}" != "0" ] || return 0
    [ "${MAGICNET_WATCHDOG:-0}" = "1" ] || [ "${MAGICNET_NOTIFY_FORCE:-0}" = "1" ] || return 0
    import notify
    notify post "${1:-magicnet}" "${2:-MagicNet}" "${3:-event}" >/dev/null 2>&1 || true
}

magicnet_supervisor_stop_pidfile() {
    _mssp_pid_file="$1"
    if [ -f "$_mssp_pid_file" ]; then
        _mssp_pid="$(sed -n '1p' "$_mssp_pid_file" 2>/dev/null)"
        if [ -n "$_mssp_pid" ]; then
            kill "$_mssp_pid" 2>/dev/null || true
        fi
        rm -f "$_mssp_pid_file" 2>/dev/null || true
    fi
    unset _mssp_pid_file _mssp_pid
}

magicnet_watchdog_start() {
    [ "${MAGICNET_WATCHDOG_ENABLED:-1}" != "0" ] || return 0
    [ "${MAGICNET_WATCHDOG:-0}" != "1" ] || return 0
    [ -f "${MODDIR}/cli" ] || return 0
    magicnet_any_subscription_ready || {
        magicnet_mark_subscription_missing
        magicnet_watchdog_stop >/dev/null 2>&1 || true
        return 1
    }
    import watchdog
    _watchdog_notify_arg="--notify"
    [ "${MAGICNET_NOTIFY_ENABLED:-1}" != "0" ] || _watchdog_notify_arg="--no-notify"
    [ "${MAGICNET_WATCHDOG_NOTIFY:-1}" != "0" ] || _watchdog_notify_arg="--no-notify"
    KAM_WATCHDOG_NOTIFY_TITLE="${MAGICNET_WATCHDOG_NOTIFY_TITLE:-MagicNet}" \
        KAM_WATCHDOG_LOG_FILE="${MODDIR}/.log/watchdog.log" \
        watchdog start "$_watchdog_notify_arg" "$(magicnet_watchdog_name)" "$(magicnet_watchdog_interval)" "$(magicnet_watchdog_command)"
    _watchdog_rc=$?
    if [ "$_watchdog_rc" -ne 0 ]; then
        magicnet_warn "$(i18n "MAGICNET_WATCHDOG_START_FAILED" | t "$_watchdog_rc" "${MODDIR}/.log/watchdog.log")"
    fi
    unset _watchdog_notify_arg
    return "$_watchdog_rc"
}

magicnet_watchdog_stop() {
    magicnet_supervisor_stop_pidfile "${KAM_HOME:-$MODDIR}/.state/watchdog/$(magicnet_watchdog_name).pid"
    magicnet_supervisor_kill_orphans watchdog
}

magicnet_watchdog_status() {
    _watchdog_pid_file="${KAM_HOME:-$MODDIR}/.state/watchdog/$(magicnet_watchdog_name).pid"
    if [ ! -f "$_watchdog_pid_file" ]; then
        unset _watchdog_pid_file
        magicnet_supervisor_status_with_orphans "" watchdog
        return $?
    fi
    _watchdog_pid="$(sed -n '1p' "$_watchdog_pid_file" 2>/dev/null)"
    if [ -n "$_watchdog_pid" ] && kill -0 "$_watchdog_pid" 2>/dev/null; then
        magicnet_supervisor_status_with_orphans "$_watchdog_pid" watchdog
        unset _watchdog_pid_file _watchdog_pid
        return 0
    fi
    unset _watchdog_pid_file _watchdog_pid
    magicnet_supervisor_status_with_orphans "" watchdog
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
    printf '%s\n' "MODDIR='$(magicnet_json_escape "$MODDIR")' '$(magicnet_json_escape "$MODDIR")/cli' config apply >/dev/null 2>&1"
}

magicnet_fswatch_start() {
    [ "${MAGICNET_FSWATCH_ENABLED:-1}" != "0" ] || return 0
    [ -d "$(magicnet_fswatch_path)" ] || return 0
    [ -f "${MODDIR}/cli" ] || return 0
    import fswatch
    KAM_FSWATCH_PRUNE_NAMES="${MAGICNET_FSWATCH_PRUNE_NAMES:-ui zashboard}" \
        KAM_FSWATCH_LOG_FILE="${MODDIR}/.log/fswatch.log" \
        fswatch start "$(magicnet_fswatch_name)" "$(magicnet_fswatch_path)" "$(magicnet_fswatch_interval)" "$(magicnet_fswatch_command)"
    _fswatch_rc=$?
    if [ "$_fswatch_rc" -ne 0 ]; then
        magicnet_warn "$(i18n "MAGICNET_FSWATCH_START_FAILED" | t "$_fswatch_rc" "${MODDIR}/.log/fswatch.log")"
    fi
    return "$_fswatch_rc"
}

magicnet_fswatch_stop() {
    magicnet_supervisor_stop_pidfile "${KAM_HOME:-$MODDIR}/.state/fswatch/$(magicnet_fswatch_name).pid"
    magicnet_supervisor_kill_orphans fswatch
}

magicnet_fswatch_status() {
    _fswatch_pid_file="${KAM_HOME:-$MODDIR}/.state/fswatch/$(magicnet_fswatch_name).pid"
    if [ ! -f "$_fswatch_pid_file" ]; then
        unset _fswatch_pid_file
        magicnet_supervisor_status_with_orphans "" fswatch
        return $?
    fi
    _fswatch_pid="$(sed -n '1p' "$_fswatch_pid_file" 2>/dev/null)"
    if [ -n "$_fswatch_pid" ] && kill -0 "$_fswatch_pid" 2>/dev/null; then
        magicnet_supervisor_status_with_orphans "$_fswatch_pid" fswatch
        unset _fswatch_pid_file _fswatch_pid
        return 0
    fi
    unset _fswatch_pid_file _fswatch_pid
    magicnet_supervisor_status_with_orphans "" fswatch
}

magicnet_supervisors_start() {
    _mss_rc=0
    magicnet_watchdog_start || _mss_rc=1
    magicnet_fswatch_start || _mss_rc=1
    return "$_mss_rc"
}

magicnet_supervisors_stop() {
    magicnet_watchdog_stop
    magicnet_fswatch_stop
}
