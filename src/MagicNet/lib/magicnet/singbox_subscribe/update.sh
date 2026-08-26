# shellcheck shell=ash

type magicnet_source_primitives >/dev/null 2>&1 || {
    if [ -n "${BASH_VERSION:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
        # BASH_SOURCE is guarded by the Bash-only branch above.
        # shellcheck disable=SC3054
        . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/primitives.sh"
    else
        . "${MODDIR}/lib/magicnet/primitives.sh"
    fi
}
magicnet_source_primitives

magicnet_reapply_post_start_policy() {
    if command -v magicnet_after_kernel_start_unlocked >/dev/null 2>&1; then
        magicnet_after_kernel_start_unlocked
    else
        magicnet_enable_dns_capture && magicnet_enable_dns_leak_guard
    fi
}

# Read-only lock probe for status/reporting paths.
magicnet_singbox_update_lock_live() (
    _lock="${MODDIR}/.state/sing-box/subscription-update.lock"
    [ -d "$_lock" ] || return 1
    _owner=$(sed -n '1p' "$_lock/owner" 2>/dev/null || true)
    if [ -z "$_owner" ]; then
        _grace="${MAGICNET_SUB_UPDATE_LOCK_INIT_GRACE:-5}"
        case "$_grace" in '' | *[!0-9]*) _grace=5 ;; esac
        _mtime=$(stat -c '%Y' "$_lock" 2>/dev/null || true)
        _now=$(date +%s 2>/dev/null || true)
        case "$_mtime:$_now" in *[!0-9:]* | :* | *:) return 0 ;; esac
        if [ "$_now" -lt "$_mtime" ] || [ "$((_now - _mtime))" -lt "$_grace" ]; then
            return 0
        fi
        return 1
    fi
    _pid=${_owner%%:*}
    _rest=${_owner#*:}
    _start=${_rest%%:*}
    case "$_pid:$_start" in *[!0-9:]* | :* | *:) return 1 ;; esac
    _live_start=$(magicnet_singbox_proc_start "/proc/${_pid}/stat")
    kill -0 "$_pid" 2>/dev/null && [ "$_start" = "$_live_start" ]
)

magicnet_singbox_update_lock_active() (
    _lock="${MODDIR}/.state/sing-box/subscription-update.lock"
    [ -d "$_lock" ] || return 1
    _owner=$(sed -n '1p' "$_lock/owner" 2>/dev/null || true)
    magicnet_singbox_update_lock_live && return 0
    [ "$(sed -n '1p' "$_lock/owner" 2>/dev/null || true)" = "$_owner" ] || return 1
    [ -z "$_owner" ] || rm -f "$_lock/owner" 2>/dev/null || true
    rmdir "$_lock" 2>/dev/null || true
    return 1
)

magicnet_singbox_update_lock_acquire() {
    _update_lock="${MODDIR}/.state/sing-box/subscription-update.lock"
    mkdir -p "${_update_lock%/*}"
    if ! mkdir "$_update_lock" 2>/dev/null; then
        if magicnet_singbox_update_lock_active; then
            error "Subscription update already running"
            return 1
        fi
        mkdir "$_update_lock" 2>/dev/null || return 1
    fi
    _update_start=$(magicnet_proc_start "$$")
    _update_nonce=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s)
    _update_token="$$:${_update_start:-unknown}:${_update_nonce}"
    if ! printf '%s\n' "$_update_token" >"$_update_lock/owner"; then
        # Do not leave an empty lock directory behind when publishing the
        # owner marker fails.  Such a directory is indistinguishable from a
        # crashed updater and would force every later update through stale
        # reclamation/timeouts.
        rm -f "$_update_lock/owner" 2>/dev/null || true
        rmdir "$_update_lock" 2>/dev/null || true
        return 1
    fi
}

magicnet_singbox_update_lock_release() {
    _update_lock="${MODDIR}/.state/sing-box/subscription-update.lock"
    _update_owner=$(sed -n '1p' "$_update_lock/owner" 2>/dev/null)
    if [ -n "${_update_token:-}" ] && [ "$_update_owner" = "$_update_token" ]; then
        rm -f "$_update_lock/owner" 2>/dev/null || true
        rmdir "$_update_lock" 2>/dev/null || true
    fi
}

magicnet_singbox_status_value() {
    _status_key="$1"
    _status_default="$2"
    _status_file=$(magicnet_singbox_subscription_status_file)
    _status_value=$(sed -n "s/^${_status_key}=//p" "$_status_file" 2>/dev/null | tail -n 1)
    printf '%s\n' "${_status_value:-$_status_default}"
    unset _status_key _status_default _status_file _status_value
}

