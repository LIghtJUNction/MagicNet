magicnet_supervisor_target_pid_matches() (
    _mstm_target="$1"
    _mstm_pid_file="$2"
    _mstm_pid="$3"
    case "$_mstm_target" in
    fswatch | watchdog | hotspot-watchdog) magicnet_supervisor_pidfile_matches "$_mstm_pid_file" "$_mstm_pid" ;;
    wifi-policy) magicnet_wifi_policy_pid_matches "$_mstm_pid" ;;
    *) return 1 ;;
    esac
)

magicnet_supervisor_orphan_pids() (
    _mso_target="$1"
    case "$_mso_target" in
    fswatch) _mso_pid_file="${KAM_HOME:-$MODDIR}/.state/fswatch/$(magicnet_fswatch_name).pid" ;;
    watchdog) _mso_pid_file="${KAM_HOME:-$MODDIR}/.state/watchdog/magicnet-kernel.pid" ;;
    hotspot-watchdog) _mso_pid_file="${KAM_HOME:-$MODDIR}/.state/watchdog/$(magicnet_hotspot_watchdog_name).pid" ;;
    wifi-policy) _mso_pid_file="$(magicnet_wifi_policy_pid_file)" ;;
    *) return 1 ;;
    esac

    _mso_ps=$(ps -A -o pid=,args= 2>/dev/null || true)
    if [ -n "$_mso_ps" ]; then
        _mso_candidates=$(printf '%s\n' "$_mso_ps" |
            awk -v root="$MODDIR" 'index($0, root) { print $1 }')
    else
        _mso_candidates=$(for _mso_proc in /proc/[0-9]*; do
            [ -d "$_mso_proc" ] && printf '%s\n' "${_mso_proc##*/}"
        done)
    fi
    _mso_result=''
    for _mso_pid in $_mso_candidates; do
        [ "$_mso_pid" = "$$" ] && continue
        if magicnet_supervisor_target_pid_matches "$_mso_target" "$_mso_pid_file" "$_mso_pid"; then
            _mso_match_rc=0
        else
            _mso_match_rc=$?
        fi
        [ "$_mso_match_rc" -ne 2 ] || return 2
        [ "$_mso_match_rc" -eq 0 ] || continue
        _mso_result="${_mso_result}${_mso_result:+
}${_mso_pid}"
    done
    [ -n "$_mso_result" ] || return 1
    printf '%s\n' "$_mso_result"
    return 0
)

magicnet_trim_log_file() {
    _trim_log_file="$1"
    _trim_log_max="${2:-1048576}"
    _trim_log_keep="${3:-524288}"
    [ -f "$_trim_log_file" ] || {
        unset _trim_log_file _trim_log_max _trim_log_keep
        return 0
    }
    _trim_log_size=$(wc -c <"$_trim_log_file" 2>/dev/null | tr -d ' ')
    case "$_trim_log_size" in '' | *[!0-9]*) _trim_log_size=0 ;; esac
    if [ "$_trim_log_size" -gt "$_trim_log_max" ]; then
        _trim_log_tmp="${_trim_log_file}.trim.$$"
        if tail -c "$_trim_log_keep" "$_trim_log_file" >"$_trim_log_tmp" 2>/dev/null; then
            cat "$_trim_log_tmp" >"$_trim_log_file" 2>/dev/null || true
        fi
        rm -f "$_trim_log_tmp" 2>/dev/null || true
    fi
    unset _trim_log_file _trim_log_max _trim_log_keep _trim_log_size _trim_log_tmp
}

magicnet_supervisor_kill_orphans() (
    _msko_target="$1"
    if _msko_pids=$(magicnet_supervisor_orphan_pids "$_msko_target"); then
        _msko_rc=0
    else
        _msko_rc=$?
    fi
    [ "$_msko_rc" -ne 2 ] || return 2
    [ "$_msko_rc" -eq 0 ] || return 0
    for _msko_pid in $_msko_pids; do
        kill "$_msko_pid" 2>/dev/null || true
    done
    _msko_attempt=0
    while [ "$_msko_attempt" -lt 20 ]; do
        if _msko_pids=$(magicnet_supervisor_orphan_pids "$_msko_target"); then
            _msko_rc=0
        else
            _msko_rc=$?
        fi
        [ "$_msko_rc" -ne 2 ] || return 2
        [ "$_msko_rc" -eq 0 ] || return 0
        _msko_attempt=$((_msko_attempt + 1))
        [ "$_msko_attempt" -lt 20 ] && sleep 0.05
    done
    for _msko_pid in $_msko_pids; do
        kill -9 "$_msko_pid" 2>/dev/null || true
    done
    sleep 0.05
)

set_i18n "MAGICNET_FSWATCH_START_FAILED" \
    "zh" "fswatch 启动失败 (rc=\$_1)；请查看 \$_2" \
    "en" "fswatch failed to start (rc=\$_1); see \$_2"
set_i18n "MAGICNET_FSWATCH_FLOCK_INCOMPATIBLE" \
    "zh" "fswatch 找到的 flock 不兼容: \$_1；请使用 APatch/KSU/Magisk BusyBox" \
    "en" "fswatch found an incompatible flock: \$_1; use the APatch/KSU/Magisk BusyBox"

magicnet_supervisor_status_with_orphans() {
    _msswo_pid="$1"
    _msswo_target="$2"
    if [ -n "$_msswo_pid" ]; then
        printf '%s\n' "$_msswo_pid"
        unset _msswo_pid _msswo_target
        return 0
    fi
    if _msswo_orphans=$(magicnet_supervisor_orphan_pids "$_msswo_target"); then
        _msswo_orphan_rc=0
        _msswo_orphan=$(printf '%s\n' "$_msswo_orphans" | sed -n '1p')
    else
        _msswo_orphan_rc=$?
        _msswo_orphan=''
    fi
    [ "$_msswo_orphan_rc" -ne 2 ] || return 2
    if [ -n "$_msswo_orphan" ]; then
        printf '%s\n' "orphan:${_msswo_orphan}"
        return 0
    fi
    return 1
}

magicnet_notify() {
    [ "${MAGICNET_NOTIFY_ENABLED:-1}" != "0" ] || return 0
    import notify
    notify post "${1:-magicnet}" "${2:-MagicNet}" "${3:-event}" >/dev/null 2>&1 || true
}

magicnet_supervisor_stop_pidfile() {
    _mssp_pid_file="$1"
    [ -f "$_mssp_pid_file" ] || return 0
    _mssp_pid="$(sed -n '1p' "$_mssp_pid_file" 2>/dev/null)"
    if magicnet_supervisor_pidfile_matches "$_mssp_pid_file" "$_mssp_pid"; then
        _mssp_match_rc=0
    else
        _mssp_match_rc=$?
    fi
    [ "$_mssp_match_rc" -ne 2 ] || return 2
    if [ "$_mssp_match_rc" -eq 0 ]; then
        kill "$_mssp_pid" 2>/dev/null || true
        _mssp_attempt=0
        while [ "$_mssp_attempt" -lt 20 ]; do
            if magicnet_supervisor_pidfile_matches "$_mssp_pid_file" "$_mssp_pid"; then
                _mssp_match_rc=0
            else
                _mssp_match_rc=$?
            fi
            [ "$_mssp_match_rc" -ne 2 ] || return 2
            [ "$_mssp_match_rc" -eq 0 ] || break
            _mssp_attempt=$((_mssp_attempt + 1))
            [ "$_mssp_attempt" -lt 20 ] && sleep 0.05
        done
        if [ "$_mssp_match_rc" -eq 0 ]; then
            kill -9 "$_mssp_pid" 2>/dev/null || true
            sleep 0.05
            if magicnet_supervisor_pidfile_matches "$_mssp_pid_file" "$_mssp_pid"; then
                return 1
            else
                _mssp_match_rc=$?
            fi
            [ "$_mssp_match_rc" -ne 2 ] || return 2
        fi
    fi
    rm -f "$_mssp_pid_file" 2>/dev/null || return 1
    unset _mssp_pid_file _mssp_pid _mssp_match_rc _mssp_attempt
    return 0
}

