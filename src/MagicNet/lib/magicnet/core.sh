magicnet_status_text() {
    "$1" >/dev/null 2>&1
    _status_text_rc=$?
    case "$_status_text_rc" in
    0) printf '%s\n' "Running" ;;
    1) printf '%s\n' "Stopped" ;;
    *) printf '%s\n' "Unknown" ;;
    esac
}

# Keep sing-box's Go-managed working set bounded without trading normal
# throughput for an aggressively low GOGC value. GOMEMLIMIT is a soft runtime
# budget: the GC stays on its normal pacing until the process approaches it.
# Operators can provide the standard GOMEMLIMIT environment variable to
# override or disable (GOMEMLIMIT=off) auto sizing.
magicnet_singbox_runtime_memory_limit() {
    if [ -n "${GOMEMLIMIT:-}" ]; then
        printf '%s\n' "$GOMEMLIMIT"
        return 0
    fi

    _singbox_meminfo="${MAGICNET_MEMINFO_PATH:-/proc/meminfo}"
    _singbox_mem_total_kib="$(
        awk '/^MemTotal:/ { print $2; exit }' "$_singbox_meminfo" 2>/dev/null || true
    )"
    case "$_singbox_mem_total_kib" in
    '' | *[!0-9]*)
        # Android always exposes /proc/meminfo, but retain a conservative
        # fallback for recovery shells and host-side tests.
        _singbox_memory_limit_mib=384
        ;;
    *)
        # Fixed tiers are intentionally less aggressive than a percentage-only
        # budget on modern 8-16 GiB phones, while still capping runaway heaps.
        if [ "$_singbox_mem_total_kib" -lt 3145728 ]; then
            _singbox_memory_limit_mib=192
        elif [ "$_singbox_mem_total_kib" -lt 6291456 ]; then
            _singbox_memory_limit_mib=256
        elif [ "$_singbox_mem_total_kib" -lt 12582912 ]; then
            _singbox_memory_limit_mib=384
        else
            _singbox_memory_limit_mib=512
        fi
        ;;
    esac

    printf '%sMiB\n' "$_singbox_memory_limit_mib"
    unset _singbox_meminfo _singbox_mem_total_kib _singbox_memory_limit_mib
}

magicnet_refresh_status() {
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        if is_singbox_running >/dev/null 2>&1; then
            _refresh_running_rc=0
        else
            _refresh_running_rc=$?
        fi
        case "$_refresh_running_rc" in
        0) return 0 ;;
        1) ;;
        *) return 2 ;;
        esac
    fi

    config set override.description "[MagicNet]: No kernel running" 2>/dev/null || true
}

# Internal, zero-argument startup steps. Keep execution in this shell: several
# normalizers publish variables needed by later steps. Positional parameters
# survive nested helpers without shared scratch-variable or subshell races.
# Only fixed stage names and exit codes are logged, never command arguments,
# subscription URLs or config/auth contents. This is a diagnostic, not state.
magicnet_startup_step() {
    if "$2"; then
        return 0
    else
        set -- "$1" "$?"
    fi
    magicnet_warn "Startup step failed: stage=$1 exit=$2" >&2
    return "$2"
}

magicnet_prepare_singbox_candidate_unlocked() {
    magicnet_module_disabled && return 1
    [ "${MAGIC_SINGBOX:-1}" -ne 0 ] || return 1
    magicnet_cmd_exists sing-box || return 1
    magicnet_startup_step subscription magicnet_prepare_singbox_nodes_unlocked || return $?
    magicnet_startup_step chain magicnet_singbox_chain_apply || return $?
    magicnet_startup_step transparent magicnet_singbox_apply_transparent_mode || return $?
    magicnet_startup_step hotspot magicnet_singbox_apply_hotspot_policy || return $?
    magicnet_startup_step dns magicnet_dns_apply_unlocked || return $?
    magicnet_startup_step tailscale magicnet_tailscale_apply_unlocked || return $?
    magicnet_startup_step apps magicnet_app_policy_apply_unlocked || return $?
    magicnet_startup_step warp magicnet_warp_apply_unlocked || return $?
    magicnet_singbox_apply_zashboard ||
        magicnet_warn "Failed to materialize the sing-box Zashboard panel; the core will continue without the panel rewrite."
    if [ -s "$MODDIR/.config/magicnet/config-override-active.json" ] || [ -s "$MODDIR/.state/override-materialization/checkpoint.json" ]; then
        magicnet_startup_step overrides magicnet_override_materialize_unlocked || return $?
    fi
    magicnet_startup_step config-check magicnet_validate_singbox_transparent_config
}

