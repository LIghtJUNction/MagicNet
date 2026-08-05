magicnet_app_policy_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_app_policy_mode() {
    _mode_file="$(magicnet_app_policy_dir)/app-mode.conf"
    if [ -f "$_mode_file" ]; then
        . "$_mode_file"
    fi
    case "${MAGICNET_APP_MODE:-blacklist}" in
        whitelist) printf '%s\n' "whitelist" ;;
        *) printf '%s\n' "blacklist" ;;
    esac
}

# App package policy is NOT the primary domestic/foreign split.
# - Blacklist mode: most apps enter TUN; geosite/geoip (+ domain lists) choose cn-direct vs proxy.
# - app-bypass.list: multi-VPN coexistence and optional user opt-outs only.
# - app-direct.list: keep selected packages in TUN but force the direct outbound.
# - app-proxy.list: force selected packages onto MagicNet proxy.
# Do not auto-seed large “domestic app catalogs” into bypass — that does not scale and
# duplicates work already done by rule-sets (lyc/metacubex geosite-cn / geoip-cn).


magicnet_package_array_block() {
    _key="$1"
    _file="$2"
    _comma="${3:-,}"
    _force_empty="${4:-0}"
    if [ ! -s "$_file" ]; then
        [ "$_force_empty" = "1" ] || return 0
        printf '      "%s": []%s\n' "$_key" "$_comma"
        unset _key _file _comma _force_empty
        return 0
    fi

    _items=$(sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null |
        awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (!seen[$0]++) print }')
    if [ -z "$_items" ]; then
        [ "$_force_empty" = "1" ] || return 0
        printf '      "%s": []%s\n' "$_key" "$_comma"
        unset _key _file _comma _force_empty _items
        return 0
    fi

    printf '      "%s": [\n' "$_key"
    _count=$(printf '%s\n' "$_items" | wc -l | tr -d ' ')
    _idx=0
    printf '%s\n' "$_items" | while read -r _pkg; do
        [ -n "$_pkg" ] || continue
        _idx=$((_idx + 1))
        _line_comma=","
        [ "$_idx" -eq "$_count" ] && _line_comma=""
        printf '        "%s"%s\n' "$(magicnet_json_escape "$_pkg")" "$_line_comma"
    done
    printf '      ]%s\n' "$_comma"
    unset _key _file _comma _force_empty _items _count _idx _line_comma _pkg
}

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
    command -v cmd >/dev/null 2>&1 || {
        unset _uid_packages_file
        return 0
    }
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
magicnet_singbox_dns_has_package_rules() {
    _dns_package_config="$1"
    [ -f "$_dns_package_config" ] || {
        unset _dns_package_config
        return 1
    }
    awk '
        function count_delta(line,    i, c, delta, in_string, escaped) {
            delta = 0
            in_string = 0
            escaped = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (in_string) {
                    if (escaped) escaped = 0
                    else if (c == "\\") escaped = 1
                    else if (c == "\"") in_string = 0
                    continue
                }
                if (c == "\"") in_string = 1
                else if (c == "{") delta++
                else if (c == "}") delta--
            }
            return delta
        }
        {
            if (!in_dns && $0 ~ /^  "dns"[[:space:]]*:[[:space:]]*\{/) {
                in_dns = 1
                dns_depth = depth + count_delta($0)
            }
            if (in_dns && index($0, "\"package_name\"") > 0) found = 1
            depth += count_delta($0)
            if (in_dns && depth < dns_depth) in_dns = 0
        }
        END { exit found ? 0 : 1 }
    ' "$_dns_package_config"
    _dns_package_rc=$?
    unset _dns_package_config
    return "$_dns_package_rc"
}

# Ownership marker for MagicNet-managed force-proxy rules (not a user package).
# Idempotent rewrites strip rules containing this marker, then re-inject one
# authoritative rule from app-proxy.list — single source of truth for that list.
MAGICNET_APP_PROXY_MARKER="__magicnet_app_proxy__"
MAGICNET_APP_DIRECT_MARKER="__magicnet_app_direct__"

