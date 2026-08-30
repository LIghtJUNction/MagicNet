magicnet_app_policy_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_app_policy_mode() {
    _app_mode="$(magicnet_conf_value "$(magicnet_app_policy_dir)/app-mode.conf" MAGICNET_APP_MODE 2>/dev/null || true)"
    [ -n "$_app_mode" ] || _app_mode="${MAGICNET_APP_MODE:-}"
    case "$_app_mode" in
    whitelist) printf '%s\n' "whitelist" ;;
    *) printf '%s\n' "blacklist" ;;
    esac
    unset _app_mode
}

# App package policy is NOT the primary domestic/foreign split.
# - Blacklist mode: most apps enter TUN; geosite/geoip (+ domain lists) choose cn-direct vs proxy.
# - app-bypass.list: multi-VPN coexistence and optional user opt-outs only.
# - app-direct.list: keep selected packages in TUN but force the direct outbound.
# - app-proxy.list: force selected packages onto MagicNet proxy.
# Do not auto-seed large “domestic app catalogs” into bypass — that does not scale and
# duplicates work already done by rule-sets (lyc/metacubex geosite-cn / geoip-cn).

# Standalone sing-box on rooted Android does not have the graphical client's
# VpnService package filter.  Package filters have also been observed to let
# unlisted traffic reach the TUN.  Resolve packages to Linux UIDs and apply the
# TUN boundary with include_uid/exclude_uid instead.
MAGICNET_APP_UID_SENTINEL=4294967294

magicnet_app_proxy_packages() {
    _proxy_packages_file="$1"
    if [ ! -f "$_proxy_packages_file" ]; then
        unset _proxy_packages_file
        return 0
    fi
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_proxy_packages_file" 2>/dev/null |
        awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (!seen[$0]++) print }'
    unset _proxy_packages_file
}

magicnet_android_user_ids() {
    if command -v cmd >/dev/null 2>&1; then
        cmd user list 2>/dev/null |
            sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p'
    fi
}

magicnet_package_uids() {
    _uid_packages_file="$1"
    if command -v cmd >/dev/null 2>&1; then
        _uid_users="$(magicnet_android_user_ids | awk '/^[0-9]+$/ && !seen[$0]++')"
        [ -n "$_uid_users" ] || _uid_users=0
        magicnet_app_proxy_packages "$_uid_packages_file" |
            while IFS= read -r _uid_package; do
                [ -n "$_uid_package" ] || continue
                for _uid_user in $_uid_users; do
                    cmd package list packages --user "$_uid_user" -U "$_uid_package" 2>/dev/null |
                        awk -v expected="package:${_uid_package}" '
                            $1 == expected {
                                for (field = 2; field <= NF; field++) {
                                    if ($field ~ /^uid:[0-9]+$/) {
                                        sub(/^uid:/, "", $field)
                                        print $field
                                    }
                                }
                            }
                        '
                done
            done |
            awk '/^[0-9]+$/ && !seen[$0]++'
    elif command -v pm >/dev/null 2>&1; then
        magicnet_app_proxy_packages "$_uid_packages_file" |
            while IFS= read -r _uid_package; do
                [ -n "$_uid_package" ] || continue
                pm list packages -U "$_uid_package" 2>/dev/null |
                    awk -v expected="package:${_uid_package}" '
                        $1 == expected {
                            for (field = 2; field <= NF; field++) {
                                if ($field ~ /^uid:[0-9]+$/) {
                                    sub(/^uid:/, "", $field)
                                    print $field
                                }
                            }
                        }
                    '
            done |
            awk '/^[0-9]+$/ && !seen[$0]++'
    fi
    unset _uid_packages_file _uid_users _uid_package _uid_user
}

magicnet_app_uid_state_commit() {
    _uid_state_dir="$1"
    _uid_include_source="$2"
    _uid_exclude_source="$3"
    mkdir -p "$_uid_state_dir" || return 1
    _uid_include_tmp="${_uid_state_dir}/include-uids.list.new.$$"
    _uid_exclude_tmp="${_uid_state_dir}/exclude-uids.list.new.$$"
    if ! cp -f "$_uid_include_source" "$_uid_include_tmp" ||
        ! cp -f "$_uid_exclude_source" "$_uid_exclude_tmp" ||
        ! mv -f "$_uid_include_tmp" "${_uid_state_dir}/include-uids.list" ||
        ! mv -f "$_uid_exclude_tmp" "${_uid_state_dir}/exclude-uids.list"; then
        rm -f "$_uid_include_tmp" "$_uid_exclude_tmp" 2>/dev/null || true
        unset _uid_state_dir _uid_include_source _uid_exclude_source _uid_include_tmp _uid_exclude_tmp
        return 1
    fi
    unset _uid_state_dir _uid_include_source _uid_exclude_source _uid_include_tmp _uid_exclude_tmp
}

