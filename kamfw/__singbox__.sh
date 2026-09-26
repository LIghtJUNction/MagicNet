# shellcheck shell=ash
#
# singbox helper utilities
#

import rich
import self

# Return 0 with PIDs in the private destination file, 1 for an authoritative
# empty set, or 2 when discovery is indeterminate. MagicNet common.sh loads the
# bounded, count-framed implementation before importing this helper.
singbox_pids_to_file() {
    _singbox_pid_output="$1"
    if type magicnet_singbox_owned_pids_to_file >/dev/null 2>&1; then
        magicnet_singbox_owned_pids_to_file \
            "${MODDIR}/.config/sing-box/config.json" "$_singbox_pid_output"
        return $?
    fi
    # Generic kamfw consumers without MagicNet ownership policy may still use
    # bounded name discovery, but never fall back to an unbounded proc scan.
    if type magicnet_proc_named_pids_to_file >/dev/null 2>&1; then
        magicnet_proc_named_pids_to_file sing-box "$_singbox_pid_output"
        return $?
    fi
    return 2
}

# Compatibility emitter only. Lifecycle paths use singbox_pids_to_file so the
# tri-state return code cannot be erased by command substitution.
singbox_pids() {
    type magicnet_proc_query_temp_create >/dev/null 2>&1 || return 2
    _singbox_pid_file=$(magicnet_proc_query_temp_create) || return 2
    singbox_pids_to_file "$_singbox_pid_file"
    _singbox_pid_rc=$?
    if [ "$_singbox_pid_rc" -eq 0 ]; then
        while IFS= read -r _singbox_pid; do
            printf '%s\n' "$_singbox_pid"
        done <"$_singbox_pid_file"
    fi
    rm -f "$_singbox_pid_file"
    unset _singbox_pid_file _singbox_pid
    return "$_singbox_pid_rc"
}

singbox_set_status_description() {
    # Preserve an actionable startup/update error; a stopped process is only
    # the symptom and should not erase the cause shown by the module manager.
    if [ "$1" != "running" ] && [ -s "${MODDIR}/.state/startup-error" ]; then
        return 0
    fi
    if [ "$1" = "running" ]; then
        _singbox_description="$(i18n 'SINGBOX_STATUS'): $(i18n 'RUNNING')"
    else
        _singbox_description="$(i18n 'SINGBOX_STATUS'): $(i18n 'NOT_RUNNING')"
    fi
    _singbox_current_description="$(config get override.description 2>/dev/null || true)"
    if [ "$_singbox_current_description" != "$_singbox_description" ]; then
        config set override.description "$_singbox_description"
    fi
    unset _singbox_description _singbox_current_description
}

is_singbox_running() {
    # Return 0=running, 1=definitely stopped, 2=indeterminate.
    _singbox_running_file=$(magicnet_proc_query_temp_create) || return 2
    if singbox_pids_to_file "$_singbox_running_file"; then
        _singbox_running_rc=0
    else
        _singbox_running_rc=$?
    fi
    rm -f "$_singbox_running_file"
    case "$_singbox_running_rc" in
    0) singbox_set_status_description running ;;
    1) singbox_set_status_description stopped ;;
    *) return 2 ;;
    esac
    return "$_singbox_running_rc"
}

singbox_wait_ready() {
    _tries="${MAGICNET_SINGBOX_READY_TRIES:-5}"
    _delay="${MAGICNET_SINGBOX_READY_DELAY:-1}"
    _try=0
    while [ "$_try" -lt "$_tries" ]; do
        if is_singbox_running >/dev/null 2>&1; then
            if command -v curl >/dev/null 2>&1 &&
                curl -sS --max-time 1 http://127.0.0.1:9090/version >/dev/null 2>&1; then
                unset _tries _delay _try
                return 0
            fi
            if [ "$_try" -gt 0 ]; then
                unset _tries _delay _try
                return 0
            fi
        fi
        _try=$((_try + 1))
        sleep "$_delay"
    done
    unset _tries _delay _try
    return 1
}

singbox_tun() {
    mkdir -p /dev/net
    info "创建/dev/net/目录"

    if [ ! -e /dev/net/tun ]; then
        ln -s /dev/tun /dev/net/tun
        info "创建/dev/net/tun符号链接"
    fi

    if [ ! -c "/dev/net/tun" ]; then
        error "无法创建 /dev/net/tun，可能的原因："
        warn "系统不支持 TUN/TAP 驱动或内核不兼容"
        return 1
    fi
    info "/dev/net/tun 为字符设备，检查通过"
}

