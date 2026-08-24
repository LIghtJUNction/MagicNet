magicnet_tailscale_auth_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/tailscale-auth.json"
}

magicnet_tailscale_apply_unlocked() (
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || return 1
    _auth="$(magicnet_tailscale_auth_file)"
    _state="${MODDIR}/.state/sing-box/tailscale"
    _tmp="${_config}.tailscale.new"
    _new_auth="${_auth}.new"
    _merged_auth="${_auth}.merged"
    _old_umask="$(umask)"
    umask 077
    trap 'rm -f "$_tmp" "$_new_auth" "$_merged_auth"; umask "$_old_umask"' 0
    mkdir -p "$_state" "${_auth%/*}" || return 1
    chmod 700 "$_state" "${_auth%/*}" 2>/dev/null || true

    "$_jq" '
      reduce (.endpoints[]?
        | select(.type == "tailscale" and (.tag // "") != "" and (.auth_key // "") != "")) as $endpoint
        ({}; .[$endpoint.tag] = $endpoint.auth_key)
    ' "$_config" >"$_new_auth" || {
        rm -f "$_new_auth"
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
      if has("endpoints") then
        .endpoints = ((.endpoints // []) | map(
          if .type == "tailscale" then
            del(.auth_key)
            | if (.state_directory // "") == "" then .state_directory = $state_dir else . end
            | .system_interface = false
          else . end
        ))
      else . end
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
    ' "$_config" >"$_tmp" || {
        rm -f "$_tmp" "$_new_auth" "$_merged_auth"
        return 1
    }
    if ! chmod 600 "$_tmp" || ! mv -f "$_tmp" "$_config" || ! chmod 600 "$_config"; then
        rm -f "$_tmp" "$_new_auth" "$_merged_auth"
        return 1
    fi
    umask "$_old_umask"
    trap - 0
    unset _config _jq _auth _state _tmp _new_auth _merged_auth _old_umask
)

magicnet_tailscale_inject_auth_key() {
    _config="${MODDIR}/.config/sing-box/config.json"
    _auth="$(magicnet_tailscale_auth_file)"
    [ -s "$_auth" ] || return 0
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || return 1
    _tmp="${_config}.tailscale-auth.new"
    (
        umask 077
        "$_jq" --slurpfile auth "$_auth" '
      ($auth[0] // {}) as $keys
      | .endpoints = ((.endpoints // []) | map(
          if .type == "tailscale" and ($keys[.tag] // "") != "" then
            .auth_key = $keys[.tag]
          else . end
        ))
    ' "$_config" >"$_tmp"
    ) || {
        rm -f "$_tmp"
        return 1
    }
    if ! chmod 600 "$_tmp" || ! mv -f "$_tmp" "$_config" || ! chmod 600 "$_config"; then
        rm -f "$_tmp"
        return 1
    fi
    unset _config _auth _jq _tmp
}

magicnet_tailscale_scrub_auth_key() {
    _config="${MODDIR}/.config/sing-box/config.json"
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || return 1
    _tmp="${_config}.tailscale-scrub.new"
    (
        umask 077
        "$_jq" '
        if has("endpoints") then
            .endpoints = ((.endpoints // []) | map(if .type == "tailscale" then del(.auth_key) else . end))
            | if (.endpoints | length) == 0 then del(.endpoints) else . end
        else . end
    ' "$_config" >"$_tmp"
    ) &&
        chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config"
    _rc=$?
    unset _config _jq _tmp
    return "$_rc"
}

magicnet_singbox_runtime_fingerprint_file() {
    printf '%s\n' "${MODDIR}/.state/sing-box/runtime-fingerprint"
}

# Record only inputs consumed by the running sing-box process.  User-facing
# policy files are materialized into config.json before this is called, while
# UI assets, subscription caches and other mutable runtime files must not
# force a core restart and disconnect every long-lived application socket.
magicnet_singbox_runtime_fingerprint() (
    _runtime_root="${MODDIR}/.config/sing-box"
    _runtime_config="${_runtime_root}/config.json"
    [ -f "$_runtime_config" ] || return 1
    _runtime_jq="${MODDIR}/bin/jq"
    [ -x "$_runtime_jq" ] || return 1
    command -v cksum >/dev/null 2>&1 || return 1
    command -v find >/dev/null 2>&1 || return 1
    command -v sort >/dev/null 2>&1 || return 1

    {
        # Runtime materializers may emit equivalent JSON with a different key
        # order or whitespace.  sing-box sees the same configuration in that
        # case, so hash a stable representation instead of the file bytes.
        "$_runtime_jq" -e . "$_runtime_config" >/dev/null || exit 1
        "$_runtime_jq" -S -c . "$_runtime_config" | cksum || exit 1
        if [ -f "${_runtime_root}/tailscale-auth.json" ]; then
            "$_runtime_jq" -e . "${_runtime_root}/tailscale-auth.json" >/dev/null || exit 1
            "$_runtime_jq" -S -c . "${_runtime_root}/tailscale-auth.json" | cksum || exit 1
        fi
        if [ -d "${_runtime_root}/rules" ]; then
            find "${_runtime_root}/rules" -type f -name '*.srs' -print 2>/dev/null |
                sort |
                while IFS= read -r _runtime_rule || [ -n "$_runtime_rule" ]; do
                    [ -n "$_runtime_rule" ] || continue
                    cksum "$_runtime_rule" || exit 1
                done
        fi
    } | cksum | awk '{ print $1 ":" $2 }'
)

magicnet_singbox_record_runtime_fingerprint() {
    _runtime_fingerprint_file="$(magicnet_singbox_runtime_fingerprint_file)"
    _runtime_fingerprint_dir=${_runtime_fingerprint_file%/*}
    _runtime_fingerprint_tmp="${_runtime_fingerprint_file}.new.$$"
    mkdir -p "$_runtime_fingerprint_dir" || return 1
    (
        umask 077
        magicnet_singbox_runtime_fingerprint >"$_runtime_fingerprint_tmp"
    ) || {
        rm -f "$_runtime_fingerprint_tmp" 2>/dev/null || true
        unset _runtime_fingerprint_file _runtime_fingerprint_dir _runtime_fingerprint_tmp
        return 1
    }
    chmod 600 "$_runtime_fingerprint_tmp" &&
        mv -f "$_runtime_fingerprint_tmp" "$_runtime_fingerprint_file" &&
        chmod 600 "$_runtime_fingerprint_file"
    _runtime_fingerprint_rc=$?
    [ "$_runtime_fingerprint_rc" -eq 0 ] || rm -f "$_runtime_fingerprint_tmp" 2>/dev/null || true
    set -- "$_runtime_fingerprint_rc"
    unset _runtime_fingerprint_file _runtime_fingerprint_dir _runtime_fingerprint_tmp _runtime_fingerprint_rc
    return "$1"
}

magicnet_singbox_runtime_fingerprint_matches() {
    _runtime_fingerprint_file="$(magicnet_singbox_runtime_fingerprint_file)"
    [ -s "$_runtime_fingerprint_file" ] || {
        unset _runtime_fingerprint_file
        return 1
    }
    _runtime_fingerprint="$(magicnet_singbox_runtime_fingerprint)" || {
        unset _runtime_fingerprint_file _runtime_fingerprint
        return 1
    }
    grep -F -x "$_runtime_fingerprint" "$_runtime_fingerprint_file" >/dev/null 2>&1
    _runtime_fingerprint_rc=$?
    set -- "$_runtime_fingerprint_rc"
    unset _runtime_fingerprint_file _runtime_fingerprint
    unset _runtime_fingerprint_rc
    return "$1"
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
    magicnet_singbox_chain_apply || _runtime_rc=1
    magicnet_singbox_apply_zashboard || _runtime_rc=1
    magicnet_dns_apply_unlocked || _runtime_rc=1
    magicnet_transparent_apply_unlocked || _runtime_rc=1
    magicnet_app_policy_apply_unlocked || _runtime_rc=1
    magicnet_warp_apply_unlocked || _runtime_rc=1
    magicnet_route_apply_unlocked || _runtime_rc=1
    magicnet_block_apply_unlocked || _runtime_rc=1
    magicnet_tailscale_apply_unlocked || _runtime_rc=1
    # Runtime policy writers rebuild selector objects. Normalize route-level
    # sing-box fields afterwards so a no-op apply remains byte-equivalent to
    # the configuration used by the running core.
    import __singbox__ &&
        singbox_prepare_route_config "$(magicnet_singbox_config_file)" || _runtime_rc=1
    magicnet_wifi_policy_start || _runtime_rc=1
    if magicnet_kernel_running; then
        magicnet_enable_dns_capture || _runtime_rc=1
        magicnet_enable_dns_leak_guard || _runtime_rc=1
        if [ "$_runtime_rc" -ne 0 ]; then
            # A partial DNS-control install is not a safe steady state.  Do
            # not leave capture or leak-guard rules enabled after any other
            # runtime materialization step reported failure.
            magicnet_disable_dns_capture || true
            magicnet_disable_dns_leak_guard || true
        fi
    else
        magicnet_disable_dns_capture || true
        magicnet_disable_dns_leak_guard || true
    fi
    return "$_runtime_rc"
}

magicnet_apply_runtime_config() {
    magicnet_with_config_lock magicnet_apply_runtime_config_unlocked
}