magicnet_supervisor_pidfile_matches() (
    _msp_pid_file="$1"
    _msp_pid="$2"
    case "$_msp_pid" in '' | *[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_msp_pid" ] || {
        unset _msp_pid_file _msp_pid
        return 1
    }
    case "$_msp_pid_file" in
    */.state/watchdog/magicnet-kernel.pid)
        _msp_root=${_msp_pid_file%/.state/watchdog/magicnet-kernel.pid}
        _msp_expected="$_msp_root/.state/watchdog/magicnet-kernel.loop.sh"
        _msp_arg1=service
        _msp_arg2=ensure
        ;;
    */.state/fswatch/magicnet-config.pid)
        _msp_root=${_msp_pid_file%/.state/fswatch/magicnet-config.pid}
        _msp_expected="$_msp_root/.state/fswatch/magicnet-config.loop.sh"
        _msp_arg1=config
        _msp_arg2=apply
        ;;
    */.state/watchdog/magicnet-hotspot-route.pid)
        _msp_root=${_msp_pid_file%/.state/watchdog/magicnet-hotspot-route.pid}
        _msp_expected="$_msp_root/.state/watchdog/magicnet-hotspot-route.loop.sh"
        _msp_arg1=
        _msp_arg2=
        ;;
    *)
        unset _msp_pid_file _msp_pid _msp_root _msp_expected _msp_arg1 _msp_arg2
        return 1
        ;;
    esac
    _msp_rc=1
    # Preserve exact argv boundaries without directly streaming an OEM proc
    # pseudo-file into a pipeline. A live unreadable cmdline is indeterminate.
    if _msp_argv=$(magicnet_proc_cmdline_lines "$_msp_pid" /proc); then
        _msp_read_rc=0
    else
        _msp_read_rc=$?
    fi
    [ "$_msp_read_rc" -eq 0 ] || return "$_msp_read_rc"
    if awk -v expected="$_msp_expected" -v cli="$_msp_root/cli" \
        -v arg1="$_msp_arg1" -v arg2="$_msp_arg2" '
            function is_shell(value) {
                return value == "sh" || value == "ash" || value == "dash" ||
                    value == "bash" || value == "ksh" || value == "mksh" ||
                    value ~ /\/(sh|ash|dash|bash|ksh|mksh)$/
            }
            { argv[++count] = $0 }
            END {
                loop = count == 2 && is_shell(argv[1]) && argv[2] == expected
                cli_command = arg1 != "" && arg2 != "" &&
                    ((count == 3 && argv[1] == cli && argv[2] == arg1 && argv[3] == arg2) ||
                    (count == 4 && is_shell(argv[1]) && argv[2] == cli && argv[3] == arg1 && argv[4] == arg2))
                exit (loop || cli_command) ? 0 : 1
            }' <<EOF; then
$_msp_argv
EOF
        _msp_rc=0
    fi
    unset _msp_pid_file _msp_pid _msp_root _msp_expected _msp_arg1 _msp_arg2
    return "$_msp_rc"
)

magicnet_watchdog_stop() {
    _watchdog_stop_rc=0
    magicnet_supervisor_stop_pidfile "${KAM_HOME:-$MODDIR}/.state/watchdog/magicnet-kernel.pid" || _watchdog_stop_rc=$?
    [ "$_watchdog_stop_rc" -ne 2 ] || return 2
    magicnet_supervisor_kill_orphans watchdog || _watchdog_stop_rc=$?
    [ "$_watchdog_stop_rc" -ne 2 ] || return 2
    magicnet_hotspot_watchdog_stop >/dev/null 2>&1 || _watchdog_stop_rc=$?
    return "$_watchdog_stop_rc"
}

magicnet_hotspot_watchdog_name() {
    printf '%s\n' "magicnet-hotspot-route"
}

magicnet_hotspot_watchdog_interval() {
    printf '%s\n' "${MAGICNET_HOTSPOT_WATCH_INTERVAL:-3}"
}

magicnet_hotspot_watchdog_start() {
    if magicnet_module_disabled || ! magicnet_hotspot_proxy_enabled || ! magicnet_kernel_running; then
        magicnet_hotspot_watchdog_stop >/dev/null 2>&1 || true
        return 0
    fi
    import watchdog
    _hotspot_watch_name="$(magicnet_hotspot_watchdog_name)"
    if watchdog status "$_hotspot_watch_name" >/dev/null 2>&1; then
        unset _hotspot_watch_name
        return 0
    else
        _hotspot_watch_status_rc=$?
    fi
    [ "$_hotspot_watch_status_rc" -ne 2 ] || return 2
    # magicnet_start_kernel already performs the synchronous initial
    # reconciliation.  The watcher owns only later interface transitions and
    # must not repeat slow OEM tethering discovery on the start button path.
    _hotspot_watch_interval="$(magicnet_hotspot_watchdog_interval)"
    case "$_hotspot_watch_interval" in
    '' | *[!0-9]* | 0) _hotspot_watch_interval=3 ;;
    esac
    KAM_WATCHDOG_LOG_FILE="${MODDIR}/.log/hotspot-route.log" \
        watchdog start --quiet "$_hotspot_watch_name" "$_hotspot_watch_interval" \
        "\"${MODDIR}/cli\" hotspot reconcile >/dev/null 2>&1"
    _hotspot_watch_rc=$?
    unset _hotspot_watch_name _hotspot_watch_interval
    return "$_hotspot_watch_rc"
}