singbox_managed_inbound_type() {
    _singbox_inbound_config="$1"
    _singbox_inbound_jq="${MODDIR}/bin/jq"
    [ -f "$_singbox_inbound_config" ] && [ -x "$_singbox_inbound_jq" ] || {
        error "$(i18n 'SINGBOX_INBOUND_CHECK_UNAVAILABLE')"
        unset _singbox_inbound_config _singbox_inbound_jq
        return 1
    }
    _singbox_inbound_type="$("$_singbox_inbound_jq" -r '
        [.inbounds[]? | select((.type // "") == "tun" or (.type // "") == "ebpf") | .type]
        | if length == 0 then "none" elif length == 1 then .[0] else "" end
    ' "$_singbox_inbound_config" 2>/dev/null)" || {
        unset _singbox_inbound_config _singbox_inbound_jq _singbox_inbound_type
        return 1
    }
    case "$_singbox_inbound_type" in
    none | tun | ebpf)
        printf '%s\n' "$_singbox_inbound_type"
        unset _singbox_inbound_config _singbox_inbound_jq _singbox_inbound_type
        return 0
        ;;
    *)
        error "$(i18n 'SINGBOX_MANAGED_INBOUND_INVALID')"
        unset _singbox_inbound_config _singbox_inbound_jq _singbox_inbound_type
        return 1
        ;;
    esac
}

singbox_prepare_dataplane() {
    _singbox_dataplane_type="$(singbox_managed_inbound_type "$1")" || return 1
    case "$_singbox_dataplane_type" in
    tun) singbox_tun ;;
    none | ebpf) : ;;
    *) unset _singbox_dataplane_type; return 1 ;;
    esac
    _singbox_dataplane_rc=$?
    unset _singbox_dataplane_type
    return "$_singbox_dataplane_rc"
}

singbox_prepare_route_config() {
    _singbox_route_config="$1"
    [ -f "$_singbox_route_config" ] || return 0

    _jq="${MODDIR}/bin/jq"
    if [ ! -x "$_jq" ]; then
        _jq="$(command -v jq 2>/dev/null || true)"
    fi
    if [ -n "$_jq" ]; then
        _tmp="${_singbox_route_config}.route.new"
        if "$_jq" '
            .route = ((.route // {})
                | .auto_detect_interface = false
                | del(.default_interface))
            | .outbounds = ((.outbounds // []) | map(
                if (.type // "") == "direct" then
                    del(.bind_interface)
                elif (.type // "") == "selector" then
                    .interrupt_exist_connections = true
                else
                    .
                end
            ))
        ' "$_singbox_route_config" >"$_tmp"; then
            if mv -f "$_tmp" "$_singbox_route_config"; then
                unset _singbox_route_config _jq _tmp
                return 0
            fi
        fi
        rm -f "$_tmp"
    fi

    # Last-resort text fallback for minimal Android environments without jq.
    # Without jq, keep routing delegated to Android rather than retaining a stale interface.
    _tmp="${_singbox_route_config}.route.new"
    _route_rc=1
    if awk '
        function flush_previous() {
            if (have_previous) {
                print previous
            }
        }
        function count_structural_brace(text, target,    i, char, escaped, quoted, count) {
            for (i = 1; i <= length(text); i++) {
                char = substr(text, i, 1)
                if (quoted) {
                    if (escaped) {
                        escaped = 0
                    } else if (char == "\\") {
                        escaped = 1
                    } else if (char == "\"") {
                        quoted = 0
                    }
                } else if (char == "\"") {
                    quoted = 1
                } else if (char == target) {
                    count++
                }
            }
            return count
        }
        {
            current = $0
            open_count = count_structural_brace(current, "{")
            for (i = 1; i <= open_count; i++) {
                object_depth++
                object_type[object_depth] = ""
            }
            if (current ~ /^[[:space:]]*"type"[[:space:]]*:/) {
                current_type = current
                sub(/^.*"type"[[:space:]]*:[[:space:]]*"/, "", current_type)
                sub(/".*/, "", current_type)
                object_type[object_depth] = current_type
            }
            if (current ~ /^[[:space:]]*"auto_detect_interface"[[:space:]]*:/) {
                sub(/:[[:space:]]*(true|false)/, ": false", current)
            }
            if (object_type[object_depth] == "selector" &&
                current ~ /^[[:space:]]*"interrupt_exist_connections"[[:space:]]*:/) {
                sub(/:[[:space:]]*(true|false)/, ": true", current)
            }
            if (current ~ /^[[:space:]]*"(default_interface|bind_interface)"[[:space:]]*:/) {
                if (current !~ /,[[:space:]]*$/ && have_previous) {
                    sub(/,[[:space:]]*$/, "", previous)
                }
                next
            }
            flush_previous()
            previous = current
            have_previous = 1
            close_count = count_structural_brace(current, "}")
            for (i = 1; i <= close_count; i++) {
                delete object_type[object_depth]
                object_depth--
            }
        }
        END {
            flush_previous()
        }
    ' "$_singbox_route_config" >"$_tmp" &&
        mv -f "$_tmp" "$_singbox_route_config"; then
        _route_rc=0
    else
        rm -f "$_tmp"
    fi
    unset _singbox_route_config _jq _tmp
    return "$_route_rc"
}

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
        _started_pid=$!

        if singbox_wait_ready; then
            success "sing-box started successfully."
            unset _config _log _workdir _attempt _started_pid
            return 0
        fi

        warn "sing-box process did not stay running; stopping partial start."
        # This PID came directly from the launch above, so cleanup does not
        # depend on a second discovery call that may itself be indeterminate.
        kill "$_started_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$_started_pid" 2>/dev/null || true
        singbox_stop >/dev/null 2>&1 || true
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

singbox_signal_pids_file() {
    _singbox_signal_file="$1"
    _singbox_signal="$2"
    while IFS= read -r _singbox_signal_pid; do
        case "$_singbox_signal_pid" in '' | *[!0-9]* | 0) return 1 ;; esac
        if [ "$_singbox_signal" = 9 ]; then
            kill -9 "$_singbox_signal_pid" 2>/dev/null || true
        else
            kill "$_singbox_signal_pid" 2>/dev/null || true
        fi
    done <"$_singbox_signal_file"
}

singbox_stop() {
    _singbox_stop_file=$(magicnet_proc_query_temp_create) || return 2
    if singbox_pids_to_file "$_singbox_stop_file"; then
        _singbox_stop_state=0
    else
        _singbox_stop_state=$?
    fi
    case "$_singbox_stop_state" in
    1)
        rm -f "$_singbox_stop_file"
        success "sing-box stopped."
        return 0
        ;;
    0) ;;
    *)
        rm -f "$_singbox_stop_file"
        error "sing-box process discovery is indeterminate; stop aborted."
        return 2
        ;;
    esac

    info "Stopping sing-box..."
    singbox_signal_pids_file "$_singbox_stop_file" 15 || true
    sleep 1
    if singbox_pids_to_file "$_singbox_stop_file"; then
        _singbox_stop_state=0
    else
        _singbox_stop_state=$?
    fi
    if [ "$_singbox_stop_state" -eq 0 ]; then
        singbox_signal_pids_file "$_singbox_stop_file" 9 || true
        sleep 1
        if singbox_pids_to_file "$_singbox_stop_file"; then
            _singbox_stop_state=0
        else
            _singbox_stop_state=$?
        fi
    fi
    rm -f "$_singbox_stop_file"
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
}

toggle_singbox() {
    if is_singbox_running; then
        _singbox_toggle_state=0
    else
        _singbox_toggle_state=$?
    fi
    case "$_singbox_toggle_state" in
    0)
        info "Stop and check"
        singbox_stop
        ;;
    1)
        info "Start and check"
        singbox_start
        ;;
    *)
        error "sing-box process discovery is indeterminate; toggle aborted."
        return 2
        ;;
    esac
}

