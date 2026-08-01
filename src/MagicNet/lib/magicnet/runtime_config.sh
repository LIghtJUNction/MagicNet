magicnet_tailscale_auth_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/tailscale-auth.json"
}

magicnet_tailscale_apply_unlocked() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || _jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_jq" ] || return 1
    _auth="$(magicnet_tailscale_auth_file)"
    _state="${MODDIR}/.state/sing-box/tailscale"
    _tmp="${_config}.tailscale.new"
    _new_auth="${_auth}.new"
    _merged_auth="${_auth}.merged"
    _old_umask="$(umask)"
    umask 077
    mkdir -p "$_state" "${_auth%/*}" || return 1
    chmod 700 "$_state" "${_auth%/*}" 2>/dev/null || true

    "$_jq" '
      reduce (.endpoints[]?
        | select(.type == "tailscale" and (.tag // "") != "" and (.auth_key // "") != "")) as $endpoint
        ({}; .[$endpoint.tag] = $endpoint.auth_key)
    ' "$_config" >"$_new_auth" || {
        rm -f "$_new_auth"
        umask "$_old_umask"
        return 1
    }
    if [ "$("$_jq" 'length' "$_new_auth" 2>/dev/null)" -gt 0 ]; then
        if [ -s "$_auth" ]; then
            "$_jq" -s '.[0] * .[1]' "$_auth" "$_new_auth" >"$_merged_auth" || return 1
            mv -f "$_merged_auth" "$_auth" || return 1
        else
            mv -f "$_new_auth" "$_auth" || return 1
        fi
        chmod 600 "$_auth" || return 1
    else
        rm -f "$_new_auth"
    fi

    "$_jq" --arg state_dir "$_state" '
      def tailnets: ["100.64.0.0/10", "fd7a:115c:a1e0::/48"];
      def userspace_tailscale:
        .type == "tailscale"
          and (.tag // "") != ""
          and ((.system_interface // false) == false);
      def managed_tailnet_rule:
        (((.ip_cidr // []) | sort) == (tailnets | sort))
          and ((.outbound // "") != "lan");
      .endpoints = ((.endpoints // []) | map(
        if .type == "tailscale" then
          del(.auth_key)
          | if (.state_directory // "") == "" then .state_directory = $state_dir else . end
          | .system_interface = false
        else . end
      ))
      | ((.endpoints // []) | map(select(userspace_tailscale)) | first) as $endpoint
      | if $endpoint == null then . else
          .inbounds = ((.inbounds // []) | map(
            if .type == "tun" and (.tag // "") == "tun-in" then
              .route_exclude_address = ((.route_exclude_address // []) - tailnets)
            else . end
          ))
          | ((.route.rules // [])
              | map(
                  if (.outbound // "") == "lan" and ((.ip_cidr // null) | type) == "array" then
                    .ip_cidr = (.ip_cidr - tailnets)
                  else . end
                )
              | map(select((has("ip_cidr") and .ip_cidr == []) | not))
              | map(select(managed_tailnet_rule | not))) as $rules
          | (([$rules | to_entries[] | select((.value.outbound // "") == "lan") | .key] | first) // ($rules | length)) as $at
          | .route.rules = ($rules[:$at] + [{"ip_cidr": tailnets, "outbound": $endpoint.tag}] + $rules[$at:])
        end
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config" || {
        rm -f "$_tmp" "$_new_auth" "$_merged_auth"
        umask "$_old_umask"
        return 1
    }
    chmod 600 "$_config" 2>/dev/null || true
    umask "$_old_umask"
    unset _config _jq _auth _state _tmp _new_auth _merged_auth _old_umask
}

magicnet_tailscale_inject_auth_key() {
    _config="${MODDIR}/.config/sing-box/config.json"
    _auth="$(magicnet_tailscale_auth_file)"
    [ -s "$_auth" ] || return 0
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || _jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_jq" ] || return 1
    _tmp="${_config}.tailscale-auth.new"
    (umask 077; "$_jq" --slurpfile auth "$_auth" '
      ($auth[0] // {}) as $keys
      | .endpoints = ((.endpoints // []) | map(
          if .type == "tailscale" and ($keys[.tag] // "") != "" then
            .auth_key = $keys[.tag]
          else . end
        ))
    ' "$_config" >"$_tmp") && mv -f "$_tmp" "$_config" || {
        rm -f "$_tmp"
        return 1
    }
    chmod 600 "$_config" 2>/dev/null || true
    unset _config _auth _jq _tmp
}

magicnet_tailscale_scrub_auth_key() {
    _config="${MODDIR}/.config/sing-box/config.json"
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || _jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_jq" ] || return 1
    _tmp="${_config}.tailscale-scrub.new"
    (umask 077; "$_jq" '.endpoints = ((.endpoints // []) | map(if .type == "tailscale" then del(.auth_key) else . end))' "$_config" >"$_tmp") &&
        mv -f "$_tmp" "$_config"
    _rc=$?
    [ "$_rc" -eq 0 ] && chmod 600 "$_config" 2>/dev/null || true
    unset _config _jq _tmp
    return "$_rc"
}

magicnet_apply_runtime_config_unlocked() {
    if magicnet_module_disabled; then
        magicnet_supervisors_stop >/dev/null 2>&1 || true
        magicnet_disable_dns_capture >/dev/null 2>&1 || true
        magicnet_disable_dns_leak_guard >/dev/null 2>&1 || true
        return 0
    fi
    _runtime_rc=0
    magicnet_ipset_lkm_prepare || true
    magicnet_singbox_apply_zashboard
    magicnet_dns_apply_unlocked || _runtime_rc=1
    magicnet_transparent_apply_unlocked || _runtime_rc=1
    magicnet_app_policy_apply_unlocked || _runtime_rc=1
    magicnet_warp_apply_unlocked || _runtime_rc=1
    magicnet_route_apply_unlocked || _runtime_rc=1
    magicnet_block_apply_unlocked || _runtime_rc=1
    magicnet_tailscale_apply_unlocked || _runtime_rc=1
    magicnet_wifi_policy_start || _runtime_rc=1
    if magicnet_kernel_running; then
        magicnet_enable_dns_capture || true
        magicnet_enable_dns_leak_guard || true
    else
        magicnet_disable_dns_capture || true
        magicnet_disable_dns_leak_guard || true
    fi
    return "$_runtime_rc"
}

magicnet_apply_runtime_config() {
    magicnet_with_config_lock magicnet_apply_runtime_config_unlocked
}
