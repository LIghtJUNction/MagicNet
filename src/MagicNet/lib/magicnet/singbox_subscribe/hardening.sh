# shellcheck shell=ash
#
# Device-validated Google Play fallback plus resilient Google/Gemini routing.
#
# Keep the Go runtime on a bounded heap by default. GOMEMLIMIT is a soft runtime
# memory target rather than an RLIMIT, so sing-box can still allocate what it
# needs under pressure while avoiding an unnecessarily large steady-state heap.
: "${MAGICNET_SINGBOX_GOMEMLIMIT:=96MiB}"
export GOMEMLIMIT="$MAGICNET_SINGBOX_GOMEMLIMIT"

magicnet_singbox_google_reliability_patch() {
    _google_config="$1"
    _google_jq="$(magicnet_jq)" || return 1
    _google_tmp="${_google_config}.google-reliability.$$"
    rm -f "$_google_tmp" 2>/dev/null || true

    if ! "$_google_jq" '
      def packages:
        if ((.package_name? // null) | type) == "array" then .package_name
        elif ((.package_name? // null) | type) == "string" then [.package_name]
        else [] end;
      def has_package($name): (packages | index($name)) != null;
      def is_google_play_service:
        has_package("com.android.vending")
          or has_package("com.google.android.gms")
          or has_package("com.google.android.gsf");
      def is_gemini_rule:
        has_package("com.google.android.apps.bard")
          or (((.rule_set? // []) | if type == "array" then . else [.] end)
              | index("meta-google-gemini")) != null;
      def append_once($items; $value):
        reduce (($items // []) + [$value])[] as $item
          ([]; if index($item) then . else . + [$item] end);

      ([.outbounds[]? | select(.tag == "proxy-auto" and .type == "urltest")][0] // null) as $proxy_auto
      | if $proxy_auto != null then
          .outbounds = (
            ((.outbounds // []) | map(select(.tag != "magicnet-google-auto")))
            + [{
                "type": "urltest",
                "tag": "magicnet-google-auto",
                "outbounds": append_once(($proxy_auto.outbounds // []); "direct"),
                "url": "https://www.google.com/generate_204",
                "interval": "2m",
                "tolerance": 50,
                "idle_timeout": "10m",
                "interrupt_exist_connections": true
              }]
          )
          | .outbounds = (.outbounds | map(
              if (.tag? == "google-proxy" and .type? == "selector") then
                .outbounds = append_once(.outbounds; "magicnet-google-auto")
                | if .default? == "proxy" then .default = "magicnet-google-auto" else . end
              else . end))
        else . end
      | .outbounds = ((.outbounds // []) | map(
          if (.tag? == "ai-gemini-auto" and .type? == "urltest") then
            .outbounds = append_once(.outbounds; "direct")
          else . end))
      | .route.rules = ((.route.rules // []) | map(
          if (is_google_play_service
              and ((.outbound? == "google-proxy") or (.outbound? == "proxy"))) then
            .outbound = "direct"
          elif (is_gemini_rule and .outbound? == "ai-gemini") then
            .outbound = "ai-gemini-auto"
          else . end))
    ' "$_google_config" >"$_google_tmp"; then
        rm -f "$_google_tmp" 2>/dev/null || true
        return 1
    fi

    chmod 600 "$_google_tmp" 2>/dev/null || true
    magicnet_singbox_recovery_config_valid "$_google_tmp" || {
        rm -f "$_google_tmp" 2>/dev/null || true
        return 1
    }

    if cmp -s "$_google_config" "$_google_tmp" 2>/dev/null; then
        rm -f "$_google_tmp" 2>/dev/null || true
        printf '%s\n' unchanged
        return 0
    fi

    mv -f "$_google_tmp" "$_google_config" || {
        rm -f "$_google_tmp" 2>/dev/null || true
        return 1
    }
    chmod 600 "$_google_config" 2>/dev/null || true
    printf '%s\n' changed
}

# Compatibility name used by the v1.5.1 regression and older callers. The
# implementation now covers the whole Google reliability policy, not only Play.
magicnet_singbox_google_play_direct_fallback_patch() {
    magicnet_singbox_google_reliability_patch "$@"
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
    _verify_google_patch="$(magicnet_singbox_google_reliability_patch "$_verify_config")" || {
        error "Failed to apply the Google service reliability policy safely"
        unset _verify_config _verify_google_patch
        return 1
    }
    if [ "$_verify_google_patch" = changed ]; then
        warn "Google service reliability policy updated (Play direct fallback; Google/Gemini auto routing)"
    fi
    unset _verify_config _verify_google_patch
    _magicnet_singbox_verify_subscription_ready_base
}