magicnet_start_singbox_unlocked() {
    magicnet_module_disabled && return 1
    [ "${MAGIC_SINGBOX:-1}" -ne 0 ] || return 1
    magicnet_cmd_exists sing-box || return 1
    import __singbox__
    if is_singbox_running >/dev/null 2>&1; then
        _start_running_rc=0
    else
        _start_running_rc=$?
    fi
    case "$_start_running_rc" in
    0) return 0 ;;
    1) ;;
    *)
        magicnet_warn "sing-box process discovery is indeterminate; start aborted."
        return 2
        ;;
    esac
    if [ "${MAGICNET_TRANSPARENT_RESTORED_CONFIG:-0}" != 1 ]; then
        magicnet_startup_step subscription magicnet_prepare_singbox_nodes_unlocked || return $?
        magicnet_startup_step chain magicnet_singbox_chain_apply || return $?
        magicnet_startup_step transparent magicnet_singbox_apply_transparent_mode || return $?
        magicnet_startup_step hotspot magicnet_singbox_apply_hotspot_policy || return $?
        # sing-box snapshots DNS servers and WARP endpoints when the process
        # starts. Applying these only in the post-start rewrite made a fresh
        # start report success while the running core still held the old config.
        magicnet_startup_step dns magicnet_dns_apply_unlocked || return $?
        magicnet_startup_step tailscale magicnet_tailscale_apply_unlocked || return $?
        # The preceding normalizers rebuild the managed transparent inbound.
        # Materialize per-app UID boundaries before sing-box snapshots it.
        magicnet_startup_step apps magicnet_app_policy_apply_unlocked || return $?
        magicnet_startup_step warp magicnet_warp_apply_unlocked || return $?
        magicnet_singbox_apply_zashboard ||
            magicnet_warn "Failed to materialize the sing-box Zashboard panel; the core will continue without the panel rewrite."
        if [ -s "$MODDIR/.config/magicnet/config-override-active.json" ] || [ -s "$MODDIR/.state/override-materialization/checkpoint.json" ]; then
            magicnet_startup_step overrides magicnet_override_materialize_unlocked || return $?
        fi
        magicnet_startup_step auth magicnet_tailscale_inject_auth_key || return $?
    fi
    # A rollback/recovery starts the byte-exact snapshot without rewriting it.
    # The snapshot was already validated while its previous generation ran.
    magicnet_startup_step config-check magicnet_validate_singbox_transparent_config || {
        set -- "$?"
        [ "${MAGICNET_TRANSPARENT_RESTORED_CONFIG:-0}" = 1 ] ||
            magicnet_tailscale_scrub_auth_key >/dev/null 2>&1 || true
        return "$1"
    }
    import __singbox__
    # Absorb short TUN teardown or eBPF detachment windows inside one user
    # action. The shared launcher cleans a failed PID generation between
    # attempts, and callers can still override the bounded attempt count.
    if command -v magicnet_kernel_route_state_begin >/dev/null 2>&1; then
        magicnet_startup_step route-baseline magicnet_kernel_route_state_begin || {
            [ "${MAGICNET_TRANSPARENT_RESTORED_CONFIG:-0}" = 1 ] ||
                magicnet_tailscale_scrub_auth_key >/dev/null 2>&1 || true
            magicnet_kernel_route_report_result 2 || true
            return 2
        }
    fi
    _singbox_gomemlimit="$(magicnet_singbox_runtime_memory_limit)"
    if GOMEMLIMIT="$_singbox_gomemlimit" \
        MAGICNET_SINGBOX_START_ATTEMPTS="${MAGICNET_SINGBOX_START_ATTEMPTS:-3}" \
        magicnet_startup_step core-launch singbox_start; then
        :
    else
        set -- "$?"
        unset _singbox_gomemlimit
        [ "${MAGICNET_TRANSPARENT_RESTORED_CONFIG:-0}" = 1 ] ||
            magicnet_tailscale_scrub_auth_key >/dev/null 2>&1 || true
        return "$1"
    fi
    unset _singbox_gomemlimit
    if [ "${MAGICNET_TRANSPARENT_RESTORED_CONFIG:-0}" != 1 ]; then
        magicnet_tailscale_scrub_auth_key >/dev/null 2>&1 ||
            magicnet_warn "Failed to scrub the transient Tailscale auth key from config.json."
    fi
    if ! magicnet_singbox_running_has_nodes; then
        magicnet_warn "sing-box started but no proxy nodes were detected; stopping sing-box."
        singbox_stop >/dev/null 2>&1 || true
        magicnet_need_nodes_message sing-box
        return 1
    fi
    return 0
}

