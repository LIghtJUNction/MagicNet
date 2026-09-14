# shellcheck shell=ash
#
# Device-validated Google Play package fallback.
# Ordinary Google/YouTube domain routing continues to use maintained selectors.

magicnet_singbox_google_play_direct_fallback_patch() {
    _play_config="$1"
    _play_jq="$(magicnet_jq)" || return 1
    _play_tmp="${_play_config}.google-play-direct.$$"
    rm -f "$_play_tmp" 2>/dev/null || true

    if ! "$_play_jq" -e '
      def packages:
        if ((.package_name? // null) | type) == "array" then .package_name
        elif ((.package_name? // null) | type) == "string" then [.package_name]
        else [] end;
      def is_google_play_service:
        packages as $packages
        | (($packages | index("com.android.vending")) != null
          or ($packages | index("com.google.android.gms")) != null
          or ($packages | index("com.google.android.gsf")) != null);
      any(.route.rules[]?;
        is_google_play_service
        and ((.outbound? == "google-proxy") or (.outbound? == "proxy")))
    ' "$_play_config" >/dev/null 2>&1; then
        printf '%s\n' unchanged
        return 0
    fi

    if ! "$_play_jq" '
      def packages:
        if ((.package_name? // null) | type) == "array" then .package_name
        elif ((.package_name? // null) | type) == "string" then [.package_name]
        else [] end;
      def is_google_play_service:
        packages as $packages
        | (($packages | index("com.android.vending")) != null
          or ($packages | index("com.google.android.gms")) != null
          or ($packages | index("com.google.android.gsf")) != null);
      .route.rules = ((.route.rules // []) | map(
        if (is_google_play_service
            and ((.outbound? == "google-proxy") or (.outbound? == "proxy")))
        then .outbound = "direct"
        else . end))
    ' "$_play_config" >"$_play_tmp"; then
        rm -f "$_play_tmp" 2>/dev/null || true
        return 1
    fi

    chmod 600 "$_play_tmp" 2>/dev/null || true
    magicnet_singbox_recovery_config_valid "$_play_tmp" || {
        rm -f "$_play_tmp" 2>/dev/null || true
        return 1
    }
    mv -f "$_play_tmp" "$_play_config" || {
        rm -f "$_play_tmp" 2>/dev/null || true
        return 1
    }
    chmod 600 "$_play_config" 2>/dev/null || true
    printf '%s\n' changed
}

# Wrap the existing activation check rather than replacing its process-state
# semantics. The generated candidate is patched and core-validated before the
# normal activation/restart path observes it.
_magicnet_singbox_verify_subscription_ready_base() {
    if magicnet_singbox_is_running "$(magicnet_singbox_subscription_config_file)"; then
        _verify_running_rc=0
    else
        _verify_running_rc=$?
    fi
    if [ "$_verify_running_rc" -eq 0 ]; then
        magicnet_singbox_restart_if_running || {
            error "sing-box restart failed after subscription update"
            return 1
        }
        magicnet_singbox_api_has_nodes || {
            warn "sing-box API did not expose proxy nodes; generated config contains nodes"
        }
        magicnet_singbox_google_works || {
            warn "sing-box proxy test failed: https://www.google.com is not reachable"
        }
        return 0
    fi
    if [ "$_verify_running_rc" -eq 2 ]; then
        error "sing-box process state is indeterminate; subscription activation aborted"
        return 2
    fi
    magicnet_singbox_config_has_nodes || {
        error "sing-box generated config contains no proxy nodes"
        return 1
    }
}

magicnet_singbox_verify_subscription_ready() {
    _verify_config="$(magicnet_singbox_subscription_config_file)"
    _verify_fallback="$(magicnet_singbox_google_play_direct_fallback_patch "$_verify_config")" || {
        error "Failed to apply the Google Play direct fallback safely"
        unset _verify_config _verify_fallback
        return 1
    }
    if [ "$_verify_fallback" = changed ]; then
        warn "Google Play/GMS package traffic is using the verified direct fallback"
    fi
    unset _verify_config _verify_fallback
    _magicnet_singbox_verify_subscription_ready_base
}