magicnet_hotspot_watchdog_stop() {
    _hotspot_watch_pid_file="${KAM_HOME:-$MODDIR}/.state/watchdog/$(magicnet_hotspot_watchdog_name).pid"
    magicnet_supervisor_stop_pidfile "$_hotspot_watch_pid_file" || return $?
    magicnet_supervisor_kill_orphans hotspot-watchdog
    _hotspot_watch_stop_rc=$?
    unset _hotspot_watch_pid_file
    return "$_hotspot_watch_stop_rc"
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

magicnet_fswatch_busybox_bin() (
    _mfb_busybox_bin="${KAM_FSWATCH_BUSYBOX_BIN:-}"
    if [ -n "$_mfb_busybox_bin" ] && [ -x "$_mfb_busybox_bin" ] &&
        "$_mfb_busybox_bin" flock --help >/dev/null 2>&1; then
        printf '%s\n' "$_mfb_busybox_bin"
        return 0
    fi

    # Root solutions keep their private BusyBox in different fixed locations.
    # Do not rely on the lifecycle shell exporting those directories in PATH.
    for _mfb_candidate in \
        /data/adb/ap/bin/busybox \
        /data/adb/ksu/bin/busybox \
        /data/adb/magisk/busybox; do
        if [ -x "$_mfb_candidate" ] &&
            "$_mfb_candidate" flock --help >/dev/null 2>&1; then
            printf '%s\n' "$_mfb_candidate"
            return 0
        fi
    done

    _mfb_candidate="$(command -v busybox 2>/dev/null || true)"
    if [ -n "$_mfb_candidate" ] && [ -x "$_mfb_candidate" ] &&
        "$_mfb_candidate" flock --help >/dev/null 2>&1; then
        printf '%s\n' "$_mfb_candidate"
        return 0
    fi
    return 1
)

magicnet_fswatch_command() {
    printf '%s\n' "[ ! -f '$(magicnet_json_escape "$MODDIR")/disable' ] && [ ! -f '$(magicnet_json_escape "$MODDIR")/remove' ] || exit 0; MODDIR='$(magicnet_json_escape "$MODDIR")' '$(magicnet_json_escape "$MODDIR")/cli' config apply >/dev/null 2>&1"
}

magicnet_fswatch_start() {
    if magicnet_module_disabled; then
        magicnet_fswatch_stop >/dev/null 2>&1 || true
        return 0
    fi
    [ "${MAGICNET_FSWATCH_ENABLED:-1}" != "0" ] || return 0
    [ -d "$(magicnet_fswatch_path)" ] || return 0
    [ -f "${MODDIR}/cli" ] || return 0
    import fswatch
    _fswatch_name="$(magicnet_fswatch_name)"
    if fswatch status "$_fswatch_name" >/dev/null 2>&1; then
        unset _fswatch_name _fw_rc
        return 0
    else
        _fw_rc=$?
    fi
    [ "$_fw_rc" -ne 2 ] || return 2
    magicnet_trim_log_file "${MODDIR}/.log/fswatch.log"
    _fswatch_busybox_bin="$(magicnet_fswatch_busybox_bin 2>/dev/null || true)"
    _fswatch_flock_bin="$(command -v flock 2>/dev/null || true)"
    if [ -z "$_fswatch_busybox_bin" ] && [ -n "$_fswatch_flock_bin" ] &&
        ! flock -n -o /dev/null true >/dev/null 2>&1; then
        magicnet_warn "$(i18n MAGICNET_FSWATCH_FLOCK_INCOMPATIBLE | t "$_fswatch_flock_bin")"
        set -- 1
        unset _fswatch_name _fswatch_busybox_bin _fswatch_flock_bin _fw_rc
        return "$1"
    fi
    [ -n "$_fswatch_busybox_bin" ] && KAM_FSWATCH_BUSYBOX_BIN="$_fswatch_busybox_bin"
    KAM_FSWATCH_PRUNE_NAMES="${MAGICNET_FSWATCH_PRUNE_NAMES:-ui zashboard cache.db cache.db-wal cache.db-shm cache.db-journal}" \
        KAM_FSWATCH_LOG_FILE="${MODDIR}/.log/fswatch.log" \
        fswatch start "$_fswatch_name" "$(magicnet_fswatch_path)" "$(magicnet_fswatch_interval)" "$(magicnet_fswatch_command)"
    _fswatch_rc=$?
    if [ "$_fswatch_rc" -ne 0 ]; then
        magicnet_warn "$(i18n "MAGICNET_FSWATCH_START_FAILED" | t "$_fswatch_rc" "${MODDIR}/.log/fswatch.log")"
    fi
    set -- "$_fswatch_rc"
    unset _fswatch_name _fswatch_rc _fswatch_busybox_bin _fswatch_flock_bin _fw_rc
    return "$1"
}

magicnet_fswatch_stop() {
    magicnet_supervisor_stop_pidfile "${KAM_HOME:-$MODDIR}/.state/fswatch/$(magicnet_fswatch_name).pid" || return $?
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
    if [ -n "$_fswatch_pid" ]; then
        if magicnet_supervisor_pidfile_matches "$_fswatch_pid_file" "$_fswatch_pid"; then
            magicnet_supervisor_status_with_orphans "$_fswatch_pid" fswatch
            unset _fswatch_pid_file _fswatch_pid
            return 0
        else
            _fswatch_match_rc=$?
        fi
        [ "$_fswatch_match_rc" -ne 2 ] || return 2
    fi
    # Status is observational. Startup/stop paths own stale pidfile cleanup.
    unset _fswatch_pid_file _fswatch_pid
    magicnet_supervisor_status_with_orphans "" fswatch
}

magicnet_wifi_policy_enabled() {
    _wifi_policy_enabled="$(magicnet_conf_value \
        "${MODDIR}/.config/magicnet/wifi-policy.conf" \
        MAGICNET_WIFI_POLICY_ENABLED 2>/dev/null || true)"
    [ "$_wifi_policy_enabled" = "1" ]
    _wifi_policy_enabled_rc=$?
    unset _wifi_policy_enabled
    return "$_wifi_policy_enabled_rc"
}

magicnet_wifi_policy_pid_file() {
    printf '%s\n' "${MODDIR}/.state/wifi-policy/magicnet-wifi-policy.pid"
}

magicnet_wifi_policy_pid_matches() (
    _wifi_policy_match_pid="$1"
    case "$_wifi_policy_match_pid" in '' | *[!0-9]*) return 1 ;; esac
    [ -d "/proc/${_wifi_policy_match_pid}" ] || return 1
    if _wifi_policy_match_argv=$(magicnet_proc_cmdline_lines "$_wifi_policy_match_pid" /proc); then
        _wifi_policy_match_read_rc=0
    else
        _wifi_policy_match_read_rc=$?
    fi
    [ "$_wifi_policy_match_read_rc" -eq 0 ] || return "$_wifi_policy_match_read_rc"
    awk -v cli="${MODDIR}/cli" -v alt_cli="${MODDIR}/bin/magicnet-cli" '
        { argv[++count] = $0 }
        END {
            direct = count == 3 && (argv[1] == cli || argv[1] == alt_cli) && argv[2] == "wifi" && argv[3] == "watch"
            wrapper = count == 4 && argv[1] ~ /(^|\/)(sh|ash|dash|bash|ksh|mksh)$/ &&
                (argv[2] == cli || argv[2] == alt_cli) && argv[3] == "wifi" && argv[4] == "watch"
            exit (direct || wrapper) ? 0 : 1
        }
    ' <<EOF
$_wifi_policy_match_argv
EOF
)