magicnet_app_proxy_rule() {
    _proxy_rule_packages="$(magicnet_app_proxy_packages "$1")"
    if [ -z "$_proxy_rule_packages" ]; then
        unset _proxy_rule_packages
        return 0
    fi
    printf '      {\n'
    printf '        "package_name": [\n'
    printf '          "%s",\n' "$MAGICNET_APP_PROXY_MARKER"
    _proxy_rule_count=$(printf '%s\n' "$_proxy_rule_packages" | wc -l | tr -d ' ')
    _proxy_rule_idx=0
    printf '%s\n' "$_proxy_rule_packages" | while IFS= read -r _proxy_rule_package; do
        [ -n "$_proxy_rule_package" ] || continue
        _proxy_rule_idx=$((_proxy_rule_idx + 1))
        _proxy_rule_comma=","
        [ "$_proxy_rule_idx" -eq "$_proxy_rule_count" ] && _proxy_rule_comma=""
        printf '          "%s"%s\n' "$(magicnet_json_escape "$_proxy_rule_package")" "$_proxy_rule_comma"
    done
    printf '        ],\n'
    printf '        "outbound": "proxy"\n'
    printf '      }\n'
    unset _proxy_rule_packages _proxy_rule_count _proxy_rule_idx _proxy_rule_package _proxy_rule_comma
}

magicnet_app_direct_rule() {
    _direct_rule_packages="$(magicnet_app_proxy_packages "$1")"
    if [ -z "$_direct_rule_packages" ]; then
        unset _direct_rule_packages
        return 0
    fi
    printf '      {\n'
    printf '        "package_name": [\n'
    printf '          "%s",\n' "$MAGICNET_APP_DIRECT_MARKER"
    _direct_rule_count=$(printf '%s\n' "$_direct_rule_packages" | wc -l | tr -d ' ')
    _direct_rule_idx=0
    printf '%s\n' "$_direct_rule_packages" | while IFS= read -r _direct_rule_package; do
        [ -n "$_direct_rule_package" ] || continue
        _direct_rule_idx=$((_direct_rule_idx + 1))
        _direct_rule_comma=","
        [ "$_direct_rule_idx" -eq "$_direct_rule_count" ] && _direct_rule_comma=""
        printf '          "%s"%s\n' "$(magicnet_json_escape "$_direct_rule_package")" "$_direct_rule_comma"
    done
    printf '        ],\n'
    printf '        "outbound": "direct"\n'
    printf '      }\n'
    unset _direct_rule_packages _direct_rule_count _direct_rule_idx _direct_rule_package _direct_rule_comma
}