set_i18n "TOGGLE_SINGBOX" \
    "zh" "切换 sing-box 状态" \
    "en" "Toggle sing-box status" \
    "ja" "sing-box の状態を切り替え" \
    "ko" "sing-box 상태 전환"

set_i18n "SINGBOX_STATUS" \
    "zh" "sing-box状态" \
    "en" "sing-box status" \
    "ja" "sing-box の状態" \
    "ko" "sing-box 상태"

set_i18n "RUNNING" \
    "zh" "正在运行" \
    "en" "Running" \
    "ja" "実行中" \
    "ko" "실행 중"

set_i18n "NOT_RUNNING" \
    "zh" "未运行" \
    "en" "Not running" \
    "ja" "実行していません" \
    "ko" "実行 중 아님"

set_i18n "PROCESS_STATE_UNKNOWN" \
    "zh" "进程状态未知" \
    "en" "Process state unknown" \
    "ja" "プロセス状態不明" \
    "ko" "프로세스 상태 알 수 없음"

set_i18n "SINGBOX_INBOUND_CHECK_UNAVAILABLE" \
    "zh" "无法读取 sing-box 受管透明入站类型" \
    "en" "Unable to read the managed sing-box transparent inbound type" \
    "ja" "sing-box の管理対象透過インバウンド種別を読み取れません" \
    "ko" "관리되는 sing-box 투명 인바운드 유형을 읽을 수 없습니다"

set_i18n "SINGBOX_MANAGED_INBOUND_INVALID" \
    "zh" "sing-box 配置不能同时包含多个 tun 或 ebpf 透明入站" \
    "en" "The sing-box config cannot contain multiple tun or ebpf transparent inbounds" \
    "ja" "sing-box 設定に複数の tun または ebpf 透過インバウンドを含めることはできません" \
    "ko" "sing-box 구성에는 여러 tun 또는 ebpf 투명 인바운드를 포함할 수 없습니다"

ask_toggle_singbox() {
    # Ask the user to toggle sing-box.
    # Question key:    TOGGLE_SINGBOX
    if is_singbox_running; then
        _singbox_question_state=0
    else
        _singbox_question_state=$?
    fi
    case "$_singbox_question_state" in
    0) _singbox_state="$(i18n 'RUNNING')" ;;
    1) _singbox_state="$(i18n 'NOT_RUNNING')" ;;
    *) _singbox_state="$(i18n 'PROCESS_STATE_UNKNOWN')" ;;
    esac
    panel "$(i18n 'SINGBOX_STATUS')"
    panel_row "$(i18n 'SINGBOX_STATUS')" "$_singbox_state"
    panel_end
    ask "TOGGLE_SINGBOX" \
        "CONFIRM" \
        'toggle_singbox' \
        "REFUSE" \
        'exit 0' \
        0
    unset _singbox_state
}
