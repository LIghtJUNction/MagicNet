magicnet_status_text() {
    if "$1" >/dev/null 2>&1; then
        printf '%s\n' "Running"
    else
        printf '%s\n' "Stopped"
    fi
}

magicnet_refresh_status() {
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        is_singbox_running >/dev/null 2>&1 && return 0
    fi

    config set override.description "[MagicNet]: No kernel running" 2>/dev/null || true
}

magicnet_start_singbox_unlocked() {
    magicnet_module_disabled && return 1
    [ "${MAGIC_SINGBOX:-1}" -ne 0 ] || return 1
    magicnet_cmd_exists sing-box || return 1
    import __singbox__
    is_singbox_running >/dev/null 2>&1 && return 0
    magicnet_prepare_singbox_nodes_unlocked || return 1
    magicnet_singbox_chain_apply || return 1
    magicnet_singbox_apply_transparent_mode || return 1
    magicnet_singbox_apply_hotspot_policy || return 1
    # sing-box snapshots DNS servers and WARP endpoints when the process
    # starts.  Applying these only in the post-start rewrite made a fresh
    # start report success while the running core still held the old config.
    magicnet_dns_apply_unlocked || return 1
    magicnet_tailscale_apply_unlocked || return 1
    # The preceding normalizers rebuild the managed TUN inbound.  Materialize
    # per-app UID boundaries after all of them and before sing-box starts; a
    # deferred rewrite cannot change the already-running core's in-memory routes.
    magicnet_app_policy_apply_unlocked || return 1
    magicnet_warp_apply_unlocked || return 1
    # The running core snapshots clash_api.external_ui at process start.  A
    # post-start rewrite only dirties config.json and cannot affect that core.
    magicnet_singbox_apply_zashboard ||
        magicnet_warn "Failed to materialize the sing-box Zashboard panel; the core will continue without the panel rewrite."
    magicnet_tailscale_inject_auth_key || return 1
    import __singbox__
    if ! singbox_start; then
        magicnet_tailscale_scrub_auth_key >/dev/null 2>&1 || true
        return 1
    fi
    magicnet_tailscale_scrub_auth_key >/dev/null 2>&1 ||
        magicnet_warn "Failed to scrub the transient Tailscale auth key from config.json."
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

magicnet_start_singbox_ready_unlocked() {
    magicnet_start_singbox_unlocked || return 1
    # Keep core materialization, process readiness, and the kernel controls
    # that target this exact generation under one lock acquisition.  Releasing
    # and reacquiring here let fswatch win the gap and made manual startup wait
    # behind a redundant config apply.
    if magicnet_after_kernel_start_unlocked; then
        return 0
    fi
    import __singbox__
    singbox_stop >/dev/null 2>&1 || true
    magicnet_warn "sing-box started but post-start network initialization failed"
    return 1
}

magicnet_start_singbox_ready() {
    magicnet_with_sub_config_lock magicnet_start_singbox_ready_unlocked
}

magicnet_kernel_running() {
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        is_singbox_running >/dev/null 2>&1 && return 0
    fi

    return 1
}

magicnet_live_kernel_fast_path() {
    magicnet_kernel_running || return 1
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
    magicnet_live_kernel_fast_path && return 0
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
    magicnet_kernel_start_preamble || return 1
    if magicnet_kernel_running; then
        return 0
    fi

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
        "${MODDIR}/cli" api replay-startup >/dev/null 2>&1 ||
        magicnet_warn "Persisted selector or hotspot policy replay was incomplete."
        magicnet_notify "magicnet_guard" "MagicNet" "sing-box started"
        return 0
    fi

    command -v magicnet_hotspot_startup_snapshot_clear >/dev/null 2>&1 &&
        magicnet_hotspot_startup_snapshot_clear
    magicnet_warn "No supported sing-box core found or starting is disabled."
    return 1
}

magicnet_ensure_kernel() {
    magicnet_kernel_start_preamble || return 1
    magicnet_kernel_running && return 0
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

    panel_row "sing-box" "$_singbox_state"
    _fswatch_pid=$(magicnet_fswatch_status)
    panel_row "fswatch" "${_fswatch_pid:-Stopped}"
    panel_row "WebUI" "http://127.0.0.1:9090/ui/"
    if [ -s "${MODDIR}/.config/sing-box/subscription.local" ]; then
        panel_row "sing-box subscription" "local file"
    else
        panel_row "sing-box subscription" "${MODDIR}/.config/sing-box/subscription.url"
    fi
    panel_end
}