magicnet_start_singbox() {
    magicnet_with_sub_config_lock magicnet_start_singbox_unlocked
}

# Caller holds the startup/config lock. Failed initialization must detach our
# interception before removing its listener; otherwise netd still targets a dead
# port. If detachment fails, keep the listener and report recovery as incomplete.
magicnet_rollback_failed_start_unlocked() (
    if magicnet_kernel_running; then
        magicnet_prepare_network_for_core_stop || {
            magicnet_kernel_route_report_result 2 || true
            return 2
        }
        import __singbox__
        singbox_stop || {
            magicnet_kernel_route_report_result 2 || true
            return 2
        }
    else
        _rollback_core_rc=$?
        [ "$_rollback_core_rc" -eq 1 ] || return 2
    fi
    # Also handles a core that already exited during initialization. Final
    # cleanup verifies stopped identity and attempts every independent resource.
    magicnet_lifecycle_after_stop
)

magicnet_start_singbox_ready_unlocked() {
    if magicnet_start_singbox_unlocked; then
        :
    else
        _ready_start_rc=$?
        # Unknown identity is not permission to tear down another generation.
        [ "$_ready_start_rc" -ne 2 ] || return 2
        magicnet_rollback_failed_start_unlocked || return 2
        return 1
    fi
    # Capture the core's own rules BEFORE hotspot/DNS initialization. A failure
    # in those later phases must not leave only a prepared, unattributed ledger.
    if command -v magicnet_kernel_route_state_capture >/dev/null 2>&1; then
        if ! magicnet_startup_step route-capture magicnet_kernel_route_state_capture; then
            magicnet_kernel_route_report_result 2 || true
            magicnet_warn "Route ownership could not be verified; rolling back startup."
            magicnet_rollback_failed_start_unlocked || return 2
            return 2
        fi
    fi
    if magicnet_startup_step network-ready magicnet_after_kernel_start_unlocked; then
        magicnet_singbox_save_last_good ||
            magicnet_warn "Could not save the validated sing-box recovery checkpoint."
        return 0
    fi
    magicnet_warn "sing-box started but post-start network initialization failed"
    magicnet_rollback_failed_start_unlocked || return 2
    return 1
}

magicnet_start_singbox_ready() {
    magicnet_with_sub_config_lock magicnet_start_singbox_ready_unlocked
}

magicnet_kernel_running() {
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        if is_singbox_running >/dev/null 2>&1; then
            _kernel_status_rc=0
        else
            _kernel_status_rc=$?
        fi
        return "$_kernel_status_rc"
    fi

    return 1
}

magicnet_live_kernel_fast_path() {
    if magicnet_kernel_running; then
        _live_kernel_rc=0
    else
        _live_kernel_rc=$?
    fi
    case "$_live_kernel_rc" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
    esac
    [ "${MAGICNET_ALLOW_DISRUPTIVE_RECOVERY:-0}" != 1 ] || return 1
    if [ -d "${MODDIR}/.state/sing-box/subscription-transaction" ]; then
        magicnet_warn "A live sing-box core has pending subscription recovery; keeping the connection and deferring recovery until an explicit repair, update, or restart."
    fi
    return 0
}

magicnet_kernel_start_preamble() {
    magicnet_module_disabled && {
        magicnet_supervisors_stop >/dev/null 2>&1 || true
        return 1
    }
    if [ "${MAGICNET_TRANSPARENT_TRANSACTION_ACTIVE:-0}" != 1 ] &&
        [ -d "$(magicnet_transparent_transaction_dir)" ]; then
        # The interrupted target may already be running even though its journal
        # was never committed. Stop it before restoring the previous files so
        # the loaded dataplane cannot disagree with configured_mode.
        if magicnet_cmd_exists sing-box; then
            import __singbox__
            singbox_stop >/dev/null 2>&1 || return 1
        fi
        magicnet_hotspot_watchdog_stop >/dev/null 2>&1 || true
        magicnet_hotspot_route_cleanup >/dev/null 2>&1 || true
        magicnet_disable_dns_capture >/dev/null 2>&1 || true
        magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
        if ! magicnet_recover_interrupted_transparent_transaction; then
            magicnet_warn "Interrupted transparent mode transaction recovery failed"
            return 1
        fi
        MAGICNET_TRANSPARENT_RESTORED_CONFIG=1
        export MAGICNET_TRANSPARENT_RESTORED_CONFIG
    fi
    if magicnet_live_kernel_fast_path; then
        _preamble_live_rc=0
    else
        _preamble_live_rc=$?
    fi
    case "$_preamble_live_rc" in
    0) return 0 ;;
    1) ;;
    *)
        magicnet_warn "sing-box process discovery is indeterminate; startup preamble aborted."
        return 2
        ;;
    esac
    if command -v magicnet_recover_interrupted_subscription >/dev/null 2>&1 &&
        ! magicnet_recover_interrupted_subscription; then
        magicnet_warn "Interrupted subscription transaction recovery failed"
        return 1
    fi
    return 0
}