magicnet_wifi_policy_start() {
    if magicnet_module_disabled || ! magicnet_wifi_policy_enabled; then
        magicnet_wifi_policy_stop >/dev/null 2>&1 || true
        return 0
    fi
    [ -x "${MODDIR}/cli" ] || return 1
    _wifi_policy_pid_file="$(magicnet_wifi_policy_pid_file)"
    _wifi_policy_pid="$(sed -n '1p' "$_wifi_policy_pid_file" 2>/dev/null || true)"
    if magicnet_wifi_policy_pid_matches "$_wifi_policy_pid"; then
        unset _wifi_policy_pid_file _wifi_policy_pid
        return 0
    else
        _wifi_policy_match_rc=$?
    fi
    [ "$_wifi_policy_match_rc" -ne 2 ] || return 2
    if _wifi_policy_orphans=$(magicnet_supervisor_orphan_pids wifi-policy); then
        return 2
    else
        _wifi_policy_orphan_rc=$?
    fi
    [ "$_wifi_policy_orphan_rc" -ne 2 ] || return 2
    rm -f "$_wifi_policy_pid_file" 2>/dev/null || return 1
    mkdir -p "${MODDIR}/.state/wifi-policy" "${MODDIR}/.log" || return 1
    magicnet_trim_log_file "${MODDIR}/.log/wifi-policy.log"
    nohup "${MODDIR}/cli" wifi watch </dev/null >>"${MODDIR}/.log/wifi-policy.log" 2>&1 &
    _wifi_policy_pid=$!
    printf '%s\n' "$_wifi_policy_pid" >"$_wifi_policy_pid_file" || {
        kill "$_wifi_policy_pid" 2>/dev/null || true
        unset _wifi_policy_pid_file _wifi_policy_pid
        return 1
    }

    # A freshly spawned Android process can expose an incomplete /proc
    # cmdline for a short interval.  Do not publish a healthy supervisor (and
    # do not let the next lifecycle pass start a duplicate) until the exact
    # `cli wifi watch` identity is observable.  Keep the wait bounded so a
    # broken binary still fails closed instead of blocking boot indefinitely.
    _wifi_policy_ready_attempts="${MAGICNET_WIFI_POLICY_READY_ATTEMPTS:-20}"
    case "$_wifi_policy_ready_attempts" in
    '' | *[!0-9]*) _wifi_policy_ready_attempts=20 ;;
    esac
    [ "$_wifi_policy_ready_attempts" -gt 40 ] && _wifi_policy_ready_attempts=40
    [ "$_wifi_policy_ready_attempts" -gt 0 ] || _wifi_policy_ready_attempts=1
    _wifi_policy_ready_attempt=0
    _wifi_policy_ready_rc=1
    while [ "$_wifi_policy_ready_attempt" -lt "$_wifi_policy_ready_attempts" ]; do
        if magicnet_wifi_policy_pid_matches "$_wifi_policy_pid"; then
            unset _wifi_policy_pid_file _wifi_policy_pid _wifi_policy_ready_attempts \
                _wifi_policy_ready_attempt _wifi_policy_ready_rc
            return 0
        else
            _wifi_policy_ready_rc=$?
        fi
        _wifi_policy_ready_attempt=$((_wifi_policy_ready_attempt + 1))
        [ "$_wifi_policy_ready_attempt" -lt "$_wifi_policy_ready_attempts" ] && sleep 0.05
    done
    [ "$_wifi_policy_ready_rc" -ne 2 ] || return 2
    kill "$_wifi_policy_pid" 2>/dev/null || true
    rm -f "$_wifi_policy_pid_file" 2>/dev/null || true
    unset _wifi_policy_pid_file _wifi_policy_pid _wifi_policy_ready_attempts \
        _wifi_policy_ready_attempt
    return 1
}

magicnet_wifi_policy_stop() {
    _wifi_policy_pid_file="$(magicnet_wifi_policy_pid_file)"
    _wifi_policy_pid="$(sed -n '1p' "$_wifi_policy_pid_file" 2>/dev/null || true)"
    if magicnet_wifi_policy_pid_matches "$_wifi_policy_pid"; then
        _wifi_policy_match_rc=0
    else
        _wifi_policy_match_rc=$?
    fi
    [ "$_wifi_policy_match_rc" -ne 2 ] || return 2
    if [ "$_wifi_policy_match_rc" -eq 0 ]; then
        kill "$_wifi_policy_pid" 2>/dev/null || true
        sleep 1
        if magicnet_wifi_policy_pid_matches "$_wifi_policy_pid"; then
            return 1
        else
            _wifi_policy_match_rc=$?
        fi
        [ "$_wifi_policy_match_rc" -ne 2 ] || return 2
    fi
    magicnet_supervisor_kill_orphans wifi-policy || return $?
    rm -f "$_wifi_policy_pid_file" 2>/dev/null || return 1
    return 0
}

magicnet_wifi_policy_status() {
    _wifi_policy_pid_file="$(magicnet_wifi_policy_pid_file)"
    [ -f "$_wifi_policy_pid_file" ] || return 1
    _wifi_policy_pid="$(sed -n '1p' "$_wifi_policy_pid_file" 2>/dev/null)"
    if magicnet_wifi_policy_pid_matches "$_wifi_policy_pid"; then
        printf '%s\n' "$_wifi_policy_pid"
        return 0
    else
        _wifi_policy_status_rc=$?
    fi
    [ "$_wifi_policy_status_rc" -ne 2 ] || return 2
    return 1
}

magicnet_subscription_refresh_name() {
    printf '%s\n' "magicnet-subscription-refresh"
}

magicnet_subscription_refresh_state_dir() {
    printf '%s\n' "${KAM_HOME:-$MODDIR}/.state/watchdog"
}

magicnet_subscription_refresh_pid_file() {
    printf '%s/%s.pid\n' "$(magicnet_subscription_refresh_state_dir)" "$(magicnet_subscription_refresh_name)"
}

magicnet_subscription_refresh_owner_file() {
    printf '%s/%s.owner\n' "$(magicnet_subscription_refresh_state_dir)" "$(magicnet_subscription_refresh_name)"
}

magicnet_subscription_refresh_loop_file() {
    printf '%s/%s.loop.sh\n' "$(magicnet_subscription_refresh_state_dir)" "$(magicnet_subscription_refresh_name)"
}

magicnet_subscription_refresh_proc_start() {
    magicnet_proc_start "$1" "${MAGICNET_SUB_REFRESH_PROC_ROOT:-/proc}"
}

magicnet_subscription_refresh_proc_command_matches() {
    _refresh_proc_pid="$1"
    _refresh_proc_root="${MAGICNET_SUB_REFRESH_PROC_ROOT:-/proc}"
    _refresh_proc_expected=$(magicnet_subscription_refresh_loop_file)
    _refresh_proc_pid_dir="${_refresh_proc_root}/${_refresh_proc_pid}"
    _refresh_proc_cmdline="${_refresh_proc_root}/${_refresh_proc_pid}/cmdline"
    [ -r "$_refresh_proc_cmdline" ] || {
        if [ -d "$_refresh_proc_pid_dir" ] || [ -e "$_refresh_proc_cmdline" ]; then
            _refresh_proc_rc=2
        else
            _refresh_proc_rc=1
        fi
        unset _refresh_proc_pid _refresh_proc_root _refresh_proc_expected _refresh_proc_pid_dir
        unset _refresh_proc_cmdline
        return "$_refresh_proc_rc"
    }
    if _refresh_proc_argv=$(magicnet_proc_cmdline_lines "$_refresh_proc_pid" "$_refresh_proc_root"); then
        _refresh_proc_read_rc=0
    else
        _refresh_proc_read_rc=$?
    fi
    if [ "$_refresh_proc_read_rc" -ne 0 ]; then
        if [ -d "$_refresh_proc_pid_dir" ] || [ -e "$_refresh_proc_cmdline" ]; then
            _refresh_proc_rc=2
        else
            _refresh_proc_rc=1
        fi
    elif awk -v expected="$_refresh_proc_expected" '
        function is_shell(value) { return value ~ /(^|\/)(sh|ash|dash|bash|ksh|mksh)$/ }
        { argv[++count] = $0 }
        END { exit (count == 2 && is_shell(argv[1]) && argv[2] == expected) ? 0 : 1 }
    ' <<EOF
$_refresh_proc_argv
EOF
    then
        _refresh_proc_rc=0
    else
        _refresh_proc_rc=1
    fi
    unset _refresh_proc_pid _refresh_proc_root _refresh_proc_expected _refresh_proc_pid_dir
    unset _refresh_proc_cmdline _refresh_proc_argv _refresh_proc_read_rc _refresh_proc_script
    return "$_refresh_proc_rc"
}