magicnet_singbox_apply_app_policy() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0

    _dir="$(magicnet_app_policy_dir)"
    _mode="$(magicnet_app_policy_mode)"
    _proxy_file="${_dir}/app-proxy.list"
    _direct_file="${_dir}/app-direct.list"
    _bypass_file="${_dir}/app-bypass.list"

    _include_block=""
    _exclude_block=""
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
        _include_block="$(magicnet_package_array_block include_package "$_include_packages_tmp" "," 1)"
    else
        magicnet_package_uids "$_bypass_file" >"$_exclude_uids_tmp"
        _exclude_block="$(magicnet_package_array_block exclude_package "$_bypass_file" ",")"
        rm -f "$_include_packages_tmp" 2>/dev/null || true
    fi

    _tmp="${_config}.app-policy.new"
    _include_tmp="${_config}.include-package.tmp"
    _exclude_tmp="${_config}.exclude-package.tmp"
    _proxy_rule_tmp="${_config}.app-proxy-rule.tmp"
    _direct_rule_tmp="${_config}.app-direct-rule.tmp"
    _jq="${MODDIR}/bin/jq"
    if [ ! -x "$_jq" ]; then
        _jq="$(command -v jq 2>/dev/null || true)"
    fi
    if [ -n "$_jq" ]; then
        [ -f "$_proxy_file" ] || : >"$_proxy_file"
        [ -f "$_direct_file" ] || : >"$_direct_file"
        [ -f "$_bypass_file" ] || : >"$_bypass_file"
        [ -f "$_old_include_uids" ] || : >"$_old_include_uids"
        [ -f "$_old_exclude_uids" ] || : >"$_old_exclude_uids"
        if "$_jq" --arg mode "$_mode" \
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
            | .inbounds = (
                (.inbounds // []) | map(
                  if (.type // "") == "tun" then
                    ((.include_uid // []) | without($old_include_uid_values)) as $base_include_uids
                    | ((.exclude_uid // []) | without($old_exclude_uid_values)) as $base_exclude_uids
                    | del(.include_package, .exclude_package, .include_uid, .exclude_uid)
                    | if $mode == "whitelist" then
                        .include_package = (($proxy_packages + $direct_packages) | unique)
                        | .include_uid = (($base_include_uids + $include_uid_values) | unique)
                        | .exclude_uid = ($base_exclude_uids | unique)
                      else
                        .include_uid = ($base_include_uids | unique)
                        | .exclude_uid = (($base_exclude_uids + $exclude_uid_values) | unique)
                        | if ($bypass_packages | length) > 0 then
                            .exclude_package = $bypass_packages
                          else
                            .
                          end
                      end
                    | if ((.include_uid // []) | length) == 0 then del(.include_uid) else . end
                    | if ((.exclude_uid // []) | length) == 0 then del(.exclude_uid) else . end
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
        ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config" &&
            magicnet_app_uid_state_commit "$_uid_state_dir" "$_include_uids_tmp" "$_exclude_uids_tmp"; then
            rm -f "$_include_packages_tmp" "$_include_uids_tmp" "$_exclude_uids_tmp" 2>/dev/null || true
            unset _config _dir _mode _proxy_file _direct_file _bypass_file _include_block _exclude_block
            unset _include_packages_tmp _include_uids_tmp _exclude_uids_tmp _uid_state_dir
            unset _old_include_uids _old_exclude_uids _tmp _include_tmp _exclude_tmp
            unset _proxy_rule_tmp _direct_rule_tmp _jq
            return 0
        fi
        rm -f "$_tmp" 2>/dev/null || true
        unset _jq
    fi

    # The awk fallback can preserve and reorder route rules, but it is not a
    # safe JSON editor for arbitrary DNS rule objects. Fail closed when a
    # legacy DNS package selector is present so it can never continue running
    # merely because jq is unavailable.
    if [ -z "$_jq" ] && magicnet_singbox_dns_has_package_rules "$_config"; then
        magicnet_warn "legacy DNS application rules require jq cleanup; refusing to start with them"
        rm -f "$_include_packages_tmp" "$_include_uids_tmp" "$_exclude_uids_tmp" \
            "$_include_tmp" "$_exclude_tmp" "$_proxy_rule_tmp" "$_direct_rule_tmp" \
            "$_tmp" 2>/dev/null || true
        unset _config _dir _mode _proxy_file _direct_file _bypass_file _include_block _exclude_block
        unset _include_packages_tmp _include_uids_tmp _exclude_uids_tmp _uid_state_dir
        unset _old_include_uids _old_exclude_uids _tmp _include_tmp _exclude_tmp
        unset _proxy_rule_tmp _direct_rule_tmp _jq
        return 1
    fi

    if [ -n "$_include_block" ]; then
        printf '%s\n' "$_include_block" >"$_include_tmp"
    else
        rm -f "$_include_tmp" 2>/dev/null || true
        _include_tmp=""
    fi
    if [ -n "$_exclude_block" ]; then
        printf '%s\n' "$_exclude_block" >"$_exclude_tmp"
    else
        rm -f "$_exclude_tmp" 2>/dev/null || true
        _exclude_tmp=""
    fi
    if magicnet_app_proxy_packages "$_proxy_file" | grep -q .; then
        magicnet_app_proxy_rule "$_proxy_file" >"$_proxy_rule_tmp"
    else
        rm -f "$_proxy_rule_tmp" 2>/dev/null || true
        _proxy_rule_tmp=""
    fi
    if magicnet_app_proxy_packages "$_direct_file" | grep -q .; then
        magicnet_app_direct_rule "$_direct_file" >"$_direct_rule_tmp"
    else
        rm -f "$_direct_rule_tmp" 2>/dev/null || true
        _direct_rule_tmp=""
    fi

    if awk -v include_file="$_include_tmp" -v exclude_file="$_exclude_tmp" -v proxy_rule_file="$_proxy_rule_tmp" -v direct_rule_file="$_direct_rule_tmp" '
        function emit_file(path, line) {
            if (path == "") {
                return
            }
            while ((getline line < path) > 0) {
                print line
            }
            close(path)
        }
        function emit_proxy_rule(comma, line, previous) {
            if (proxy_rule_file == "") {
                return
            }
            previous = ""
            while ((getline line < proxy_rule_file) > 0) {
                if (previous != "") {
                    print previous
                }
                previous = line
            }
            close(proxy_rule_file)
            if (previous != "") {
                print previous comma
            }
            proxy_inserted = 1
        }
        function emit_direct_rule(comma, line, previous) {
            if (direct_rule_file == "") {
                return
            }
            previous = ""
            while ((getline line < direct_rule_file) > 0) {
                if (previous != "") {
                    print previous
                }
                previous = line
            }
            close(direct_rule_file)
            if (previous != "") {
                print previous comma
            }
            direct_inserted = 1
        }
        function route_rule_is_guard(rule) {
            return rule ~ /"action"[[:space:]]*:/ ||
                (rule ~ /"protocol"[[:space:]]*:[[:space:]]*"icmp"/ &&
                 rule ~ /"outbound"[[:space:]]*:[[:space:]]*"block"/)
        }
        function flush_route_rule() {
            if (route_buffer !~ /"__magicnet_app_(proxy|direct)__"/) {
                route_rule_count++
                route_rules[route_rule_count] = route_buffer
            }
            route_buffer = ""
            route_buffering = 0
        }
        function emit_route_rule(rule, comma) {
            sub(/},\n$/, "}\n", rule)
            if (comma != "") {
                sub(/}\n$/, "},\n", rule)
            }
            printf "%s", rule
        }
        function emit_route_rules(i, guard_count, business_count, output_count, emitted) {
            guard_count = 0
            business_count = 0
            for (i = 1; i <= route_rule_count; i++) {
                if (route_rule_is_guard(route_rules[i])) {
                    guard_count++
                } else {
                    business_count++
                }
            }
            output_count = guard_count + business_count + (direct_rule_file != "" ? 1 : 0) + (proxy_rule_file != "" ? 1 : 0)
            emitted = 0
            for (i = 1; i <= route_rule_count; i++) {
                if (route_rule_is_guard(route_rules[i])) {
                    emitted++
                    emit_route_rule(route_rules[i], emitted < output_count ? "," : "")
                }
            }
            if (direct_rule_file != "") {
                emitted++
                emit_direct_rule(emitted < output_count ? "," : "")
            }
            if (proxy_rule_file != "") {
                emitted++
                emit_proxy_rule(emitted < output_count ? "," : "")
            }
            for (i = 1; i <= route_rule_count; i++) {
                if (!route_rule_is_guard(route_rules[i])) {
                    emitted++
                    emit_route_rule(route_rules[i], emitted < output_count ? "," : "")
                }
            }
        }
        BEGIN {
            in_tun = 0
            skip_package_array = 0
            in_route = 0
            in_route_rules = 0
            route_buffering = 0
            route_buffer = ""
            route_rule_count = 0
            proxy_inserted = 0
            direct_inserted = 0
        }
        route_buffering {
            route_buffer = route_buffer $0 "\n"
            if ($0 ~ /^      }[,]?[[:space:]]*$/) {
                flush_route_rule()
            }
            next
        }
        skip_package_array {
            if ($0 ~ /^[[:space:]]*][[:space:]]*,?[[:space:]]*$/) {
                skip_package_array = 0
            }
            next
        }
        {
            if ($0 ~ /^  "route"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/) {
                in_route = 1
            }
            if (in_route && $0 ~ /^    "rules"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_route_rules = 1
                print
                next
            }
            if (in_route_rules && $0 ~ /^      \{[[:space:]]*$/) {
                route_buffering = 1
                route_buffer = $0 "\n"
                next
            }
            if (in_route_rules && $0 ~ /^    ][,]?[[:space:]]*$/) {
                emit_route_rules()
                in_route_rules = 0
                print
                next
            }
            if (in_route && $0 ~ /^  }[,]?[[:space:]]*$/) {
                in_route = 0
            }
            if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"tun"/) {
                in_tun = 1
            }
            if (in_tun && $0 ~ /^[[:space:]]*"(include_package|exclude_package)"[[:space:]]*:/) {
                if ($0 !~ /\[[^]]*][[:space:]]*,?[[:space:]]*$/) {
                    skip_package_array = 1
                }
                next
            }
            if (in_tun && $0 ~ /^[[:space:]]*"stack"[[:space:]]*:/) {
                emit_file(include_file)
                emit_file(exclude_file)
            }
            print
            if (in_tun && $0 ~ /^    }[,]?[[:space:]]*$/) {
                in_tun = 0
            }
        }
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        rm -f "$_include_packages_tmp" "$_include_uids_tmp" "$_exclude_uids_tmp" "$_include_tmp" "$_exclude_tmp" "$_proxy_rule_tmp" "$_direct_rule_tmp" 2>/dev/null || true
        return 1
    fi
    rm -f "$_include_packages_tmp" "$_include_uids_tmp" "$_exclude_uids_tmp" "$_include_tmp" "$_exclude_tmp" "$_proxy_rule_tmp" "$_direct_rule_tmp" 2>/dev/null || true
}

magicnet_app_policy_apply_unlocked() {
    _app_rc=0
    magicnet_singbox_apply_app_policy || _app_rc=1
    return "$_app_rc"
}

magicnet_app_policy_apply() {
    magicnet_with_config_lock magicnet_app_policy_apply_unlocked
}
