# shellcheck shell=ash
# =============================================================================
# protector - 内部实现（自我禁用/安全相关）
# =============================================================================
#
# Usage:
#   _protector_auto_disable <module_path> [max_attempts] [window_seconds] [grace_seconds] [reason]
#
# Behavior (默认参数):
#  - max_attempts: 3           # 在 window_seconds 时间窗口内记录到达该次数则触发禁用
#  - window_seconds: 600       # 时间窗口（秒），默认 10 分钟
#  - grace_seconds: 30         # 检测启动是否完成的宽限期（秒），默认等待 30 秒
#  - reason: string            # 可选禁用原因文本（会写入 disable 文件）
#
# Implementation notes:
#  - 在 module_path 中维护 `.protector_state`（每行一个 epoch 秒）用于记录失败时间点。
#  - 当检测到在 window 窗口内失败次数 >= max_attempts 时，在 module_path 下创建 `disable`
#    文件并写入禁用信息。
#  - 如果 `disable` 已存在则不进行任何操作（避免重复）。
#  - 该实现尽量使用常见 BusyBox 命令，避免复杂依赖。
# =============================================================================

_protector__log() {
    # Prefer internal pretty-print if present, else fallback to printf
    if command -v _pure_print >/dev/null 2>&1; then
        _pure_print "$1"
    else
        printf '%s\n' "$1"
    fi
}

_protector__now() {
    # Try date +%s, fallback to /proc/uptime integer seconds, fallback to 0
    now="$(date +%s 2>/dev/null || true)"
    case "$now" in
        ''|*[!0-9]*)
            now="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
            ;;
    esac
    printf '%s' "$now"
}

_protector__purge_old_entries() {
    # Args: state_file now window_seconds tmp_file
    state_file="$1"
    now="$2"
    window="$3"
    tmp="$4"

    threshold=$((now - window))
    # create tmp containing only timestamps >= threshold
    # read line by line to avoid awk dependency in some envs
    : > "$tmp"
    if [ -f "$state_file" ]; then
        while IFS= read -r ts; do
            [ -z "$ts" ] && continue
            # ensure ts is numeric
            case "$ts" in
                ''|*[!0-9]*) continue ;;
            esac
            if [ "$ts" -ge "$threshold" ]; then
                printf '%s\n' "$ts" >> "$tmp"
            fi
        done < "$state_file"
    fi
}

