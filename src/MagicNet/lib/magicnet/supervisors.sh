magicnet_watchdog_name() {
    printf '%s\n' "magicnet-kernel"
}

magicnet_watchdog_interval() {
    printf '%s\n' "${MAGICNET_WATCHDOG_INTERVAL:-30}"
}

magicnet_watchdog_command() {
    printf '%s\n' "MAGICNET_WATCHDOG=1 MODDIR='$(magicnet_json_escape "$MODDIR")' '$(magicnet_json_escape "$MODDIR")/cli' service ensure >/dev/null 2>&1"
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
    printf '%s\n' "MODDIR='$(magicnet_json_escape "$MODDIR")' '$(magicnet_json_escape "$MODDIR")/cli' config apply >/dev/null 2>&1"
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
