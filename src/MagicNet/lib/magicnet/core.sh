magicnet_status_text() {
    if "$1" >/dev/null 2>&1; then
        printf '%s\n' "Running"
    else
        printf '%s\n' "Stopped"
    fi
}

magicnet_refresh_status() {
    if ! magicnet_singbox_disabled && magicnet_cmd_exists sing-box; then
        import __singbox__
        is_singbox_running >/dev/null 2>&1 && return 0
    fi

    if magicnet_cmd_exists mihomo; then
        import __mihomo__
        is_mihomo_running >/dev/null 2>&1 && return 0
    fi

    config set override.description "[MagicNet]: No kernel running" 2>/dev/null || true
}

magicnet_start_mihomo() {
    [ "${MAGIC_MIHOMO:-1}" -ne 0 ] || return 1
    magicnet_cmd_exists mihomo || return 1
    magicnet_prepare_mihomo_nodes || return 1
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        if is_singbox_running >/dev/null 2>&1; then
            magicnet_warn "Stopping sing-box before starting mihomo..."
            singbox_stop || return 1
        fi
    fi
    import __mihomo__
    mihomo_start || return 1
    if ! magicnet_mihomo_running_has_nodes; then
        magicnet_warn "mihomo started but no proxy nodes were detected; stopping mihomo."
        mihomo_stop >/dev/null 2>&1 || true
        magicnet_need_nodes_message mihomo
        return 1
    fi
    return 0
}

magicnet_start_singbox() {
    [ "${MAGIC_SINGBOX:-1}" -ne 0 ] || return 1
    ! magicnet_singbox_disabled || return 1
    magicnet_cmd_exists sing-box || return 1
    magicnet_prepare_singbox_nodes || return 1
    if magicnet_cmd_exists mihomo; then
        import __mihomo__
        if is_mihomo_running >/dev/null 2>&1; then
            magicnet_warn "Stopping mihomo before starting sing-box..."
            mihomo_stop || return 1
        fi
    fi
    import __singbox__
    singbox_start || return 1
    if ! magicnet_singbox_running_has_nodes; then
        magicnet_warn "sing-box started but no proxy nodes were detected; stopping sing-box."
        singbox_stop >/dev/null 2>&1 || true
        magicnet_need_nodes_message sing-box
        return 1
    fi
    return 0
}

magicnet_kernel_running() {
    if ! magicnet_singbox_disabled && magicnet_cmd_exists sing-box; then
        import __singbox__
        is_singbox_running >/dev/null 2>&1 && return 0
    fi

    if magicnet_cmd_exists mihomo; then
        import __mihomo__
        is_mihomo_running >/dev/null 2>&1 && return 0
    fi

    return 1
}

magicnet_start_kernel() {
    if magicnet_kernel_running; then
        magicnet_supervisors_start
        return 0
    fi

    _preferred_core="$(magicnet_preferred_core)"
    case "$_preferred_core" in
        mihomo)
            if magicnet_start_mihomo; then
                magicnet_after_kernel_start
                magicnet_notify "magicnet_guard" "MagicNet" "mihomo restarted by watchdog"
                magicnet_supervisors_start
                unset _preferred_core
                return 0
            fi
            magicnet_warn "mihomo failed to start; attempting sing-box fallback..."
            if magicnet_start_singbox; then
                magicnet_after_kernel_start
                magicnet_notify "magicnet_guard" "MagicNet" "sing-box restarted by watchdog"
                magicnet_supervisors_start
                unset _preferred_core
                return 0
            fi
            ;;
        *)
            if magicnet_start_singbox; then
                magicnet_after_kernel_start
                magicnet_notify "magicnet_guard" "MagicNet" "sing-box restarted by watchdog"
                magicnet_supervisors_start
                unset _preferred_core
                return 0
            fi
            if [ "${MAGIC_SINGBOX:-1}" -ne 0 ] && ! magicnet_singbox_disabled; then
                magicnet_warn "sing-box failed to start; attempting mihomo fallback..."
            fi
            if magicnet_start_mihomo; then
                magicnet_after_kernel_start
                magicnet_notify "magicnet_guard" "MagicNet" "mihomo restarted by watchdog"
                magicnet_supervisors_start
                unset _preferred_core
                return 0
            fi
            ;;
    esac
    unset _preferred_core

    magicnet_warn "No supported kernel found or starting disabled (mihomo or sing-box)."
    return 1
}

magicnet_ensure_kernel() {
    magicnet_kernel_running && return 0
    MAGICNET_WATCHDOG=1 magicnet_start_kernel
}

magicnet_show_dashboard() {
    panel "MagicNet"
    if magicnet_cmd_exists sing-box; then
        import __singbox__
        if magicnet_singbox_disabled; then
            _singbox_state="Disabled by .disable_sing_box"
        else
            _singbox_state=$(magicnet_status_text is_singbox_running)
        fi
    else
        _singbox_state="Not installed"
    fi

    if magicnet_cmd_exists mihomo; then
        import __mihomo__
        _mihomo_state=$(magicnet_status_text is_mihomo_running)
    else
        _mihomo_state="Not installed"
    fi

    panel_row "sing-box" "$_singbox_state"
    panel_row "mihomo" "$_mihomo_state"
    _watchdog_pid=$(magicnet_watchdog_status)
    panel_row "watchdog" "${_watchdog_pid:-Stopped}"
    _fswatch_pid=$(magicnet_fswatch_status)
    panel_row "fswatch" "${_fswatch_pid:-Stopped}"
    panel_row "WebUI" "http://127.0.0.1:9090/ui/"
    panel_row "sing-box subscription" "${MODDIR}/.config/sing-box/subscription.url"
    panel_end
}