magicnet_subscription_refresh_wait_for_identity() {
    _refresh_wait_pid="${1:-}"
    _refresh_wait_attempts="${MAGICNET_SUB_REFRESH_IDENTITY_ATTEMPTS:-20}"
    _refresh_wait_delay="${MAGICNET_SUB_REFRESH_IDENTITY_DELAY:-0.05}"
    case "$_refresh_wait_pid" in
    '' | *[!0-9]*)
        unset _refresh_wait_pid _refresh_wait_attempts _refresh_wait_delay
        return 1
        ;;
    esac
    case "$_refresh_wait_attempts" in '' | *[!0-9]*) _refresh_wait_attempts=20 ;; esac
    case "$_refresh_wait_delay" in '' | *[!0-9.]* | .* | *.*.*) _refresh_wait_delay=0.05 ;; esac
    [ "$_refresh_wait_attempts" -gt 0 ] || _refresh_wait_attempts=1
    while [ "$_refresh_wait_attempts" -gt 0 ]; do
        _refresh_wait_start=$(magicnet_subscription_refresh_proc_start "$_refresh_wait_pid" 2>/dev/null || true)
        if [ -n "$_refresh_wait_start" ]; then
            if magicnet_subscription_refresh_proc_command_matches "$_refresh_wait_pid"; then
                printf '%s\n' "$_refresh_wait_start"
                unset _refresh_wait_pid _refresh_wait_attempts _refresh_wait_delay _refresh_wait_start
                unset _refresh_wait_match_rc
                return 0
            else
                _refresh_wait_match_rc=$?
                # A readable, mismatched command is not a startup race. Only
                # the transient live-but-unreadable proc result is retryable.
                if [ "$_refresh_wait_match_rc" -ne 2 ]; then
                    break
                fi
            fi
        fi
        _refresh_wait_attempts=$((_refresh_wait_attempts - 1))
        [ "$_refresh_wait_attempts" -gt 0 ] || break
        sleep "$_refresh_wait_delay"
    done
    unset _refresh_wait_pid _refresh_wait_attempts _refresh_wait_delay _refresh_wait_start _refresh_wait_match_rc
    return 1
}

magicnet_subscription_refresh_owner_parse() {
    _refresh_owner_record="$1"
    _refresh_owner_pid=${_refresh_owner_record%%:*}
    _refresh_owner_rest=${_refresh_owner_record#*:}
    _refresh_owner_start=${_refresh_owner_rest%%:*}
    _refresh_owner_identity=${_refresh_owner_rest#*:}
    case "$_refresh_owner_pid" in '' | *[!0-9]*) return 1 ;; esac
    case "$_refresh_owner_start" in '' | *[!0-9]*) return 1 ;; esac
    [ "$_refresh_owner_identity" = "subscription-refresh-v1" ]
}

magicnet_subscription_refresh_owner_matches() {
    _refresh_match_pid="$1"
    _refresh_match_start="$2"
    if ! kill -0 "$_refresh_match_pid" 2>/dev/null; then
        [ -d "${MAGICNET_SUB_REFRESH_PROC_ROOT:-/proc}/$_refresh_match_pid" ] && _refresh_match_rc=2 || _refresh_match_rc=1
    elif _refresh_match_actual_start=$(magicnet_subscription_refresh_proc_start "$_refresh_match_pid"); then
        if [ "$_refresh_match_actual_start" != "$_refresh_match_start" ]; then
            _refresh_match_rc=1
        elif magicnet_subscription_refresh_proc_command_matches "$_refresh_match_pid"; then
            _refresh_match_rc=0
        else
            _refresh_match_rc=$?
        fi
    else
        _refresh_match_rc=$?
    fi
    unset _refresh_match_pid _refresh_match_start _refresh_match_actual_start
    return "$_refresh_match_rc"
}

magicnet_subscription_refresh_stop_known() {
    _refresh_known_pid="$1"
    _refresh_known_start="$2"
    magicnet_subscription_refresh_owner_matches "$_refresh_known_pid" "$_refresh_known_start" || return 1
    kill "$_refresh_known_pid" 2>/dev/null || true
    _refresh_known_deadline=$(($(date +%s) + ${MAGICNET_SUB_REFRESH_STOP_TIMEOUT:-3}))
    while magicnet_subscription_refresh_owner_matches "$_refresh_known_pid" "$_refresh_known_start" &&
        [ "$(date +%s)" -lt "$_refresh_known_deadline" ]; do
        sleep 1
    done
    if magicnet_subscription_refresh_owner_matches "$_refresh_known_pid" "$_refresh_known_start"; then
        kill -9 "$_refresh_known_pid" 2>/dev/null || true
    fi
    unset _refresh_known_pid _refresh_known_start _refresh_known_deadline
}