# DNS application selectors are legacy policy residue. Application routing
# may still be used for explicit business features below, but DNS resolution
# must remain destination/policy based so stale app catalogs cannot force a
# different resolver after an upgrade.
magicnet_singbox_apply_app_policy() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || {
        magicnet_warn "packaged jq is unavailable; application policy apply rejected"
        return 1
    }

    _dir="$(magicnet_app_policy_dir)"
    _mode="$(magicnet_app_policy_mode)"
    _proxy_file="${_dir}/app-proxy.list"
    _direct_file="${_dir}/app-direct.list"
    _bypass_file="${_dir}/app-bypass.list"

    _include_packages_tmp="${_config}.include-packages.tmp"
    _include_uids_tmp="${_config}.include-uids.tmp"
    _exclude_uids_tmp="${_config}.exclude-uids.tmp"
    _uid_state_dir="${MODDIR}/.state/app-policy"
    _old_include_uids="${_uid_state_dir}/include-uids.list"
    _old_exclude_uids="${_uid_state_dir}/exclude-uids.list"
    mkdir -p "$_uid_state_dir" || return 1
    : >"$_include_uids_tmp"
    : >"$_exclude_uids_tmp"
    if [ "$_mode" = "whitelist" ]; then
        {
            magicnet_app_proxy_packages "$_direct_file"
            magicnet_app_proxy_packages "$_proxy_file"
        } | awk 'NF && !seen[$0]++' >"$_include_packages_tmp"
        magicnet_package_uids "$_include_packages_tmp" >"$_include_uids_tmp"
        awk '/^[0-9]+$/ && !seen[$0]++ { print }' "$_include_uids_tmp" >"${_include_uids_tmp}.new"
        # An empty include list means “unrestricted” in sing-box.  Keep
        # whitelist mode fail-closed when no selected package resolves.
        [ -s "${_include_uids_tmp}.new" ] || printf '%s\n' "$MAGICNET_APP_UID_SENTINEL" >"${_include_uids_tmp}.new"
        if ! mv -f "${_include_uids_tmp}.new" "$_include_uids_tmp"; then
            rm -f "${_include_uids_tmp}.new" 2>/dev/null || true
            return 1
        fi
    else
        rm -f "$_include_packages_tmp" 2>/dev/null || true
        : >"$_include_uids_tmp"
    fi
    # Resolve explicit bypass packages in both app modes. Their concrete UIDs
    # may bypass the local dataplane, but Android netd commonly emits DNS as
    # UID 0; local DNS must stay hijacked or one bypass app would leak DNS for
    # every application on the device.
    magicnet_package_uids "$_bypass_file" >"$_exclude_uids_tmp"
    awk 'BEGIN { print 0 } /^[0-9]+$/ && !seen[$0]++ { print }' \
        "$_exclude_uids_tmp" >"${_exclude_uids_tmp}.new"
    if ! mv -f "${_exclude_uids_tmp}.new" "$_exclude_uids_tmp"; then
        rm -f "${_exclude_uids_tmp}.new" 2>/dev/null || true
        return 1
    fi

    _tmp="${_config}.app-policy.new"
    [ -f "$_old_include_uids" ] || : >"$_old_include_uids"
    [ -f "$_old_exclude_uids" ] || : >"$_old_exclude_uids"
    [ -f "$_proxy_file" ] || : >"$_proxy_file"
    [ -f "$_direct_file" ] || : >"$_direct_file"
    [ -f "$_bypass_file" ] || : >"$_bypass_file"
    [ -f "$_include_uids_tmp" ] || : >"$_include_uids_tmp"
    [ -f "$_exclude_uids_tmp" ] || : >"$_exclude_uids_tmp"
    if (
        umask 077
        "$_jq" --arg mode "$_mode" --argjson uid_sentinel "$MAGICNET_APP_UID_SENTINEL" \
            --rawfile proxy "$_proxy_file" \
            --rawfile direct "$_direct_file" \
            --rawfile bypass "$_bypass_file" \
            --rawfile include_uids "$_include_uids_tmp" \
            --rawfile exclude_uids "$_exclude_uids_tmp" \
            --rawfile old_include_uids "$_old_include_uids" \
            --rawfile old_exclude_uids "$_old_exclude_uids" '
        def packages($text):
          $text
          | split("\n")
          | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
          | map(select(. != "" and (startswith("#") | not)))
          | unique;
        def uids($text):
          $text
          | split("\n")
          | map(select(test("^[0-9]+$")) | tonumber)
          | unique;
        def without($values):
          map(. as $value | select(($values | index($value)) == null));
        (packages($proxy)) as $proxy_packages
        | (packages($direct)) as $direct_packages
        | (packages($bypass)) as $bypass_packages
        | (uids($include_uids)) as $include_uid_values
        | (uids($exclude_uids)) as $exclude_uid_values
        | (uids($old_include_uids)) as $old_include_uid_values
        | (uids($old_exclude_uids)) as $old_exclude_uid_values
        | (if ($include_uid_values | length) == 0 then [$uid_sentinel] else $include_uid_values end) as $managed_include_uid_values
        | def apply_uid_policy:
            ((.include_uid // []) | without($old_include_uid_values)) as $base_include_uids
            | ((.exclude_uid // []) | without($old_exclude_uid_values)) as $base_exclude_uids
            | del(.include_package, .exclude_package, .include_uid, .exclude_uid)
            | if $mode == "whitelist" then
                .include_uid = (($base_include_uids + $managed_include_uid_values) | unique)
                | .exclude_uid = (([0] + $base_exclude_uids) | unique)
              else
                .include_uid = ($base_include_uids | unique)
                | .exclude_uid = (([0] + $base_exclude_uids + $exclude_uid_values) | unique)
              end
            | if ((.include_uid // []) | length) == 0 then del(.include_uid) else . end
            | if ((.exclude_uid // []) | length) == 0 then del(.exclude_uid) else . end;
          .inbounds = (
            (.inbounds // []) | map(
              if (.type // "") == "tun" then
                apply_uid_policy
              elif (.type // "") == "ebpf" and ((.mode // "local") == "local" or .mode == "hybrid") then
                .local = (
                  (.local // {})
                  | apply_uid_policy
                  | .dns_mode = "hijack"
                )
              else
                .
              end
            )
          )
        | .route.rules = (
            ((.route.rules // [])
              | map(select(
                  ((.package_name // []) | index("__magicnet_app_proxy__")) == null
                  and ((.package_name // []) | index("__magicnet_app_direct__")) == null
                ))) as $rules
            | if (($proxy_packages | length) == 0 and ($direct_packages | length) == 0) then
                $rules
              else
                ($rules
                  | map(select(has("action") or (((.protocol // "") == "icmp") and ((.outbound // "") == "block"))))) as $protocol_guards
                | ($rules
                  | map(select((has("action") or (((.protocol // "") == "icmp") and ((.outbound // "") == "block"))) | not))) as $business_rules
                | $protocol_guards
                  + (if ($direct_packages | length) == 0 then [] else [{
                      "package_name": (["__magicnet_app_direct__"] + $direct_packages),
                      "outbound": "direct"
                    }] end)
                  + (if ($proxy_packages | length) == 0 then [] else [{
                      "package_name": (["__magicnet_app_proxy__"] + $proxy_packages),
                      "outbound": "proxy"
                    }] end)
                  + $business_rules
              end
          )
        | .dns = (
            (.dns // {})
            | .rules = ((.rules // []) | map(select(has("package_name") | not)))
          )
    ' "$_config" >"$_tmp"
    ) && chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config" &&
        magicnet_app_uid_state_commit "$_uid_state_dir" "$_include_uids_tmp" "$_exclude_uids_tmp"; then
        rm -f "$_include_packages_tmp" "$_include_uids_tmp" "$_exclude_uids_tmp" 2>/dev/null || true
        unset _config _dir _mode _proxy_file _direct_file _bypass_file
        unset _include_packages_tmp _include_uids_tmp _exclude_uids_tmp _uid_state_dir
        unset _old_include_uids _old_exclude_uids _tmp
        unset _jq
        return 0
    fi
    rm -f "$_tmp" "$_include_packages_tmp" "$_include_uids_tmp" "$_exclude_uids_tmp" 2>/dev/null || true
    unset _config _dir _mode _proxy_file _direct_file _bypass_file
    unset _include_packages_tmp _include_uids_tmp _exclude_uids_tmp _uid_state_dir
    unset _old_include_uids _old_exclude_uids _tmp
    unset _jq
    return 1
}

magicnet_app_policy_apply_unlocked() {
    _app_rc=0
    magicnet_singbox_apply_app_policy || _app_rc=1
    return "$_app_rc"
}

magicnet_app_policy_apply() {
    magicnet_with_config_lock magicnet_app_policy_apply_unlocked
}
