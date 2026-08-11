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
    _old_lock_timeout="${MAGICNET_CONFIG_LOCK_TIMEOUT:-}"
    MAGICNET_CONFIG_LOCK_TIMEOUT="${MAGICNET_SUB_CONFIG_LOCK_TIMEOUT:-45}"
    magicnet_with_config_lock magicnet_start_singbox_unlocked
    _start_rc=$?
    if [ -n "$_old_lock_timeout" ]; then
        MAGICNET_CONFIG_LOCK_TIMEOUT="$_old_lock_timeout"
    else
        unset MAGICNET_CONFIG_LOCK_TIMEOUT
    fi
    unset _old_lock_timeout
    return "$_start_rc"
}

magicnet_kernel_running() {
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        is_singbox_running >/dev/null 2>&1 && return 0
    fi

    return 1
}

magicnet_start_kernel() {
    magicnet_module_disabled && {
        magicnet_supervisors_stop >/dev/null 2>&1 || true
        return 1
    }
    if magicnet_kernel_running; then
        return 0
    fi

    magicnet_disable_dns_capture || true
    magicnet_disable_dns_leak_guard || true
    magicnet_require_subscription_or_stop || return 1

    if magicnet_start_singbox; then
        # The post-start phase installs DNS interception and leak guards.  It
        # used to run detached, so callers could immediately issue dns.test or
        # open the WebUI while the runtime was only half initialized.  Keep
        # startup fail-closed and report the real readiness result.
        if ! magicnet_after_kernel_start; then
            # Do not leave a half-initialized core running: the next start
            # attempt would otherwise hit magicnet_kernel_running and report
            # success without ever retrying DNS/TUN materialization.
            import __singbox__
            singbox_stop >/dev/null 2>&1 || true
            magicnet_warn "sing-box started but post-start network initialization failed"
            return 1
        fi
        magicnet_singbox_record_runtime_fingerprint ||
            magicnet_warn "Failed to record the running sing-box configuration fingerprint."
        "${MODDIR}/cli" api replay >/dev/null 2>&1 || true
        magicnet_notify "magicnet_guard" "MagicNet" "sing-box started"
        return 0
    fi

    magicnet_warn "No supported sing-box core found or starting is disabled."
    return 1
}

magicnet_ensure_kernel() {
    magicnet_module_disabled && {
        magicnet_supervisors_stop >/dev/null 2>&1 || true
        return 1
    }
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