magicnet_subscription_refresh_loop_pids() {
    _refresh_loop_proc_root="${MAGICNET_SUB_REFRESH_PROC_ROOT:-/proc}"
    _refresh_loop_expected=$(magicnet_subscription_refresh_loop_file)
    case "$_refresh_loop_proc_root:$_refresh_loop_expected" in
    /*:/*) ;;
    *)
        unset _refresh_loop_proc_root _refresh_loop_expected
        return 2
        ;;
    esac
    if [ ! -d "$_refresh_loop_proc_root" ] || [ ! -r "$_refresh_loop_proc_root" ] ||
        [ ! -x "$_refresh_loop_proc_root" ]; then
        unset _refresh_loop_proc_root _refresh_loop_expected
        return 2
    fi
    # Production uses one bounded Rust scan: 64 KiB per cmdline, 750 ms total,
    # and 4096 candidates. The count/footer frame rejects partial output.
    if ! type magicnet_proc_script_pids_test_hook >/dev/null 2>&1; then
        _refresh_loop_reader="${MODDIR}/cli"
        [ -x "$_refresh_loop_reader" ] || return 2
        _refresh_loop_frame=$(magicnet_proc_query_temp_create) || return 2
        _refresh_loop_pids=$(magicnet_proc_query_temp_create) || {
            rm -f "$_refresh_loop_frame"
            return 2
        }
        if "$_refresh_loop_reader" __proc-script-pids \
            "$_refresh_loop_proc_root" "$_refresh_loop_expected" \
            >"$_refresh_loop_frame" 2>/dev/null; then
            if magicnet_proc_framed_pids_to_file \
                "$_refresh_loop_frame" "$_refresh_loop_pids"; then
                _refresh_loop_decode_rc=0
            else
                _refresh_loop_decode_rc=$?
            fi
        else
            _refresh_loop_decode_rc=2
        fi
        rm -f "$_refresh_loop_frame"
        case "$_refresh_loop_decode_rc" in
        0)
            while IFS= read -r _refresh_loop_pid || [ -n "$_refresh_loop_pid" ]; do
                printf '%s\n' "$_refresh_loop_pid"
            done <"$_refresh_loop_pids"
            ;;
        1) ;;
        *) _refresh_loop_decode_rc=2 ;;
        esac
        rm -f "$_refresh_loop_pids"
        return "$_refresh_loop_decode_rc"
    fi
    # Test-only regular-file hook; production never enters this fallback.
    # /proc is a live directory: an unrelated process can disappear between
    # the readable snapshot and the batched grep. Retry that narrow race, but
    # keep a hard cap and return 2 when the snapshot never becomes trustworthy.
    _refresh_loop_scan_attempts="${MAGICNET_SUB_REFRESH_SCAN_ATTEMPTS:-3}"
    case "$_refresh_loop_scan_attempts" in
    '' | *[!0-9]*) _refresh_loop_scan_attempts=3 ;;
    esac
    [ "$_refresh_loop_scan_attempts" -gt 0 ] || _refresh_loop_scan_attempts=1
    [ "$_refresh_loop_scan_attempts" -le 5 ] || _refresh_loop_scan_attempts=5
    _refresh_loop_scan_delay="${MAGICNET_SUB_REFRESH_SCAN_DELAY:-0.05}"
    case "$_refresh_loop_scan_delay" in
    '' | *[!0-9.]* | .* | *.*.*) _refresh_loop_scan_delay=0.05 ;;
    esac
    _refresh_loop_scan_attempt=0
    while [ "$_refresh_loop_scan_attempt" -lt "$_refresh_loop_scan_attempts" ]; do
        set --
        _refresh_loop_snapshot_error=0
        _refresh_loop_candidate_count=0
        for _refresh_loop_pid_dir in "$_refresh_loop_proc_root"/[0-9]*; do
            _refresh_loop_pid_name=${_refresh_loop_pid_dir#"$_refresh_loop_proc_root"/}
            case "$_refresh_loop_pid_name" in '' | *[!0-9]*) continue ;; esac
            _refresh_loop_candidate_count=$((_refresh_loop_candidate_count + 1))
            [ "$_refresh_loop_candidate_count" -le 4096 ] || {
                _refresh_loop_snapshot_error=1
                break
            }
            if [ ! -d "$_refresh_loop_pid_dir" ]; then
                [ ! -e "$_refresh_loop_pid_dir" ] || _refresh_loop_snapshot_error=1
                continue
            fi
            _refresh_loop_proc="${_refresh_loop_pid_dir}/cmdline"
            if [ -r "$_refresh_loop_proc" ]; then
                set -- "$@" "$_refresh_loop_proc"
            elif [ -d "$_refresh_loop_pid_dir" ]; then
                _refresh_loop_snapshot_error=1
            fi
        done
        if [ ! -d "$_refresh_loop_proc_root" ] || [ ! -r "$_refresh_loop_proc_root" ] ||
            [ ! -x "$_refresh_loop_proc_root" ]; then
            _refresh_loop_snapshot_error=1
        fi
        if [ "$_refresh_loop_snapshot_error" -eq 0 ] && [ "$#" -eq 0 ]; then
            unset _refresh_loop_proc_root _refresh_loop_expected _refresh_loop_scan_attempt
            unset _refresh_loop_scan_attempts _refresh_loop_scan_delay
            unset _refresh_loop_snapshot_error _refresh_loop_proc _refresh_loop_pid_dir _refresh_loop_pid_name
            return 1
        fi
        if [ "$_refresh_loop_snapshot_error" -eq 0 ]; then
            _refresh_loop_candidates=''
            _refresh_loop_scan_rc=1
            for _refresh_loop_proc in "$@"; do
                _refresh_loop_pid=${_refresh_loop_proc#"$_refresh_loop_proc_root"/}
                _refresh_loop_pid=${_refresh_loop_pid%/cmdline}
                if magicnet_proc_script_pids_test_hook "$_refresh_loop_proc_root" \
                    "$_refresh_loop_expected" "$_refresh_loop_pid"; then
                    _refresh_loop_candidates="${_refresh_loop_candidates}${_refresh_loop_candidates:+
}${_refresh_loop_proc}"
                    _refresh_loop_scan_rc=0
                else
                    _refresh_loop_prefilter_rc=$?
                    if [ "$_refresh_loop_prefilter_rc" -eq 2 ]; then
                        _refresh_loop_scan_rc=2
                        break
                    fi
                fi
            done
            case "$_refresh_loop_scan_rc" in
            0)
                set --
                _refresh_loop_exact_error=0
                for _refresh_loop_proc in $_refresh_loop_candidates; do
                    case "$_refresh_loop_proc" in
                    "$_refresh_loop_proc_root"/[0-9]*/cmdline) ;;
                    *) continue ;;
                    esac
                    _refresh_loop_pid=${_refresh_loop_proc#"$_refresh_loop_proc_root"/}
                    _refresh_loop_pid=${_refresh_loop_pid%/cmdline}
                    case "$_refresh_loop_pid" in '' | *[!0-9]*) continue ;; esac
                    if magicnet_subscription_refresh_proc_command_matches "$_refresh_loop_pid"; then
                        set -- "$@" "$_refresh_loop_pid"
                    else
                        _refresh_loop_match_rc=$?
                        if [ "$_refresh_loop_match_rc" -eq 2 ]; then
                            _refresh_loop_exact_error=1
                            break
                        fi
                    fi
                done
                if [ "$_refresh_loop_exact_error" -eq 0 ]; then
                    [ "$#" -eq 0 ] || printf '%s\n' "$@"
                    unset _refresh_loop_proc_root _refresh_loop_expected _refresh_loop_candidates
                    unset _refresh_loop_scan_rc _refresh_loop_scan_attempt _refresh_loop_snapshot_error
                    unset _refresh_loop_scan_attempts _refresh_loop_scan_delay
                    unset _refresh_loop_proc _refresh_loop_pid _refresh_loop_pid_dir _refresh_loop_pid_name
                    unset _refresh_loop_match_rc _refresh_loop_exact_error
                    return 0
                fi
                ;;
            1)
                unset _refresh_loop_proc_root _refresh_loop_expected _refresh_loop_candidates
                unset _refresh_loop_scan_rc _refresh_loop_scan_attempt _refresh_loop_snapshot_error
                unset _refresh_loop_scan_attempts _refresh_loop_scan_delay
                unset _refresh_loop_proc _refresh_loop_pid_dir _refresh_loop_pid_name
                unset _refresh_loop_pid _refresh_loop_match_rc _refresh_loop_exact_error
                return 1
                ;;
            esac
        fi
        _refresh_loop_scan_attempt=$((_refresh_loop_scan_attempt + 1))
        if [ "$_refresh_loop_scan_attempt" -lt "$_refresh_loop_scan_attempts" ]; then
            sleep "$_refresh_loop_scan_delay"
        fi
    done
    unset _refresh_loop_proc_root _refresh_loop_expected _refresh_loop_candidates
    unset _refresh_loop_scan_rc _refresh_loop_scan_attempt _refresh_loop_snapshot_error
    unset _refresh_loop_scan_attempts _refresh_loop_scan_delay
    unset _refresh_loop_proc _refresh_loop_pid _refresh_loop_pid_dir _refresh_loop_pid_name
    unset _refresh_loop_match_rc _refresh_loop_exact_error
    return 2
}

magicnet_subscription_refresh_owner_state() {
    _refresh_state_owner=$(magicnet_subscription_refresh_owner_file)
    [ -f "$_refresh_state_owner" ] || {
        if _refresh_state_orphans=$(magicnet_subscription_refresh_loop_pids); then
            _refresh_state_scan_rc=0
        else
            _refresh_state_scan_rc=$?
        fi
        if [ "$_refresh_state_scan_rc" -eq 2 ]; then
            printf '%s\n' indeterminate
            unset _refresh_state_owner _refresh_state_orphans _refresh_state_scan_rc
            return 2
        fi
        if [ "$_refresh_state_scan_rc" -eq 0 ] && [ -n "$_refresh_state_orphans" ]; then
            printf '%s\n' orphan
        else
            printf '%s\n' none
        fi
        unset _refresh_state_owner _refresh_state_orphans _refresh_state_scan_rc
        return 1
    }
    _refresh_state_record=$(sed -n '1p' "$_refresh_state_owner" 2>/dev/null)
    if ! magicnet_subscription_refresh_owner_parse "$_refresh_state_record"; then
        printf '%s\n' stale
        _refresh_state_rc=1
    elif magicnet_subscription_refresh_owner_matches "$_refresh_owner_pid" "$_refresh_owner_start"; then
        printf '%s\n' active
        _refresh_state_rc=0
    else
        _refresh_state_rc=$?
        [ "$_refresh_state_rc" -ne 2 ] && printf '%s\n' stale || printf '%s\n' indeterminate
    fi
    unset _refresh_state_owner _refresh_state_record
    unset _refresh_owner_record _refresh_owner_pid _refresh_owner_rest _refresh_owner_start _refresh_owner_identity
    return "$_refresh_state_rc"
}

