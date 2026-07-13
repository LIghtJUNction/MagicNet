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

magicnet_app_proxy_rule() {
    _proxy_rule_packages="$(magicnet_app_proxy_packages "$1")"
    if [ -z "$_proxy_rule_packages" ]; then
        unset _proxy_rule_packages
        return 0
    fi
    printf '      {\n'
    printf '        "package_name": [\n'
    printf '          "__magicnet_app_proxy__",\n'
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

magicnet_singbox_apply_app_policy() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0

    _dir="$(magicnet_app_policy_dir)"
    _mode="$(magicnet_app_policy_mode)"
    _proxy_file="${_dir}/app-proxy.list"
    _bypass_file="${_dir}/app-bypass.list"

    _include_block=""
    _exclude_block=""
    if [ "$_mode" = "whitelist" ]; then
        _include_block="$(magicnet_package_array_block include_package "$_proxy_file" "," 1)"
    else
        _exclude_block="$(magicnet_package_array_block exclude_package "$_bypass_file" ",")"
    fi

    _tmp="${_config}.app-policy.new"
    _include_tmp="${_config}.include-package.tmp"
    _exclude_tmp="${_config}.exclude-package.tmp"
    _proxy_rule_tmp="${_config}.app-proxy-rule.tmp"
    _jq="${MODDIR}/bin/jq"
    if [ ! -x "$_jq" ]; then
        _jq="$(command -v jq 2>/dev/null || true)"
    fi
    if [ -n "$_jq" ]; then
        [ -f "$_proxy_file" ] || : >"$_proxy_file"
        [ -f "$_bypass_file" ] || : >"$_bypass_file"
        if "$_jq" --arg mode "$_mode" --rawfile proxy "$_proxy_file" --rawfile bypass "$_bypass_file" '
            def packages($text):
              $text
              | split("\n")
              | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
              | map(select(. != "" and (startswith("#") | not)))
              | unique;
            (packages($proxy)) as $proxy_packages
            | (packages($bypass)) as $bypass_packages
            | .inbounds = (
                (.inbounds // []) | map(
                  if (.type // "") == "tun" then
                    del(.include_package, .exclude_package)
                    | if $mode == "whitelist" then
                        .include_package = $proxy_packages
                      elif ($bypass_packages | length) > 0 then
                        .exclude_package = $bypass_packages
                      else
                        .
                      end
                  else
                    .
                  end
                )
              )
            | .route.rules = (
                ((.route.rules // [])
                  | map(select(((.package_name // []) | index("__magicnet_app_proxy__")) == null))) as $rules
                | if ($proxy_packages | length) == 0 then
                    $rules
                  else
                    ($rules
                      | map(select(has("action") or (((.protocol // "") == "icmp") and ((.outbound // "") == "block"))))) as $protocol_guards
                    | ($rules
                      | map(select((has("action") or (((.protocol // "") == "icmp") and ((.outbound // "") == "block"))) | not))) as $business_rules
                    | $protocol_guards
                      + [{
                          "package_name": (["__magicnet_app_proxy__"] + $proxy_packages),
                          "outbound": "proxy"
                        }]
                      + $business_rules
                  end
              )
        ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
            unset _config _dir _mode _proxy_file _bypass_file _include_block _exclude_block _tmp _include_tmp _exclude_tmp _proxy_rule_tmp _jq
            return 0
        fi
        rm -f "$_tmp" 2>/dev/null || true
        unset _jq
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

    if awk -v include_file="$_include_tmp" -v exclude_file="$_exclude_tmp" -v proxy_rule_file="$_proxy_rule_tmp" '
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
        function route_rule_is_guard(rule) {
            return rule ~ /"action"[[:space:]]*:/ ||
                (rule ~ /"protocol"[[:space:]]*:[[:space:]]*"icmp"/ &&
                 rule ~ /"outbound"[[:space:]]*:[[:space:]]*"block"/)
        }
        function flush_route_rule() {
            if (route_buffer !~ /"__magicnet_app_proxy__"/) {
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
            output_count = guard_count + business_count + (proxy_rule_file != "" ? 1 : 0)
            emitted = 0
            for (i = 1; i <= route_rule_count; i++) {
                if (route_rule_is_guard(route_rules[i])) {
                    emitted++
                    emit_route_rule(route_rules[i], emitted < output_count ? "," : "")
                }
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
        rm -f "$_include_tmp" "$_exclude_tmp" "$_proxy_rule_tmp" 2>/dev/null || true
        return 1
    fi
    rm -f "$_include_tmp" "$_exclude_tmp" "$_proxy_rule_tmp" 2>/dev/null || true
}

magicnet_app_policy_apply_unlocked() {
    _app_rc=0
    magicnet_singbox_apply_app_policy || _app_rc=1
    return "$_app_rc"
}

magicnet_app_policy_apply() {
    magicnet_with_config_lock magicnet_app_policy_apply_unlocked
}
