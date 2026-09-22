# shellcheck shell=ash
# Compatibility for kamfw 35b2284: its one-second stop and failed-start
# SIGKILL interrupt sing-box's own firewall teardown. Keep this small lifecycle
# overlay in the module until the shared dependency carries the same fix.
# Ownership discovery, readiness, dataplane preparation and signaling stay in
# kamfw; callers keep the established singbox_start/singbox_stop interface.

import __singbox__ || return 1
# The pinned loader uses shared scratch names across nested imports. Explicitly
# register this module so a later import cannot replace these fixed functions
# with the old definitions. Do not export this shell-local registry to children.
case " ${KAM_MODULES:-} " in
    *" __singbox__ "*) ;;
    *) KAM_MODULES="${KAM_MODULES:-} __singbox__" ;;
esac

set_i18n "SINGBOX_START_CLEANUP_FAILED" \
    "zh" "sing-box 启动回收未完成，已取消重试。" \
    "en" "Partial sing-box shutdown is incomplete; startup retry aborted."
set_i18n "SINGBOX_STOP_PROCESS_CHANGED" \
    "zh" "停止期间 sing-box 进程已变化，未执行强制终止。" \
    "en" "sing-box process set changed during stop; escalation aborted."
set_i18n "SINGBOX_STOP_GRACE_EXPIRED" \
    "zh" "sing-box 正常退出等待超时，正在强制停止。" \
    "en" "sing-box graceful shutdown timed out; forcing stop."

singbox_start() {
    if is_singbox_running; then
        _singbox_start_state=0
    else
        _singbox_start_state=$?
    fi
    case "$_singbox_start_state" in
    0)
        warn "sing-box is already running."
        return 0
        ;;
    1) ;;
    *)
        error "sing-box process discovery is indeterminate; start aborted."
        return 2
        ;;
    esac

    _config="${MODDIR}/.config/sing-box/config.json"
    _log="${MODDIR}/.log/sing-box.log"
    _workdir="${MODDIR}/.config/sing-box"

    if [ ! -f "$_config" ]; then
        error "Config file not found: $_config"
        return 1
    fi
    if ! singbox_prepare_dataplane "$_config"; then
        unset _config _log _workdir
        return 1
    fi

    singbox_prepare_route_config "$_config"
    [ -d "${MODDIR}/.log" ] || mkdir -p "${MODDIR}/.log"

    _attempt=1
    while [ "$_attempt" -le "${MAGICNET_SINGBOX_START_ATTEMPTS:-1}" ]; do
        info "Starting sing-box..."
        # 使用 nohup 后台运行，并将日志重定向
        nohup sing-box run -c "$_config" -D "$_workdir" >"$_log" 2>&1 &

        if singbox_wait_ready; then
            success "sing-box started successfully."
            unset _config _log _workdir _attempt
            return 0
        fi

        warn "sing-box process did not stay running; stopping partial start."
        # Startup rollback needs the same graceful firewall teardown as a
        # manual stop. Never launch another generation if cleanup is unknown.
        if ! singbox_stop; then
            error "$(i18n 'SINGBOX_START_CLEANUP_FAILED')"
            unset _config _log _workdir _attempt
            return 2
        fi
        _attempt=$((_attempt + 1))
        [ "$_attempt" -le "${MAGICNET_SINGBOX_START_ATTEMPTS:-1}" ] && sleep 1
    done

    error "sing-box failed to start. Check $_log for details."
    if [ -f "$_log" ]; then
        print "--- Log tail ---"
        tail -n 5 "$_log"
        print "----------------"
    fi
    unset _config _log _workdir _attempt
    return 1
}

# Preserve discovery's tri-state result: 0 means the bounded wait expired
# with a live core, 1 means definitely stopped, 2 means indeterminate. Each
# discovery is already bounded; the budget below counts only polling sleeps.
singbox_wait_stopped() {
    _singbox_wait_file="$1"
    _singbox_wait_polls="$2"
    while :; do
        if singbox_pids_to_file "$_singbox_wait_file"; then
            :
        else
            _singbox_wait_state=$?
            case "$_singbox_wait_state" in
            1) return 1 ;;
            *) return 2 ;;
            esac
        fi
        [ "$_singbox_wait_polls" -gt 0 ] || return 0
        sleep 0.2 || return 2
        _singbox_wait_polls=$((_singbox_wait_polls - 1))
    done
}

singbox_stop() (
    _singbox_stop_file=$(magicnet_proc_query_temp_create) || return 2
    _singbox_stop_initial=$(magicnet_proc_query_temp_create) || {
        rm -f "$_singbox_stop_file"
        return 2
    }
    trap 'rm -f "$_singbox_stop_file" "$_singbox_stop_initial"' EXIT
    if singbox_pids_to_file "$_singbox_stop_initial"; then
        _singbox_stop_state=0
    else
        _singbox_stop_state=$?
    fi
    case "$_singbox_stop_state" in
    1)
        success "sing-box stopped."
        return 0
        ;;
    0) ;;
    *)
        error "sing-box process discovery is indeterminate; stop aborted."
        return 2
        ;;
    esac

    info "Stopping sing-box..."
    singbox_signal_pids_file "$_singbox_stop_initial" 15 || return 2
    # Android auto_redirect teardown can take ~3 seconds. Allow 10 seconds
    # of polling sleeps instead of interrupting cleanup with SIGKILL at 1s.
    if singbox_wait_stopped "$_singbox_stop_file" 50; then
        _singbox_stop_state=0
    else
        _singbox_stop_state=$?
    fi
    if [ "$_singbox_stop_state" -eq 0 ]; then
        # Newly discovered PIDs did not receive SIGTERM. Do not escalate a
        # replacement using the previous generation's already-expired budget.
        while IFS= read -r _singbox_stop_pid; do
            if ! grep -Fx "$_singbox_stop_pid" "$_singbox_stop_initial" >/dev/null 2>&1; then
                error "$(i18n 'SINGBOX_STOP_PROCESS_CHANGED')"
                return 2
            fi
        done <"$_singbox_stop_file"
        warn "$(i18n 'SINGBOX_STOP_GRACE_EXPIRED')"
        singbox_signal_pids_file "$_singbox_stop_file" 9 || return 2
        if singbox_wait_stopped "$_singbox_stop_file" 5; then
            _singbox_stop_state=0
        else
            _singbox_stop_state=$?
        fi
    fi
    case "$_singbox_stop_state" in
    1)
        success "sing-box stopped."
        return 0
        ;;
    2)
        error "sing-box stop state is indeterminate."
        return 2
        ;;
    *)
        error "Failed to stop sing-box."
        return 1
        ;;
    esac
)