magicnet_subscription_schedule_interval() {
    _schedule_file=$(magicnet_subscription_schedule_file)
    _schedule_value=$(sed -n '1p' "$_schedule_file" 2>/dev/null)
    case "$_schedule_value" in
    12 | 24 | 48 | 72) printf '%s\n' "$_schedule_value" ;;
    *) printf '%s\n' "off" ;;
    esac
    unset _schedule_file _schedule_value
}

magicnet_subscription_refresh_status() {
    _refresh_status_owner=$(magicnet_subscription_refresh_owner_file)
    _refresh_status_record=$(sed -n '1p' "$_refresh_status_owner" 2>/dev/null)
    magicnet_subscription_refresh_owner_parse "$_refresh_status_record" || return 1
    if magicnet_subscription_refresh_owner_matches "$_refresh_owner_pid" "$_refresh_owner_start"; then
        printf '%s\n' "$_refresh_owner_pid"
        _refresh_status_rc=0
    else
        _refresh_status_rc=$?
    fi
    return "$_refresh_status_rc"
}

magicnet_subscription_refresh_stop() {
    _refresh_stop_owner=$(magicnet_subscription_refresh_owner_file)
    if [ ! -f "$_refresh_stop_owner" ]; then
        if magicnet_subscription_refresh_loop_pids >/dev/null 2>&1; then return 2; fi
        _refresh_stop_scan_rc=$?
        [ "$_refresh_stop_scan_rc" -ne 2 ] || return 2
        return 0
    fi
    _refresh_stop_record=$(sed -n '1p' "$_refresh_stop_owner" 2>/dev/null)
    magicnet_subscription_refresh_owner_parse "$_refresh_stop_record" || return 2
    if magicnet_subscription_refresh_owner_matches "$_refresh_owner_pid" "$_refresh_owner_start"; then
        _refresh_stop_match_rc=0
    else
        _refresh_stop_match_rc=$?
    fi
    [ "$_refresh_stop_match_rc" -ne 2 ] || return 2
    [ "$_refresh_stop_match_rc" -eq 0 ] || return 1
    if [ "$_refresh_stop_match_rc" -eq 0 ]; then
        kill "$_refresh_owner_pid" 2>/dev/null || true
        _refresh_stop_deadline=$(($(date +%s) + ${MAGICNET_SUB_REFRESH_STOP_TIMEOUT:-3}))
        while [ "$_refresh_stop_match_rc" -eq 0 ] && [ "$(date +%s)" -lt "$_refresh_stop_deadline" ]; do
            sleep 1
            if magicnet_subscription_refresh_owner_matches "$_refresh_owner_pid" "$_refresh_owner_start"; then
                _refresh_stop_match_rc=0
            else
                _refresh_stop_match_rc=$?
            fi
            [ "$_refresh_stop_match_rc" -ne 2 ] || return 2
        done
        [ "$_refresh_stop_match_rc" -ne 0 ] || return 1
    fi
    [ "$(sed -n '1p' "$_refresh_stop_owner" 2>/dev/null)" = "$_refresh_stop_record" ] || return 2
    rm -f "$_refresh_stop_owner" 2>/dev/null || return 1
    _refresh_stop_pid_file=$(magicnet_subscription_refresh_pid_file)
    [ "$(sed -n '1p' "$_refresh_stop_pid_file" 2>/dev/null)" != "$_refresh_owner_pid" ] ||
        rm -f "$_refresh_stop_pid_file" 2>/dev/null || return 1
    rm -f "$(magicnet_subscription_refresh_loop_file)" 2>/dev/null || true
    return 0
}

magicnet_subscription_refresh_start() {
    _refresh_hours=$(magicnet_subscription_schedule_interval)
    if [ "$_refresh_hours" = "off" ]; then
        magicnet_subscription_refresh_stop >/dev/null 2>&1 || true
        unset _refresh_hours
        return 0
    fi
    if command -v magicnet_module_disabled >/dev/null 2>&1 && magicnet_module_disabled; then
        magicnet_subscription_refresh_stop >/dev/null 2>&1 || true
        unset _refresh_hours
        return 0
    fi
    [ -x "${MODDIR}/cli" ] || {
        unset _refresh_hours
        return 0
    }
    if _refresh_owner_state=$(magicnet_subscription_refresh_owner_state 2>/dev/null); then
        _refresh_owner_state_rc=0
    else
        _refresh_owner_state_rc=$?
    fi
    if [ "$_refresh_owner_state_rc" -eq 2 ] || [ "$_refresh_owner_state" = indeterminate ]; then
        warn "Subscription refresh ownership is indeterminate; refusing to start a duplicate"
        return 2
    elif [ "$_refresh_owner_state" = active ]; then
        return 0
    elif [ "$_refresh_owner_state" = stale ] || [ "$_refresh_owner_state" = orphan ]; then
        warn "Subscription refresh owner is ${_refresh_owner_state}; refusing to start a duplicate or terminate an unowned loop"
        return 1
    fi

    _refresh_seconds=$((_refresh_hours * 3600))
    _refresh_state_dir=$(magicnet_subscription_refresh_state_dir)
    _refresh_loop_file=$(magicnet_subscription_refresh_loop_file)
    _refresh_pid_file=$(magicnet_subscription_refresh_pid_file)
    _refresh_owner_file=$(magicnet_subscription_refresh_owner_file)
    _refresh_log_file="${MODDIR}/.log/subscription-refresh.log"
    mkdir -p "$_refresh_state_dir" "${_refresh_log_file%/*}" || return 1
    magicnet_trim_log_file "$_refresh_log_file"
    {
        printf '%s\n' '#!/system/bin/sh'
        printf 'MODDIR=%s\n' "'$(printf '%s' "$MODDIR" | sed "s/'/'\\\\''/g")'"
        printf '%s\n' 'export MODDIR'
        printf '%s\n' 'trap "" HUP'
        printf '%s\n' "trap 'test -z \"\${_refresh_child:-}\" || kill \"\$_refresh_child\" 2>/dev/null || true; exit 0' TERM INT"
        printf 'sleep %s &\n' "$_refresh_seconds"
        printf '%s\n' "_refresh_child=\$!; wait \"\$_refresh_child\"; _refresh_child="
        printf '%s\n' "while [ ! -f \"\$MODDIR/disable\" ] && [ ! -f \"\$MODDIR/remove\" ]; do"
        printf '%s\n' "  \"\$MODDIR/cli\" sub update-all"
        printf '  sleep %s &\n' "$_refresh_seconds"
        printf '%s\n' "  _refresh_child=\$!; wait \"\$_refresh_child\"; _refresh_child="
        printf '%s\n' 'done'
    } >"$_refresh_loop_file" || return 1
    chmod 700 "$_refresh_loop_file" 2>/dev/null || true
    nohup sh "$_refresh_loop_file" </dev/null >>"$_refresh_log_file" 2>&1 &
    _refresh_pid=$!
    if ! _refresh_start=$(magicnet_subscription_refresh_wait_for_identity "$_refresh_pid"); then
        kill "$_refresh_pid" 2>/dev/null || true
        unset _refresh_hours _refresh_owner_state _refresh_seconds _refresh_state_dir _refresh_loop_file
        unset _refresh_pid_file _refresh_owner_file _refresh_log_file _refresh_pid _refresh_start
        return 1
    fi
    _refresh_owner_tmp="${_refresh_owner_file}.tmp.$$"
    _refresh_pid_tmp="${_refresh_pid_file}.tmp.$$"
    _refresh_owner_record="${_refresh_pid}:${_refresh_start}:subscription-refresh-v1"
    _refresh_rc=0
    if [ "${MAGICNET_SUB_REFRESH_OWNER_WRITE_FAIL:-0}" = "1" ] ||
        ! printf '%s\n' "$_refresh_owner_record" >"$_refresh_owner_tmp" ||
        ! printf '%s\n' "$_refresh_pid" >"$_refresh_pid_tmp" ||
        ! mv -f "$_refresh_owner_tmp" "$_refresh_owner_file" ||
        ! mv -f "$_refresh_pid_tmp" "$_refresh_pid_file"; then
        _refresh_rc=1
        magicnet_subscription_refresh_stop_known "$_refresh_pid" "$_refresh_start" >/dev/null 2>&1 || true
        [ "$(sed -n '1p' "$_refresh_owner_file" 2>/dev/null)" != "$_refresh_owner_record" ] ||
            rm -f "$_refresh_owner_file" 2>/dev/null || true
        [ "$(sed -n '1p' "$_refresh_pid_file" 2>/dev/null)" != "$_refresh_pid" ] ||
            rm -f "$_refresh_pid_file" 2>/dev/null || true
        rm -f "$_refresh_owner_tmp" "$_refresh_pid_tmp" 2>/dev/null || true
    fi
    unset _refresh_hours _refresh_owner_state _refresh_seconds _refresh_state_dir _refresh_loop_file
    unset _refresh_pid_file _refresh_pid_tmp _refresh_owner_file _refresh_owner_tmp _refresh_owner_record
    unset _refresh_log_file _refresh_pid _refresh_start
    return "$_refresh_rc"
}