magicnet_singbox_status_write() {
    _status_phase="$1"
    _status_result="$2"
    _status_attempt="$3"
    _status_success="$4"
    _status_configured="$5"
    _status_sources="$6"
    _status_imported="$7"
    _status_skipped="$8"
    _status_generation="$9"
    shift 9
    _status_reason="$1"
    _status_file=$(magicnet_singbox_subscription_status_file)
    _status_tmp="${_status_file}.tmp.$$"
    _status_phase=$(printf '%s' "$_status_phase" | tr -cd 'A-Za-z0-9._-' | cut -c1-32)
    _status_result=$(printf '%s' "$_status_result" | tr -cd 'A-Za-z0-9._-' | cut -c1-32)
    _status_generation=$(printf '%s' "$_status_generation" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
    _status_reason=$(printf '%s' "$_status_reason" | tr -cd 'A-Za-z0-9._-' | cut -c1-80)
    _status_source_mode="${MAGICNET_SUB_SOURCE_MODE:-$(magicnet_singbox_status_value source_mode unknown)}"
    _status_native_parser="${MAGICNET_SUB_NATIVE_PARSER:-$(magicnet_singbox_status_value native_parser unknown)}"
    _status_native_count="${MAGICNET_SUB_NATIVE_NODE_COUNT:-$(magicnet_singbox_status_value native_node_count 0)}"
    _status_converter_enabled="${MAGICNET_SUB_CONVERTER_ENABLED:-$(magicnet_singbox_status_value converter_enabled unknown)}"
    _status_converter_available="${MAGICNET_SUB_CONVERTER_AVAILABLE:-$(magicnet_singbox_status_value converter_available unknown)}"
    _status_converter_attempted="${MAGICNET_SUB_CONVERTER_ATTEMPTED:-$(magicnet_singbox_status_value converter_attempted 0)}"
    _status_converter_format="${MAGICNET_SUB_CONVERTER_FORMAT:-$(magicnet_singbox_status_value converter_format none)}"
    _status_converter_result="${MAGICNET_SUB_CONVERTER_RESULT:-$(magicnet_singbox_status_value converter_result unknown)}"
    _status_source_mode=$(printf '%s' "$_status_source_mode" | tr -cd 'A-Za-z0-9._-' | cut -c1-16)
    _status_native_parser=$(printf '%s' "$_status_native_parser" | tr -cd 'A-Za-z0-9._-' | cut -c1-32)
    _status_native_count=$(printf '%s' "$_status_native_count" | tr -cd '0-9' | cut -c1-10)
    _status_converter_enabled=$(printf '%s' "$_status_converter_enabled" | tr -cd 'A-Za-z0-9._-' | cut -c1-16)
    _status_converter_available=$(printf '%s' "$_status_converter_available" | tr -cd 'A-Za-z0-9._-' | cut -c1-16)
    _status_converter_attempted=$(printf '%s' "$_status_converter_attempted" | tr -cd 'A-Za-z0-9._-' | cut -c1-16)
    _status_converter_format=$(printf '%s' "$_status_converter_format" | tr -cd 'A-Za-z0-9._-' | cut -c1-32)
    _status_converter_result=$(printf '%s' "$_status_converter_result" | tr -cd 'A-Za-z0-9._-' | cut -c1-32)
    mkdir -p "${_status_file%/*}" || return 1
    {
        printf 'phase=%s\n' "${_status_phase:-unknown}"
        printf 'result=%s\n' "${_status_result:-unknown}"
        printf 'attempt_epoch=%s\n' "${_status_attempt:-0}"
        printf 'success_epoch=%s\n' "${_status_success:-0}"
        printf 'configured_count=%s\n' "${_status_configured:-0}"
        printf 'source_count=%s\n' "${_status_sources:-0}"
        printf 'imported_count=%s\n' "${_status_imported:-0}"
        printf 'skipped_count=%s\n' "${_status_skipped:-0}"
        printf 'generation_id=%s\n' "${_status_generation:-none}"
        printf 'reason=%s\n' "${_status_reason:-none}"
        printf 'source_mode=%s\n' "${_status_source_mode:-unknown}"
        printf 'native_parser=%s\n' "${_status_native_parser:-unknown}"
        printf 'native_node_count=%s\n' "${_status_native_count:-0}"
        printf 'converter_enabled=%s\n' "${_status_converter_enabled:-unknown}"
        printf 'converter_available=%s\n' "${_status_converter_available:-unknown}"
        printf 'converter_attempted=%s\n' "${_status_converter_attempted:-0}"
        printf 'converter_format=%s\n' "${_status_converter_format:-none}"
        printf 'converter_result=%s\n' "${_status_converter_result:-unknown}"
    } >"$_status_tmp" && mv -f "$_status_tmp" "$_status_file"
    _status_rc=$?
    [ "$_status_rc" -eq 0 ] || rm -f "$_status_tmp" 2>/dev/null || true
    unset _status_phase _status_result _status_attempt _status_success _status_configured
    unset _status_sources _status_imported _status_skipped _status_generation _status_reason
    unset _status_source_mode _status_native_parser _status_native_count
    unset _status_converter_enabled _status_converter_available _status_converter_attempted
    unset _status_converter_format _status_converter_result
    unset _status_file _status_tmp
    return "$_status_rc"
}

magicnet_singbox_status_mark_interrupted() {
    [ "$(magicnet_singbox_status_value result never)" = "running" ] || return 0
    magicnet_singbox_status_write \
        "$(magicnet_singbox_status_value phase unknown)" interrupted \
        "$(magicnet_singbox_status_value attempt_epoch 0)" \
        "$(magicnet_singbox_status_value success_epoch 0)" \
        "$(magicnet_singbox_status_value configured_count 0)" \
        "$(magicnet_singbox_status_value source_count 0)" \
        "$(magicnet_singbox_status_value imported_count 0)" \
        "$(magicnet_singbox_status_value skipped_count 0)" \
        "$(magicnet_singbox_status_value generation_id none)" process_interrupted
}

magicnet_singbox_status_reconcile() {
    [ "$(magicnet_singbox_status_value result never)" = "running" ] || return 0
    magicnet_singbox_update_lock_active && return 0
    magicnet_singbox_status_mark_interrupted
}

magicnet_singbox_prune_subscription_cache() {
    _prune_cache_map="$1"
    _prune_cache_dir=$(magicnet_singbox_subscription_cache_dir)
    [ -d "$_prune_cache_dir" ] || {
        unset _prune_cache_map _prune_cache_dir
        return 0
    }
    _prune_expected="${_prune_cache_dir}/.active-fingerprints.$$"
    : >"$_prune_expected" || return 1
    if [ -f "$_prune_cache_map" ]; then
        while IFS='|' read -r _prune_name _prune_file _prune_identity _prune_fingerprint _prune_extra; do
            [ -z "$_prune_extra" ] || continue
            printf '%s' "$_prune_fingerprint" | grep -Eq '^[0-9a-f]{64}$' || continue
            printf '%s\n' "$_prune_fingerprint" >>"$_prune_expected"
        done <"$_prune_cache_map"
    fi
    for _prune_file in "$_prune_cache_dir"/*.yaml; do
        [ -f "$_prune_file" ] || continue
        _prune_name=${_prune_file##*/}
        _prune_fingerprint=${_prune_name%.yaml}
        printf '%s' "$_prune_fingerprint" | grep -Eq '^[0-9a-f]{64}$' || continue
        grep -F -x "$_prune_fingerprint" "$_prune_expected" >/dev/null 2>&1 ||
            rm -f "$_prune_file" "${_prune_file}.identity" 2>/dev/null || true
    done
    for _prune_identity in "$_prune_cache_dir"/*.yaml.identity; do
        [ -f "$_prune_identity" ] || continue
        _prune_file=${_prune_identity%.identity}
        [ -f "$_prune_file" ] || rm -f "$_prune_identity" 2>/dev/null || true
    done
    rm -f "$_prune_expected" 2>/dev/null || true
    unset _prune_cache_map _prune_cache_dir _prune_expected _prune_name _prune_file
    unset _prune_identity _prune_fingerprint _prune_extra
}

magicnet_singbox_transaction_dir() {
    printf '%s\n' "${MODDIR}/.state/sing-box/subscription-transaction"
}

magicnet_singbox_transaction_reconcile() {
    _tx_dir=$(magicnet_singbox_transaction_dir)
    [ -d "$_tx_dir" ] || {
        unset _tx_dir
        return 0
    }

    _tx_active_config="${MODDIR}/.config/sing-box/config.json"
    _tx_active_work="${MODDIR}/.state/sing-box/subscription-work"
    _tx_active_url="${MODDIR}/.config/sing-box/subscription.url"
    _tx_active_local="${MODDIR}/.config/sing-box/subscription.local"
    _tx_generation=$(sed -n '1p' "$_tx_dir/generation-id" 2>/dev/null || true)
    _tx_restart_required=0
    if [ -f "$_tx_dir/was-running" ]; then
        _tx_restart_required=1
        # An activation can be interrupted immediately after an idempotent
        # config rename.  If the durable backup and active config are already
        # byte-identical and that config still owns a live core, restoring
        # metadata does not require a disruptive stop/start cycle.
        if [ -f "$_tx_dir/had-config" ] && [ -f "$_tx_dir/old-config" ] &&
            [ -f "$_tx_active_config" ] && command -v cmp >/dev/null 2>&1 &&
            cmp -s "$_tx_dir/old-config" "$_tx_active_config" &&
            magicnet_singbox_owned_ready "$_tx_active_config" &&
            command -v magicnet_singbox_runtime_fingerprint_matches >/dev/null 2>&1 &&
            magicnet_singbox_runtime_fingerprint_matches; then
            _tx_restart_required=0
        fi
    fi

    mkdir -p "${_tx_active_config%/*}" "${_tx_active_work%/*}" || return 1
    if [ -f "$_tx_dir/had-config" ]; then
        [ -f "$_tx_dir/old-config" ] || return 1
        _tx_tmp="${_tx_active_config}.reconcile.$$"
        if ! (
            umask 077
            cp -f "$_tx_dir/old-config" "$_tx_tmp"
        ) ||
            ! mv -f "$_tx_tmp" "$_tx_active_config" ||
            ! chmod 600 "$_tx_active_config"; then
            rm -f "$_tx_tmp" 2>/dev/null || true
            return 1
        fi
    else
        rm -f "$_tx_active_config" 2>/dev/null || return 1
    fi

    if [ -f "$_tx_dir/had-work" ]; then
        [ -d "$_tx_dir/old-work" ] || return 1
        _tx_work_tmp="${_tx_active_work}.reconcile.$$"
        _tx_work_backup="${_tx_active_work}.reconcile-backup.$$"
        rm -rf "$_tx_work_tmp" 2>/dev/null || true
        rm -rf "$_tx_work_backup" 2>/dev/null || true
        cp -a "$_tx_dir/old-work" "$_tx_work_tmp" || return 1
        if [ -e "$_tx_active_work" ]; then
            mv "$_tx_active_work" "$_tx_work_backup" || {
                rm -rf "$_tx_work_tmp" 2>/dev/null || true
                return 1
            }
        fi
        if ! mv "$_tx_work_tmp" "$_tx_active_work"; then
            # Keep the current work tree available when the replacement is
            # interrupted.  The journal remains in place for a later retry.
            if [ -e "$_tx_work_backup" ]; then
                mv "$_tx_work_backup" "$_tx_active_work" 2>/dev/null || true
            fi
            rm -rf "$_tx_work_tmp" 2>/dev/null || true
            return 1
        fi
        rm -rf "$_tx_work_backup" 2>/dev/null || true
    else
        rm -rf "$_tx_active_work" 2>/dev/null || return 1
    fi

    if [ -f "$_tx_dir/had-url" ]; then
        [ -f "$_tx_dir/old-url" ] || return 1
        _tx_tmp="${_tx_active_url}.reconcile.$$"
        if ! cp -f "$_tx_dir/old-url" "$_tx_tmp" || ! mv -f "$_tx_tmp" "$_tx_active_url"; then
            rm -f "$_tx_tmp" 2>/dev/null || true
            return 1
        fi
    else
        rm -f "$_tx_active_url" 2>/dev/null || return 1
    fi

    if [ -f "$_tx_dir/had-local" ]; then
        [ -f "$_tx_dir/old-local" ] || return 1
        _tx_tmp="${_tx_active_local}.reconcile.$$"
        if ! cp -f "$_tx_dir/old-local" "$_tx_tmp" || ! mv -f "$_tx_tmp" "$_tx_active_local"; then
            rm -f "$_tx_tmp" 2>/dev/null || true
            return 1
        fi
    else
        rm -f "$_tx_active_local" 2>/dev/null || return 1
    fi

    if [ -n "$_tx_generation" ]; then
        rm -rf "${MODDIR}/.state/sing-box/subscription-generations/${_tx_generation}" 2>/dev/null || true
        rm -f "${_tx_active_config}.candidate-${_tx_generation}" \
            "${_tx_active_config}.candidate-${_tx_generation}.new" 2>/dev/null || true
    fi

    if [ "$_tx_restart_required" -eq 1 ]; then
        MAGICNET_SUB_PRESERVE_REFRESH=1
        export MAGICNET_SUB_PRESERVE_REFRESH
        magicnet_singbox_restart_owned "$_tx_active_config" >/dev/null 2>&1 || {
            unset MAGICNET_SUB_PRESERVE_REFRESH
            return 1
        }
        unset MAGICNET_SUB_PRESERVE_REFRESH
    elif [ -f "$_tx_dir/was-running" ]; then
        # The core can still be alive while a signal interrupts restart_owned
        # after it removed DNS interception and the leak guard. Reapply the
        # complete post-start policy before treating an identical config as
        # recovered; otherwise startup would see a live core and return early
        # with the TUN/DNS runtime only half initialized.
        _tx_policy_rc=0
        magicnet_reapply_post_start_policy || _tx_policy_rc=1
        [ "$_tx_policy_rc" -eq 0 ] || return 1
    fi

    rm -rf "$_tx_dir" 2>/dev/null || return 1
    unset _tx_dir _tx_active_config _tx_active_work _tx_active_url _tx_active_local
    unset _tx_generation _tx_restart_required _tx_policy_rc _tx_tmp _tx_work_tmp _tx_work_backup
}

magicnet_singbox_transaction_begin_abort() {
    [ -n "${_tx_tmp:-}" ] && rm -rf "$_tx_tmp" 2>/dev/null || true
    unset _tx_dir _tx_tmp _tx_active_config _tx_active_work _tx_active_url _tx_active_local
    return 1
}

magicnet_singbox_transaction_begin() {
    _tx_dir=$(magicnet_singbox_transaction_dir)
    _tx_tmp="${_tx_dir}.new.$$"
    _tx_active_config="${MODDIR}/.config/sing-box/config.json"
    _tx_active_work="${MODDIR}/.state/sing-box/subscription-work"
    _tx_active_url="${MODDIR}/.config/sing-box/subscription.url"
    _tx_active_local="${MODDIR}/.config/sing-box/subscription.local"
    rm -rf "$_tx_tmp" 2>/dev/null || true
    [ ! -e "$_tx_dir" ] || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    mkdir -p "$_tx_tmp" || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }

    if [ -f "$_tx_active_config" ]; then
        : >"$_tx_tmp/had-config" || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
        (
            umask 077
            cp -f "$_tx_active_config" "$_tx_tmp/old-config"
        ) || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
    fi
    if [ -d "$_tx_active_work" ]; then
        : >"$_tx_tmp/had-work" || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
        cp -a "$_tx_active_work" "$_tx_tmp/old-work" || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
    fi
    if [ -f "$_tx_active_url" ]; then
        : >"$_tx_tmp/had-url" || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
        cp -f "$_tx_active_url" "$_tx_tmp/old-url" || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
    fi
    if [ -f "$_tx_active_local" ]; then
        : >"$_tx_tmp/had-local" || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
        cp -f "$_tx_active_local" "$_tx_tmp/old-local" || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
    fi
    [ -f "$_sub_input_source" ] || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    cp -f "$_sub_input_source" "$_tx_tmp/input-source" || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    chmod 600 "$_tx_tmp/input-source" 2>/dev/null || true
    printf '%s\n' "$_sub_source_mode" >"$_tx_tmp/input-mode" || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    if [ "${_sub_was_running:-0}" -eq 1 ]; then
        : >"$_tx_tmp/was-running" || {
            magicnet_singbox_transaction_begin_abort
            return 1
        }
    fi
    printf '%s\n' "$_sub_generation_id" >"$_tx_tmp/generation-id" || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    : >"$_tx_tmp/owns-generation" || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    : >"$_tx_tmp/owns-config-candidate" || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    printf '%s\n' prepared >"$_tx_tmp/phase" || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    mv "$_tx_tmp" "$_tx_dir" || {
        magicnet_singbox_transaction_begin_abort
        return 1
    }
    _sub_original_input_source="$_sub_input_source"
    _sub_input_source="${_tx_dir}/input-source"
    if [ "$_sub_source_mode" = local ]; then
        MAGICNET_SUB_SOURCE_FILE="$_sub_input_source"
        unset MAGICNET_SUB_URL_FILE
        export MAGICNET_SUB_SOURCE_FILE
    else
        MAGICNET_SUB_URL_FILE="$_sub_input_source"
        unset MAGICNET_SUB_SOURCE_FILE
        export MAGICNET_SUB_URL_FILE
    fi
    if [ "$_sub_original_input_source" != "$_tx_active_url" ] &&
        [ "$_sub_original_input_source" != "$_tx_active_local" ]; then
        rm -f "$_sub_original_input_source" 2>/dev/null || true
    fi
    unset _tx_dir _tx_tmp _tx_active_config _tx_active_work _tx_active_url _tx_active_local
}

magicnet_singbox_cleanup_stale_candidates() {
    _candidate_keep="${1:-}"
    _candidate_dir="${MODDIR}/.state/sing-box/subscription-candidates"
    _candidate_config_dir="${MODDIR}/.config/sing-box"
    for _candidate_path in "$_candidate_dir"/*; do
        [ -f "$_candidate_path" ] || continue
        [ -n "$_candidate_keep" ] && [ "$_candidate_path" = "$_candidate_keep" ] && continue
        rm -f "$_candidate_path" 2>/dev/null || true
    done
    for _candidate_path in "$_candidate_config_dir"/config.json.candidate-*; do
        [ -e "$_candidate_path" ] || continue
        rm -f "$_candidate_path" "${_candidate_path}.new" 2>/dev/null || true
    done
    rm -rf "$(magicnet_singbox_transaction_dir).new."* 2>/dev/null || true
    unset _candidate_keep _candidate_dir _candidate_config_dir _candidate_path
}

magicnet_singbox_transaction_phase() {
    _tx_dir=$(magicnet_singbox_transaction_dir)
    [ -d "$_tx_dir" ] || {
        unset _tx_dir
        return 1
    }
    _tx_phase=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-48)
    _tx_phase_tmp="$_tx_dir/phase.tmp.$$"
    # Phase metadata is part of the durable journal.  Write it privately and
    # publish it atomically so a transient filesystem failure cannot truncate
    # the last known phase or make the caller believe the write succeeded.
    if ! (
        umask 077
        printf '%s\n' "${_tx_phase:-unknown}" >"$_tx_phase_tmp"
    ) ||
        ! mv -f "$_tx_phase_tmp" "$_tx_dir/phase"; then
        rm -f "$_tx_phase_tmp" 2>/dev/null || true
        unset _tx_dir _tx_phase _tx_phase_tmp
        return 1
    fi
    unset _tx_dir _tx_phase _tx_phase_tmp
}

magicnet_singbox_fault() {
    [ "${MAGICNET_SUB_FAULT:-}" = "$1" ] || return 0
    warn "Injected subscription transaction fault at $1"
    if [ "${MAGICNET_SUB_FAULT_TERM:-0}" = "1" ]; then
        # shellcheck disable=SC3028 # Bash test hook; Android sh falls back to $$.
        kill -TERM "${BASHPID:-$$}"
        return 1
    fi
    if [ "${MAGICNET_SUB_FAULT_EXIT137:-0}" = "1" ]; then
        exit 137
    fi
    return 1
}

magicnet_singbox_status() {
    _status_tx_dir=$(magicnet_singbox_transaction_dir)
    _status_tx_pending=0
    [ -d "$_status_tx_dir" ] && _status_tx_pending=1
    _status_last_result=$(magicnet_singbox_status_value result never)
    _status_update_active=0
    magicnet_singbox_update_lock_live && _status_update_active=1
    if [ "$_status_update_active" -eq 1 ]; then
        if [ "$_status_tx_pending" -eq 1 ]; then
            _status_recovery_result=active
        else
            _status_recovery_result=none
        fi
    elif [ "$_status_tx_pending" -eq 1 ]; then
        # Status is a diagnostic command and must never restore files, rewrite
        # firewall state, or restart a live core.  Lifecycle/update entrypoints
        # own interrupted-transaction recovery; report it here as pending.
        _status_recovery_result=pending
    else
        _status_recovery_result=none
    fi
    if [ "$_status_last_result" = running ] && [ "$_status_update_active" -eq 0 ]; then
        _status_last_result=interrupted
    fi
    _status_active_url="${MODDIR}/.config/sing-box/subscription.url"
    _status_active_local="${MODDIR}/.config/sing-box/subscription.local"
    if [ -s "$_status_active_local" ]; then
        _status_source_mode=local
        _status_configured=1
    else
        _status_source_mode=url
        _status_configured=$(awk 'NF { count++ } END { print count + 0 }' "$_status_active_url" 2>/dev/null || true)
    fi
    _status_cache_dir=$(magicnet_singbox_subscription_cache_dir)
    _status_cache_count=$(find "$_status_cache_dir" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_status_update_active" -eq 1 ]; then
        _status_running=1
        _status_lock_owner=active
    else
        _status_running=0
        _status_lock_owner=none
    fi
    _status_cache_provenance_count=$(find "$_status_cache_dir" -maxdepth 1 -type f -name '*.yaml.identity' 2>/dev/null | wc -l | tr -d ' ')
    if _status_cache_probe=$(magicnet_singbox_subscription_fingerprint cache-probe 2>/dev/null) &&
        printf '%s' "$_status_cache_probe" | grep -Eq '^[0-9a-fA-F]{64}$'; then
        _status_cache_source=url_sha256_identity
    else
        _status_cache_source=disabled_no_sha256
    fi
    printf 'configured_count=%s\n' "${_status_configured:-0}"
    printf 'source_mode=%s\n' "$_status_source_mode"
    printf 'update_running=%s\n' "$_status_running"
    printf 'update_lock_owner=%s\n' "$_status_lock_owner"
    printf 'recovery_result=%s\n' "$_status_recovery_result"
    printf 'last_phase=%s\n' "$(magicnet_singbox_status_value phase never)"
    printf 'last_result=%s\n' "$_status_last_result"
    printf 'last_attempt_epoch=%s\n' "$(magicnet_singbox_status_value attempt_epoch 0)"
    printf 'last_success_epoch=%s\n' "$(magicnet_singbox_status_value success_epoch 0)"
    printf 'last_configured_count=%s\n' "$(magicnet_singbox_status_value configured_count 0)"
    printf 'last_source_count=%s\n' "$(magicnet_singbox_status_value source_count 0)"
    printf 'last_imported_count=%s\n' "$(magicnet_singbox_status_value imported_count 0)"
    printf 'last_skipped_count=%s\n' "$(magicnet_singbox_status_value skipped_count 0)"
    printf 'last_generation_id=%s\n' "$(magicnet_singbox_status_value generation_id none)"
    printf 'last_reason=%s\n' "$(magicnet_singbox_status_value reason none)"
    printf 'last_source_mode=%s\n' "$(magicnet_singbox_status_value source_mode unknown)"
    printf 'last_native_parser=%s\n' "$(magicnet_singbox_status_value native_parser unknown)"
    printf 'last_native_node_count=%s\n' "$(magicnet_singbox_status_value native_node_count 0)"
    printf 'last_converter_enabled=%s\n' "$(magicnet_singbox_status_value converter_enabled unknown)"
    printf 'last_converter_available=%s\n' "$(magicnet_singbox_status_value converter_available unknown)"
    printf 'last_converter_attempted=%s\n' "$(magicnet_singbox_status_value converter_attempted 0)"
    printf 'last_converter_format=%s\n' "$(magicnet_singbox_status_value converter_format none)"
    printf 'last_converter_result=%s\n' "$(magicnet_singbox_status_value converter_result unknown)"
    printf 'cache_count=%s\n' "${_status_cache_count:-0}"
    printf 'cache_provenance_count=%s\n' "${_status_cache_provenance_count:-0}"
    printf 'cache_source=%s\n' "$_status_cache_source"
    if command -v magicnet_subscription_schedule_report >/dev/null 2>&1; then
        magicnet_subscription_schedule_report
    else
        printf '%s\n' 'schedule_interval_hours=off' 'schedule_enabled=0' 'schedule_running=0'
    fi
    unset _status_active_url _status_active_local _status_source_mode _status_configured
    unset _status_cache_dir _status_cache_count _status_running
    unset _status_lock_owner _status_cache_provenance_count _status_cache_probe _status_cache_source
    unset _status_tx_dir _status_tx_pending _status_last_result
    unset _status_recovery_result _status_update_active
}

magicnet_singbox_recover_interrupted_locked() {
    # Both operations can restore or rewrite persisted subscription state.
    # Lifecycle callers must hold the config lock so a just-started updater
    # cannot race recovery and lose its active files intermittently.
    _status_locked_rc=0
    magicnet_singbox_transaction_reconcile >/dev/null 2>&1 || _status_locked_rc=1
    if [ "$_status_locked_rc" -eq 0 ]; then
        magicnet_singbox_status_reconcile >/dev/null 2>&1 || _status_locked_rc=1
    fi
    set -- "$_status_locked_rc"
    unset _status_locked_rc
    return "$1"
}

magicnet_singbox_update_status() {
    magicnet_singbox_status_write "$1" "$2" "$_sub_attempt_epoch" "$_sub_success_epoch" \
        "${MAGICNET_SUB_CONFIGURED_COUNT:-$_sub_configured_count}" \
        "${MAGICNET_SUB_SOURCE_COUNT:-0}" "${_imported:-0}" "${_skipped:-0}" \
        "$_sub_generation_id" "$3"
}

magicnet_singbox_update_cleanup_stage() {
    [ -n "${_sub_candidate_config:-}" ] && rm -f "$_sub_candidate_config" "${_sub_candidate_config}.new" 2>/dev/null || true
    [ -n "${_sub_stage_dir:-}" ] && rm -rf "$_sub_stage_dir" 2>/dev/null || true
}

magicnet_singbox_update_interrupt() {
    _update_interrupt_code="$1"
    trap - EXIT HUP INT TERM
    _update_interrupt_had_config_lock="${MAGICNET_CONFIG_LOCK_HELD:-0}"
    if [ "$_update_interrupt_had_config_lock" = 1 ]; then
        magicnet_singbox_transaction_reconcile >/dev/null 2>&1 || true
    fi
    magicnet_singbox_update_cleanup_stage
    magicnet_singbox_status_mark_interrupted
    if [ "$_update_interrupt_had_config_lock" = 1 ] &&
        command -v magicnet_config_lock_release >/dev/null 2>&1; then
        magicnet_config_lock_release
    fi
    MAGICNET_CONFIG_LOCK_HELD=0
    unset MAGICNET_CONFIG_LOCK_HELD
    unset MAGICNET_SUB_DEFER_FSWATCH_RESTORE
    _update_restore_fswatch="${MAGICNET_SUB_FSWATCH_RESTORE_PENDING:-0}"
    if [ "${MAGICNET_SUB_FSWATCH_WAS_ACTIVE:-0}" = 1 ]; then
        _update_restore_fswatch=1
    fi
    if [ "$_update_restore_fswatch" = 1 ]; then
        magicnet_singbox_supervisor_restore 1 >/dev/null 2>&1 || true
    fi
    unset _update_restore_fswatch _update_interrupt_had_config_lock
    unset MAGICNET_SUB_FSWATCH_RESTORE_PENDING MAGICNET_SUB_FSWATCH_WAS_ACTIVE
    magicnet_singbox_update_lock_release
    exit "$_update_interrupt_code"
}

magicnet_singbox_update_subscription() {
    magicnet_singbox_update_lock_acquire || return 1
    trap 'magicnet_singbox_update_lock_release' EXIT
    trap 'magicnet_singbox_update_interrupt 129' HUP
    trap 'magicnet_singbox_update_interrupt 130' INT
    trap 'magicnet_singbox_update_interrupt 143' TERM
    if ! magicnet_with_config_lock magicnet_singbox_transaction_reconcile; then
        trap - EXIT HUP INT TERM
        magicnet_singbox_update_lock_release
        error "Previous subscription transaction recovery failed"
        return 1
    fi
    magicnet_singbox_cleanup_stale_candidates "${MAGICNET_SUB_CANDIDATE_URL_FILE:-${MAGICNET_SUB_CANDIDATE_SOURCE_FILE:-}}"
    # Read by magicnet_singbox_restart_owned in config.sh.
    # shellcheck disable=SC2034
    MAGICNET_SUB_DEFER_FSWATCH_RESTORE=1
    MAGICNET_SUB_FSWATCH_RESTORE_PENDING=0
    magicnet_with_config_lock magicnet_singbox_update_subscription_unlocked
    _update_rc=$?
    unset MAGICNET_SUB_DEFER_FSWATCH_RESTORE
    if [ "$_update_rc" -ne 0 ]; then
        magicnet_with_config_lock magicnet_singbox_transaction_reconcile >/dev/null 2>&1 || true
        magicnet_singbox_update_cleanup_stage
    fi
    if [ "${MAGICNET_SUB_FSWATCH_RESTORE_PENDING:-0}" -eq 1 ] &&
        ! magicnet_singbox_supervisor_restore 1; then
        _update_rc=1
        magicnet_singbox_update_status complete failed fswatch_restore_failed || true
        error "fswatch failed to restart after subscription update"
    fi
    unset MAGICNET_SUB_FSWATCH_RESTORE_PENDING
    trap - EXIT HUP INT TERM
    magicnet_singbox_update_lock_release
    return "$_update_rc"
}

magicnet_singbox_update_subscription_unlocked() {
    _sub_state_dir="${MODDIR}/.state/sing-box"
    _sub_attempt_epoch=$(date +%s)
    _sub_success_epoch=$(magicnet_singbox_status_value success_epoch 0)
    _sub_generation_id="${_sub_attempt_epoch}-$$"
    _sub_stage_dir="${_sub_state_dir}/subscription-generations/${_sub_generation_id}"
    _work_dir="${_sub_state_dir}/subscription-work"
    _nodes_dir="${_sub_stage_dir}/nodes"
    _outbounds_file="${_sub_stage_dir}/outbounds.json"
    _tags_file="${_sub_stage_dir}/tags.txt"
    _sources_file="${_sub_stage_dir}/sources.txt"
    _counts_file="${_sub_stage_dir}/counts.txt"
    _sub_active_url="${MODDIR}/.config/sing-box/subscription.url"
    _sub_active_local="${MODDIR}/.config/sing-box/subscription.local"
    if [ -n "${MAGICNET_SUB_CANDIDATE_URL_FILE:-}" ] &&
        [ -n "${MAGICNET_SUB_CANDIDATE_SOURCE_FILE:-}" ]; then
        magicnet_singbox_update_status prepare failed ambiguous_source_mode || true
        return 1
    fi
    if [ -n "${MAGICNET_SUB_CANDIDATE_SOURCE_FILE:-}" ]; then
        _sub_source_mode=local
        _sub_input_source="$MAGICNET_SUB_CANDIDATE_SOURCE_FILE"
    elif [ -n "${MAGICNET_SUB_CANDIDATE_URL_FILE:-}" ]; then
        _sub_source_mode=url
        _sub_input_source="$MAGICNET_SUB_CANDIDATE_URL_FILE"
    elif [ -n "${MAGICNET_SUB_SOURCE_FILE:-}" ]; then
        _sub_source_mode=local
        _sub_input_source="$MAGICNET_SUB_SOURCE_FILE"
    elif [ -s "$_sub_active_local" ]; then
        _sub_source_mode=local
        _sub_input_source="$_sub_active_local"
    else
        _sub_source_mode=url
        _sub_input_source="${MAGICNET_SUB_URL_FILE:-$_sub_active_url}"
    fi
    MAGICNET_SUB_SOURCE_MODE="$_sub_source_mode"
    MAGICNET_SUB_NATIVE_PARSER=unknown
    MAGICNET_SUB_NATIVE_NODE_COUNT=0
    case "${MAGICNET_PROXYLINK_ENABLED:-1}" in
    1) MAGICNET_SUB_CONVERTER_ENABLED=1 ;;
    *) MAGICNET_SUB_CONVERTER_ENABLED=0 ;;
    esac
    if [ "$MAGICNET_SUB_CONVERTER_ENABLED" = 1 ] &&
        magicnet_singbox_proxylink_bin >/dev/null 2>&1; then
        MAGICNET_SUB_CONVERTER_AVAILABLE=1
    else
        MAGICNET_SUB_CONVERTER_AVAILABLE=0
    fi
    MAGICNET_SUB_CONVERTER_ATTEMPTED=0
    MAGICNET_SUB_CONVERTER_FORMAT=none
    if [ "$MAGICNET_SUB_CONVERTER_ENABLED" != 1 ]; then
        MAGICNET_SUB_CONVERTER_RESULT=disabled
    elif [ "$MAGICNET_SUB_CONVERTER_AVAILABLE" != 1 ]; then
        MAGICNET_SUB_CONVERTER_RESULT=unavailable
    else
        MAGICNET_SUB_CONVERTER_RESULT=not_attempted
    fi
    _sub_active_config="${MODDIR}/.config/sing-box/config.json"
    _sub_candidate_config="${_sub_active_config}.candidate-${_sub_generation_id}"
    _sub_was_running=0
    if magicnet_singbox_is_running "$_sub_active_config"; then
        _sub_running_rc=0
    else
        _sub_running_rc=$?
    fi
    case "$_sub_running_rc" in
    0) _sub_was_running=1 ;;
    1) ;;
    *)
        magicnet_singbox_update_status prepare failed process_state_indeterminate || true
        return 2
        ;;
    esac
    if ! magicnet_singbox_transaction_begin; then
        rm -rf "$(magicnet_singbox_transaction_dir).new.$$" 2>/dev/null || true
        magicnet_singbox_update_status prepare failed journal_create_failed || true
        return 1
    fi
    if [ "$_sub_source_mode" = local ]; then
        _sub_configured_count=1
    else
        _sub_configured_count=$(awk 'NF { count++ } END { print count + 0 }' "$_sub_input_source" 2>/dev/null)
    fi
    MAGICNET_SUB_CONFIGURED_COUNT="$_sub_configured_count"
    MAGICNET_SUB_SOURCE_COUNT=0
    _imported=0
    _skipped=0

    mkdir -p "$_nodes_dir" || {
        magicnet_singbox_update_status prepare failed staging_create_failed
        return 1
    }
    magicnet_singbox_update_status prepare running none || true

    info "Subscription update stage: fetch"
    magicnet_singbox_update_status fetch running none || true
    if ! magicnet_singbox_fetch_subscription "$_sources_file"; then
        magicnet_singbox_update_status fetch failed fetch_failed || true
        magicnet_singbox_update_cleanup_stage
        return 1
    fi

    _node_total=0
    _native_parser=none
    while IFS= read -r _source_file || [ -n "$_source_file" ]; do
        [ -s "$_source_file" ] || continue
        if grep -Eq '^proxies:[[:space:]]*$' "$_source_file"; then
            _node_count=$(magicnet_singbox_extract_clash_nodes "$_source_file" "$_nodes_dir")
            _native_kind=clash
        else
            _node_count=$(magicnet_singbox_extract_share_links "$_source_file" "$_nodes_dir")
            _native_kind=share-links
        fi
        _node_total=$((_node_total + ${_node_count:-0}))
        case "$_native_parser:$_native_kind" in
        none:*) _native_parser="$_native_kind" ;;
        *:"$_native_kind") : ;;
        *) _native_parser=mixed ;;
        esac
    done <"$_sources_file"
    MAGICNET_SUB_NATIVE_PARSER="$_native_parser"
    MAGICNET_SUB_NATIVE_NODE_COUNT="$_node_total"

    info "Subscription update stage: convert"
    magicnet_singbox_update_status convert running none || true
    if [ "$MAGICNET_SUB_CONVERTER_ENABLED" = 1 ] &&
        [ "$MAGICNET_SUB_CONVERTER_AVAILABLE" = 1 ]; then
        MAGICNET_SUB_CONVERTER_ATTEMPTED=1
        MAGICNET_SUB_CONVERTER_RESULT=failed
        if magicnet_singbox_build_outbounds_with_proxylink "$_sources_file" "$_outbounds_file" "$_node_total" >"${_sub_stage_dir}/proxylink-counts.txt" 2>/dev/null; then
            # shellcheck disable=SC2046
            set -- $(cat "${_sub_stage_dir}/proxylink-counts.txt")
            _imported="$1"
            _skipped="$2"
            MAGICNET_SUB_CONVERTER_RESULT=success
        fi
    fi
    if [ "${MAGICNET_SUB_CONVERTER_RESULT:-not_attempted}" != success ] &&
        [ "${_node_total:-0}" -gt 0 ]; then
        magicnet_singbox_build_outbounds_file "$_nodes_dir" "$_outbounds_file" "$_tags_file" >"$_counts_file" ||
            {
                magicnet_singbox_update_status convert failed conversion_failed || true
                magicnet_singbox_update_cleanup_stage
                return 1
            }
        # shellcheck disable=SC2046
        set -- $(cat "$_counts_file")
        _imported="$1"
        _skipped="$2"
    elif [ "${_imported:-0}" -le 0 ]; then
        # Native parsing may legitimately return zero for formats handled by
        # the optional converter (for example sing-box JSON). At this point
        # both conversion paths have been exhausted.
        error "No supported subscription nodes found"
        magicnet_singbox_update_status convert failed no_supported_nodes || true
        magicnet_singbox_update_cleanup_stage
        return 1
    fi

    if [ "${_imported:-0}" -le 0 ]; then
        error "No supported nodes imported. Supported natively: Clash/share-link ss, socks, vmess, vless, trojan, hysteria2, anytls, tuic. Proxylink remains an optional converter for other formats when present."
        magicnet_singbox_update_status convert failed no_nodes_imported || true
        magicnet_singbox_update_cleanup_stage
        return 1
    fi

    info "Subscription update stage: validate"
    magicnet_singbox_update_status validate running none || true
    if ! (
        umask 077
        cp -f "$_sub_active_config" "$_sub_candidate_config"
    ); then
        magicnet_singbox_update_status validate failed config_stage_failed || true
        magicnet_singbox_update_cleanup_stage
        return 1
    fi
    MAGICNET_SUB_CONFIG_FILE="$_sub_candidate_config"
    export MAGICNET_SUB_CONFIG_FILE
    if ! magicnet_singbox_update_config_with_nodes "$_outbounds_file"; then
        unset MAGICNET_SUB_CONFIG_FILE
        magicnet_singbox_update_status validate failed config_validation_failed || true
        magicnet_singbox_update_cleanup_stage
        return 1
    fi
    unset MAGICNET_SUB_CONFIG_FILE

    info "Subscription update stage: activate"
    magicnet_singbox_update_status activate running none || true
    _update_fswatch_active=0
    magicnet_fswatch_status >/dev/null 2>&1 && _update_fswatch_active=1
    if ! chmod 600 "$_sub_candidate_config" 2>/dev/null ||
        ! mv -f "$_sub_candidate_config" "$_sub_active_config" ||
        ! chmod 600 "$_sub_active_config" 2>/dev/null; then
        magicnet_singbox_update_status activate failed config_activate_failed || true
        return 1
    fi
    if ! magicnet_singbox_transaction_phase active-config; then
        magicnet_singbox_update_status activate failed journal_phase_write_failed || true
        return 1
    fi
    magicnet_singbox_fault after-active-config-rename || return 1
    # Read by magicnet_singbox_restart_owned in config.sh.
    # shellcheck disable=SC2034
    MAGICNET_SUB_FSWATCH_WAS_ACTIVE="$_update_fswatch_active"
    MAGICNET_SUB_PRESERVE_REFRESH=1
    MAGICNET_SUB_RESET_BOOTSTRAP_CACHE=0
    if [ "$_sub_success_epoch" = 0 ] && [ "${_imported:-0}" -gt 0 ]; then
        if [ "$_sub_was_running" -eq 1 ]; then
            # The zero-node bootstrap config pins selectors to block. Do not
            # let that cached choice survive the first populated config.
            MAGICNET_SUB_RESET_BOOTSTRAP_CACHE=1
        elif ! magicnet_singbox_reset_bootstrap_cache "$_sub_active_config"; then
            magicnet_singbox_update_status activate failed cache_reset_failed || true
            return 1
        fi
    fi
    export MAGICNET_SUB_PRESERVE_REFRESH MAGICNET_SUB_RESET_BOOTSTRAP_CACHE
    if ! magicnet_singbox_verify_subscription_ready; then
        unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE MAGICNET_SUB_PRESERVE_REFRESH \
            MAGICNET_SUB_RESET_BOOTSTRAP_CACHE
        magicnet_singbox_update_status activate failed activation_failed || true
        error "Subscription activation failed"
        return 1
    fi
    unset MAGICNET_SUB_FSWATCH_WAS_ACTIVE MAGICNET_SUB_PRESERVE_REFRESH \
        MAGICNET_SUB_RESET_BOOTSTRAP_CACHE
    if ! magicnet_singbox_transaction_phase core-verified; then
        magicnet_singbox_update_status activate failed journal_phase_write_failed || true
        return 1
    fi
    magicnet_singbox_fault after-core-verification || return 1

    magicnet_singbox_update_status commit running none || true
    rm -rf "$_work_dir" 2>/dev/null || return 1
    if ! mv "$_sub_stage_dir" "$_work_dir"; then
        magicnet_singbox_update_status commit failed work_commit_failed || true
        return 1
    fi
    if ! magicnet_singbox_transaction_phase work-switched; then
        magicnet_singbox_update_status commit failed journal_phase_write_failed || true
        return 1
    fi
    magicnet_singbox_fault after-work-switch || return 1

    if [ "$_sub_source_mode" = local ]; then
        _sub_source_target="$_sub_active_local"
        _sub_source_other="$_sub_active_url"
    else
        _sub_source_target="$_sub_active_url"
        _sub_source_other="$_sub_active_local"
    fi
    if [ "$_sub_input_source" != "$_sub_source_target" ]; then
        _sub_source_tmp="${_sub_source_target}.new-${_sub_generation_id}"
        if ! cp -f "$_sub_input_source" "$_sub_source_tmp" || ! mv -f "$_sub_source_tmp" "$_sub_source_target"; then
            rm -f "$_sub_source_tmp" 2>/dev/null || true
            magicnet_singbox_update_status commit failed source_commit_failed || true
            return 1
        fi
    fi
    rm -f "$_sub_source_other" 2>/dev/null || {
        magicnet_singbox_update_status commit failed source_mode_switch_failed || true
        return 1
    }
    if ! magicnet_singbox_transaction_phase source-committed; then
        magicnet_singbox_update_status commit failed journal_phase_write_failed || true
        return 1
    fi
    magicnet_singbox_fault after-source-commit || return 1
    magicnet_singbox_fault after-url-commit || return 1

    _sub_cache_map="${_work_dir}/cache-map.txt"
    if [ -f "$_sub_cache_map" ]; then
        while IFS='|' read -r _sub_cache_name _sub_cache_file _sub_identity_file _sub_fingerprint _sub_extra; do
            [ -z "$_sub_extra" ] || continue
            printf '%s' "$_sub_fingerprint" | grep -Eq '^[0-9a-f]{64}$' || continue
            [ "$_sub_cache_name" = "${_sub_fingerprint}.yaml" ] || continue
            [ "$_sub_cache_file" = "$(magicnet_singbox_subscription_cache_dir)/${_sub_fingerprint}.yaml" ] || continue
            [ "$_sub_identity_file" = "${_sub_cache_file}.identity" ] || continue
            _sub_cache_source="${_work_dir}/sources/${_sub_cache_name}"
            _sub_cache_tmp="${_sub_cache_file}.tmp.$$"
            _sub_identity_tmp="${_sub_identity_file}.tmp.$$"
            if ! cp -f "$_sub_cache_source" "$_sub_cache_tmp" ||
                ! printf '%s\n' "$_sub_fingerprint" >"$_sub_identity_tmp" ||
                ! mv -f "$_sub_cache_tmp" "$_sub_cache_file" ||
                ! mv -f "$_sub_identity_tmp" "$_sub_identity_file"; then
                rm -f "$_sub_cache_tmp" "$_sub_identity_tmp" 2>/dev/null || true
                warn "Subscription cache persistence failed for one source"
            fi
        done <"$_sub_cache_map"
    fi
    magicnet_singbox_prune_subscription_cache "$_sub_cache_map" ||
        warn "Subscription cache pruning failed"

    rm -rf "$(magicnet_singbox_transaction_dir)" 2>/dev/null || return 1
    _sub_success_epoch=$(date +%s)
    magicnet_singbox_update_status complete success none || true
    success "sing-box nodes updated: imported ${_imported}, skipped ${_skipped}"
}