# 主函数：检测并在必要时禁用模块
# 返回码：
#   0 = 正常（未触发禁用；可能是引导成功或已被禁用）
#   1 = 参数错误或文件系统错误
#   2 = 已创建 disable（模块已被自动禁用）
_protector_auto_disable() {
    module_path="$1"
    max_attempts="${2:-3}"
    window_seconds="${3:-600}"
    grace_seconds="${4:-30}"
    reason="${5:-boot_loop_detected}"

    if [ -z "$module_path" ]; then
        _protector__log "protector: module path required"
        return 1
    fi

    # normalize path (no trailing slash)
    case "$module_path" in
        */) module_path="${module_path%/}" ;;
    esac

    if [ ! -d "$module_path" ]; then
        _protector__log "protector: module path not found: $module_path"
        return 1
    fi

    disable_file="$module_path/disable"
    state_file="$module_path/.protector_state"
    info_file="$module_path/.protector_disable_info"
    tmp_state="$module_path/.protector_state.tmp.$$"
    tmp_disable="$module_path/disable.tmp.$$"

    # If already disabled, nothing to do
    if [ -f "$disable_file" ]; then
        _protector__log "protector: already disabled: $module_path"
        return 0
    fi

    # Check for getprop availability
    if command -v getprop >/dev/null 2>&1; then
        # Wait up to grace_seconds for boot to complete
        count=0
        while [ "$count" -lt "$grace_seconds" ]; do
            prop="$(getprop sys.boot_completed 2>/dev/null || true)"
            if [ "$prop" = "1" ]; then
                # Boot completed -> purge old entries and exit cleanly
                now="$(_protector__now)"
                _protector__purge_old_entries "$state_file" "$now" "$window_seconds" "$tmp_state"
                # overwrite state file with purged entries (do not append a success marker)
                mv "$tmp_state" "$state_file" 2>/dev/null || :; [ -f "$tmp_state" ] && rm -f "$tmp_state" 2>/dev/null || :
                _protector__log "protector: boot completed for module at $module_path; cleared old entries"
                return 0
            fi
            count=$((count + 1))
            sleep 1
        done
    else
        # No getprop — we cannot reliably detect boot status; be conservative and record a failure
        _protector__log "protector: getprop not available; proceeding to record potential boot failure for $module_path"
    fi

    # At this point, we consider the boot attempt as 'failed' (didn't reach completed within grace)
    now="$(_protector__now)"

    # Purge old and append now
    _protector__purge_old_entries "$state_file" "$now" "$window_seconds" "$tmp_state" || true
    printf '%s\n' "$now" >> "$tmp_state" || {
        _protector__log "protector: failed to write state (tmp) for $module_path"
        rm -f "$tmp_state" 2>/dev/null || :
        return 1
    }

    # Atomically replace state file
    mv "$tmp_state" "$state_file" 2>/dev/null || { rm -f "$tmp_state" 2>/dev/null || :; }

    # Count recent failures
    if [ -f "$state_file" ]; then
        # wc -l can include spaces; trim it
        cnt="$(wc -l < "$state_file" 2>/dev/null || echo 0)"
        cnt="$(printf '%s' "$cnt")"
    else
        cnt=0
    fi

    _protector__log "protector: recorded failure for $module_path at $now (recent failures: $cnt of $max_attempts)"

    # If threshold reached, create disable file and info
    if [ "$cnt" -ge "$max_attempts" ]; then
        # Create disable file with reason and timestamps for debugging
        {
            printf 'disabled_by=protector\n'
            printf 'reason=%s\n' "$reason"
            printf 'timestamp=%s\n' "$now"
            printf 'recent_failures=%s\n' "$cnt"
            printf 'window_seconds=%s\n' "$window_seconds"
            printf 'timestamps:\n'
            [ -f "$state_file" ] && sed -n '1,100p' "$state_file"
        } > "$tmp_disable" || {
            _protector__log "protector: failed to write disable tmp file for $module_path"
            rm -f "$tmp_disable" 2>/dev/null || :
            return 1
        }

        mv "$tmp_disable" "$disable_file" 2>/dev/null || {
            _protector__log "protector: failed to create disable file at $disable_file"
            rm -f "$tmp_disable" 2>/dev/null || :
            return 1
        }

        # Record a human-readable info file too
        {
            printf 'Protector auto-disabled module at: %s\n' "$(date 2>/dev/null || printf '%s' "$now")"
            printf 'reason: %s\n' "$reason"
            printf 'recent_failures: %s\n' "$cnt"
            printf 'window_seconds: %s\n' "$window_seconds"
            printf 'state_file: %s\n' "$state_file"
        } > "$info_file" 2>/dev/null || :

        _protector__log "protector: module at $module_path auto-disabled (created $disable_file)"
        return 2
    fi

    return 0
}

# 额外工具函数
_protector_status() {
    # Args: module_path
    module_path="$1"
    state_file="$module_path/.protector_state"
    if [ ! -d "$module_path" ]; then
        _protector__log "protector: module path not found: $module_path"
        return 1
    fi
    if [ -f "$module_path/disable" ]; then
        _protector__log "protector: DISABLED (disable file exists)"
    else
        _protector__log "protector: ENABLED (no disable file present)"
    fi
    if [ -f "$state_file" ]; then
        _protector__log "protector: recent failures:"
        sed -n '1,200p' "$state_file"
    else
        _protector__log "protector: no recorded failures"
    fi
    return 0
}

# End of _protector.sh