magicnet_start_kernel() {
    magicnet_detach_pid_from_app_cgroup "$$" ||
        magicnet_warn "Failed to detach the core launcher from the caller cgroup."
    magicnet_kernel_start_preamble || return $?
    if magicnet_kernel_running; then
        _kernel_running_rc=0
    else
        _kernel_running_rc=$?
    fi
    case "$_kernel_running_rc" in
    0) return 0 ;;
    1) ;;
    *)
        magicnet_warn "sing-box process discovery is indeterminate; network teardown and start aborted."
        return 2
        ;;
    esac

    magicnet_disable_dns_capture || true
    magicnet_disable_dns_leak_guard || true
    magicnet_require_subscription_or_stop || return 1

    if command -v magicnet_hotspot_startup_snapshot_prepare >/dev/null 2>&1; then
        magicnet_hotspot_startup_snapshot_prepare ||
            magicnet_warn "Hotspot discovery snapshot failed; falling back to live discovery."
    fi

    if magicnet_start_singbox_ready; then
        command -v magicnet_hotspot_startup_snapshot_clear >/dev/null 2>&1 &&
            magicnet_hotspot_startup_snapshot_clear
        magicnet_singbox_record_runtime_fingerprint ||
            magicnet_warn "Failed to record the running sing-box configuration fingerprint."
        # Startup already materialized hotspot policy before launching sing-box.
        # Replaying it through the full WebUI path can recursively apply config
        # and restart the core that is still starting.
        "${MODDIR}/cli" api replay-startup >/dev/null 2>&1 || true
        magicnet_notify "magicnet_guard" "MagicNet" "sing-box started"
        return 0
    else
        set -- "$?"
    fi

    command -v magicnet_hotspot_startup_snapshot_clear >/dev/null 2>&1 &&
        magicnet_hotspot_startup_snapshot_clear
    if ! magicnet_cmd_exists sing-box; then
        magicnet_warn "sing-box executable was not found."
    elif [ "${MAGIC_SINGBOX:-1}" -eq 0 ]; then
        magicnet_warn "sing-box startup is disabled by configuration."
    else
        magicnet_warn "sing-box startup failed; see the preceding core or network error."
    fi
    return "$1"
}

magicnet_ensure_kernel() {
    magicnet_kernel_start_preamble || return $?
    if magicnet_kernel_running; then
        _ensure_running_rc=0
    else
        _ensure_running_rc=$?
    fi
    case "$_ensure_running_rc" in
    0) return 0 ;;
    1) ;;
    *) return 2 ;;
    esac
    magicnet_require_subscription_or_stop || return 1
    MAGICNET_WATCHDOG=1 magicnet_start_kernel
}

magicnet_show_dashboard() {
    panel "MagicNet"
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        _singbox_state=$(magicnet_status_text is_singbox_running)
    else
        _singbox_state="Not installed"
    fi

    panel_row "sing-box" "$(magicnet_display_status "$_singbox_state")"
    _fswatch_pid=$(magicnet_fswatch_status)
    panel_row "fswatch" "$(magicnet_display_status "${_fswatch_pid:-Stopped}")"
    _webui_api="$(magicnet_singbox_api_endpoint 2>/dev/null || true)"
    if [ -n "$_webui_api" ]; then
        panel_row "WebUI" "${_webui_api}/ui/"
    else
        panel_row "WebUI" "$(i18n MAGICNET_UNAVAILABLE)"
    fi
    unset _webui_api
    if [ -s "${MODDIR}/.config/sing-box/subscription.local" ]; then
        panel_row "$(i18n MAGICNET_SUBSCRIPTION)" "$(i18n MAGICNET_LOCAL_FILE)"
    else
        panel_row "$(i18n MAGICNET_SUBSCRIPTION)" "${MODDIR}/.config/sing-box/subscription.url"
    fi
    panel_end
}