magicnet_subscription_schedule_set() {
    _schedule_value="$1"
    case "$_schedule_value" in
    off | 12 | 24 | 48 | 72) ;;
    *)
        error "Schedule must be one of: off, 12, 24, 48, 72"
        unset _schedule_value
        return 1
        ;;
    esac
    _schedule_file=$(magicnet_subscription_schedule_file)
    _schedule_tmp="${_schedule_file}.tmp.$$"
    mkdir -p "${_schedule_file%/*}" || return 1
    if ! printf '%s\n' "$_schedule_value" >"$_schedule_tmp" ||
        ! mv -f "$_schedule_tmp" "$_schedule_file"; then
        rm -f "$_schedule_tmp" 2>/dev/null || true
        unset _schedule_value _schedule_file _schedule_tmp
        return 1
    fi
    if [ "$_schedule_value" = "off" ]; then
        magicnet_subscription_refresh_stop >/dev/null 2>&1 || true
    else
        magicnet_subscription_refresh_stop >/dev/null 2>&1 || true
        magicnet_subscription_refresh_start
    fi
    _schedule_rc=$?
    unset _schedule_value _schedule_file _schedule_tmp
    return "$_schedule_rc"
}

magicnet_subscription_schedule_report() {
    _schedule_hours=$(magicnet_subscription_schedule_interval)
    if [ "$_schedule_hours" = "off" ]; then
        _schedule_enabled=0
    else
        _schedule_enabled=1
    fi
    _schedule_owner=$(magicnet_subscription_refresh_owner_state 2>/dev/null || true)
    if [ "$_schedule_owner" = active ]; then
        _schedule_running=1
    else
        _schedule_running=0
    fi
    printf 'schedule_interval_hours=%s\n' "$_schedule_hours"
    printf 'schedule_enabled=%s\n' "$_schedule_enabled"
    printf 'schedule_running=%s\n' "$_schedule_running"
    printf 'schedule_owner=%s\n' "${_schedule_owner:-none}"
    unset _schedule_hours _schedule_enabled _schedule_running _schedule_owner
}

magicnet_supervisors_start_detached() {
    _mssd_timeout="${MAGICNET_SUPERVISOR_START_TIMEOUT:-15}"
    case "$_mssd_timeout" in '' | *[!0-9]* | 0) _mssd_timeout=15 ;; esac
    [ "$_mssd_timeout" -le 60 ] || _mssd_timeout=60
    _mssd_log="${MODDIR}/.log/supervisors.log"
    mkdir -p "${MODDIR}/.log" || return 1
    magicnet_trim_log_file "$_mssd_log"

    # Maintenance supervisors are not part of core/TUN readiness.  Starting
    # them synchronously made an optional stale fswatch flock hold the manual
    # start button indefinitely.  Detach into a new session and bound the
    # nested CLI so it cannot outlive a broken helper forever.
    if [ -x "${MODDIR}/bin/busybox" ]; then
        MAGICNET_COMMAND_TIMEOUT="$_mssd_timeout" \
            "${MODDIR}/bin/busybox" setsid "${MODDIR}/cli" supervisor start all \
            </dev/null >>"$_mssd_log" 2>&1 &
    elif magicnet_cmd_exists setsid; then
        MAGICNET_COMMAND_TIMEOUT="$_mssd_timeout" \
            setsid "${MODDIR}/cli" supervisor start all \
            </dev/null >>"$_mssd_log" 2>&1 &
    else
        MAGICNET_COMMAND_TIMEOUT="$_mssd_timeout" \
            "${MODDIR}/cli" supervisor start all \
            </dev/null >>"$_mssd_log" 2>&1 &
    fi
    unset _mssd_timeout _mssd_log
    return 0
}

magicnet_supervisors_start() {
    magicnet_detach_pid_from_app_cgroup "$$" ||
        magicnet_warn "Failed to detach the supervisor launcher from the caller cgroup."
    _mss_rc=0
    # Publish the settled generation before fswatch can observe .config.  The
    # optional watcher starts last so a broken lifecycle lock cannot prevent
    # the other maintenance supervisors from becoming ready.
    if magicnet_kernel_running; then
        magicnet_singbox_record_runtime_fingerprint ||
            magicnet_warn "Failed to record the settled sing-box configuration fingerprint."
    fi
    for _mss_start_target in refresh wifi-policy hotspot-watchdog fswatch; do
        case "$_mss_start_target" in
        refresh) magicnet_subscription_refresh_start ;;
        wifi-policy) magicnet_wifi_policy_start ;;
        hotspot-watchdog) magicnet_hotspot_watchdog_start ;;
        fswatch) magicnet_fswatch_start ;;
        esac
        _mss_target_rc=$?
        [ "$_mss_target_rc" -ne 2 ] || _mss_rc=2
        if [ "$_mss_target_rc" -ne 0 ] && [ "$_mss_start_target" != fswatch ] && [ "$_mss_rc" -eq 0 ]; then
            _mss_rc=1
        fi
    done
    return "$_mss_rc"
}

magicnet_supervisors_stop() {
    _mss_stop_rc=0
    magicnet_watchdog_stop || _mss_stop_rc=$?
    magicnet_fswatch_stop || {
        _mss_target_rc=$?
        [ "$_mss_target_rc" -ne 2 ] || _mss_stop_rc=2
        [ "$_mss_stop_rc" -ne 0 ] || _mss_stop_rc=1
    }
    magicnet_wifi_policy_stop || {
        _mss_target_rc=$?
        [ "$_mss_target_rc" -ne 2 ] || _mss_stop_rc=2
        [ "$_mss_stop_rc" -ne 0 ] || _mss_stop_rc=1
    }
    if [ "${MAGICNET_SUB_PRESERVE_REFRESH:-0}" != "1" ]; then
        magicnet_subscription_refresh_stop || {
            _mss_target_rc=$?
            [ "$_mss_target_rc" -ne 2 ] || _mss_stop_rc=2
            [ "$_mss_stop_rc" -ne 0 ] || _mss_stop_rc=1
        }
    fi
    [ "$_mss_stop_rc" -ne 0 ] || magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true
    return "$_mss_stop_rc"
}
