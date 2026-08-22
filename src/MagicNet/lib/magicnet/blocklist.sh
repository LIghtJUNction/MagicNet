magicnet_block_dir() {
    printf '%s\n' "${MODDIR}/.config/magicnet"
}

magicnet_block_conf() {
    printf '%s\n' "$(magicnet_block_dir)/block.conf"
}

magicnet_block_manual_file() {
    printf '%s\n' "$(magicnet_block_dir)/block-domain-suffix.list"
}

magicnet_block_community_file() {
    printf '%s\n' "$(magicnet_block_dir)/community-ban-domain-suffix.list"
}

magicnet_block_community_rules_file() {
    printf '%s\n' "$(magicnet_block_dir)/community-ban-rules.list"
}

magicnet_block_allow_file() {
    printf '%s\n' "$(magicnet_block_dir)/block-allow-rules.list"
}

magicnet_block_conf_url_is_safe() {
    case "$1" in
        http://*|https://*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/?=%+@,-]*) return 1 ;;
    esac
    return 0
}

magicnet_block_load_conf() {
    _conf="$(magicnet_block_conf)"
    MAGICNET_BLOCK_ENABLED=1
    MAGICNET_BLOCK_COMMUNITY_ENABLED=1
    _invalid=0
    _seen_enabled=0
    _seen_community=0
    _seen_url=0

    if [ -f "$_conf" ]; then
        # block.conf is data, not shell. Accept only its complete allowlisted
        # assignment schema; any unknown, malformed, duplicate, or injected
        # line invalidates the whole file and leaves safe defaults in effect.
        while IFS= read -r _line || [ -n "$_line" ]; do
            case "$_line" in
                MAGICNET_BLOCK_ENABLED=0|MAGICNET_BLOCK_ENABLED=1)
                    if [ "$_seen_enabled" -ne 0 ]; then
                        _invalid=1
                    else
                        MAGICNET_BLOCK_ENABLED="${_line#MAGICNET_BLOCK_ENABLED=}"
                        _seen_enabled=1
                    fi
                    ;;
                MAGICNET_BLOCK_COMMUNITY_ENABLED=0|MAGICNET_BLOCK_COMMUNITY_ENABLED=1)
                    if [ "$_seen_community" -ne 0 ]; then
                        _invalid=1
                    else
                        MAGICNET_BLOCK_COMMUNITY_ENABLED="${_line#MAGICNET_BLOCK_COMMUNITY_ENABLED=}"
                        _seen_community=1
                    fi
                    ;;
                MAGICNET_BLOCK_URL=*)
                    _value="${_line#MAGICNET_BLOCK_URL=}"
                    if [ "$_seen_url" -ne 0 ] || ! magicnet_block_conf_url_is_safe "$_value"; then
                        _invalid=1
                    else
                        _seen_url=1
                    fi
                    ;;
                *) _invalid=1 ;;
            esac
        done < "$_conf"
    fi
    if [ "$_invalid" -ne 0 ]; then
        MAGICNET_BLOCK_ENABLED=1
        MAGICNET_BLOCK_COMMUNITY_ENABLED=1
    fi
    unset _conf _invalid _seen_enabled _seen_community _seen_url _line _value
}

magicnet_block_list_values() {
    _file="$1"
    [ -f "$_file" ] || return 0
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++'
}

magicnet_block_normalize_allow_rules() {
    _allow_file="$(magicnet_block_allow_file)"
    [ -f "$_allow_file" ] || {
        unset _allow_file
        return 0
    }
    _allow_tmp="${_allow_file}.magicnet-normalize.$$"
    if ! awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function normalize(line,    value, comma, kind, payload, lower, scheme_end, authority, slash, host) {
            value = trim(line)
            comma = index(value, ",")
            if (!comma) return line
            kind = toupper(trim(substr(value, 1, comma - 1)))
            if (kind != "DOMAIN" && kind != "DOMAIN-SUFFIX") return line
            payload = trim(substr(value, comma + 1))
            lower = tolower(payload)
            if (index(lower, "http://") == 1) {
                scheme_end = 8
            } else if (index(lower, "https://") == 1) {
                scheme_end = 9
            } else {
                return line
            }
            authority = substr(payload, scheme_end)
            slash = match(authority, /[\/?#]/)
            if (slash) authority = substr(authority, 1, slash - 1)
            sub(/^.*@/, "", authority)
            if (authority ~ /:[0-9]+$/) sub(/:[0-9]+$/, "", authority)
            host = tolower(authority)
            sub(/[.]+$/, "", host)
            if (host == "" || host ~ /[[:space:]\/:,@]/) return line
            return kind "," host
        }
        {
            output = normalize($0)
            key = trim(output)
            if (key != "" && key !~ /^#/ && seen[key]++) next
            print output
        }
    ' "$_allow_file" >"$_allow_tmp"; then
        rm -f "$_allow_tmp"
        unset _allow_file _allow_tmp
        return 1
    fi
    if cmp -s "$_allow_file" "$_allow_tmp"; then
        rm -f "$_allow_tmp"
    elif ! mv -f "$_allow_tmp" "$_allow_file"; then
        rm -f "$_allow_tmp"
        unset _allow_file _allow_tmp
        return 1
    fi
    unset _allow_file _allow_tmp
}

magicnet_block_manual_suffixes() {
    magicnet_block_list_values "$(magicnet_block_manual_file)" | awk '{ print "DOMAIN-SUFFIX," $0 }'
}

magicnet_block_community_rules() {
    _allow_file="$(magicnet_block_allow_file)"
    if [ -s "$(magicnet_block_community_rules_file)" ]; then
        if [ -s "$_allow_file" ]; then
            magicnet_block_list_values "$(magicnet_block_community_rules_file)" | grep -Fvx -f "$_allow_file"
        else
            magicnet_block_list_values "$(magicnet_block_community_rules_file)"
        fi
    else
        if [ -s "$_allow_file" ]; then
            magicnet_block_list_values "$(magicnet_block_community_file)" | awk '{ print "DOMAIN-SUFFIX," $0 }' | grep -Fvx -f "$_allow_file"
        else
            magicnet_block_list_values "$(magicnet_block_community_file)" | awk '{ print "DOMAIN-SUFFIX," $0 }'
        fi
    fi
    unset _allow_file
}

magicnet_block_all_rules() {
    magicnet_block_load_conf
    [ "$MAGICNET_BLOCK_ENABLED" = "1" ] || return 0
    magicnet_block_manual_suffixes
    if [ "$MAGICNET_BLOCK_COMMUNITY_ENABLED" = "1" ]; then
        magicnet_block_community_rules
    fi
}

magicnet_block_has_domains() {
    magicnet_block_all_rules | grep -q .
}

magicnet_block_emit_match_array() {
    _emit_key="$1"
    _emit_values="$2"
    [ -n "$_emit_values" ] || return 0
    printf ',\n        "%s": [\n' "$_emit_key"
    _emit_count=$(printf '%s\n' "$_emit_values" | awk 'NF' | wc -l | tr -d ' ')
    _emit_idx=0
    printf '%s\n' "$_emit_values" | while read -r _emit_value; do
        [ -n "$_emit_value" ] || continue
        _emit_idx=$((_emit_idx + 1))
        _emit_comma=","; [ "$_emit_idx" -eq "$_emit_count" ] && _emit_comma=""
        printf '          "%s"%s\n' "$(magicnet_json_escape "$_emit_value")" "$_emit_comma"
    done
    printf '        ]'
    unset _emit_key _emit_values _emit_count _emit_idx _emit_value _emit_comma
}

magicnet_block_allow_singbox_rules() {
    _rules="$(magicnet_block_list_values "$(magicnet_block_allow_file)")"
    [ -n "$_rules" ] || return 0
    _domains="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN" { print $2 }' | awk 'NF && !seen[$0]++')"
    _suffixes="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN-SUFFIX" { print $2 }' | awk 'NF && !seen[$0]++')"
    _keywords="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN-KEYWORD" { print $2 }' | awk 'NF && !seen[$0]++')"
    printf '      {\n'
    printf '        "domain": ["__magicnet_ad_allow__"'
    if [ -n "$_domains" ]; then
        printf '%s\n' "$_domains" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            printf ', "%s"' "$(magicnet_json_escape "$_domain")"
        done
    fi
    printf ']'
    magicnet_block_emit_match_array "domain_suffix" "$_suffixes"
    magicnet_block_emit_match_array "domain_keyword" "$_keywords"
    printf ',\n        "outbound": "ad-allow"\n'
    printf '      },\n'
    unset _rules _domains _suffixes _keywords _domain
}

magicnet_block_singbox_rules() {
    _rules="$(magicnet_block_all_rules)"
    [ -n "$_rules" ] || return 0
    _domains="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN" { print $2 }' | awk 'NF && !seen[$0]++')"
    _suffixes="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN-SUFFIX" { print $2 }' | awk 'NF && !seen[$0]++')"
    _keywords="$(printf '%s\n' "$_rules" | awk -F, '$1 == "DOMAIN-KEYWORD" { print $2 }' | awk 'NF && !seen[$0]++')"
    printf '      {\n'
    printf '        "domain": [\n'
    printf '          "__magicnet_block__"'
    if [ -n "$_domains" ]; then
        printf ',\n'
        _count=$(printf '%s\n' "$_domains" | awk 'NF' | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_domains" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_domain")" "$_comma"
        done
    else
        printf '\n'
    fi
    printf '        ]'
    if [ -n "$_suffixes" ]; then
        printf ',\n        "domain_suffix": [\n'
        _count=$(printf '%s\n' "$_suffixes" | awk 'NF' | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_suffixes" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_domain")" "$_comma"
        done
        printf '        ]'
    fi
    if [ -n "$_keywords" ]; then
        printf ',\n        "domain_keyword": [\n'
        _count=$(printf '%s\n' "$_keywords" | awk 'NF' | wc -l | tr -d ' ')
        _idx=0
        printf '%s\n' "$_keywords" | while read -r _domain; do
            [ -n "$_domain" ] || continue
            _idx=$((_idx + 1))
            _comma=","
            [ "$_idx" -eq "$_count" ] && _comma=""
            printf '          "%s"%s\n' "$(magicnet_json_escape "$_domain")" "$_comma"
        done
        printf '        ]'
    fi
    printf ',\n'
    printf '        "outbound": "ad-block"\n'
    printf '      },\n'
    unset _rules _domains _suffixes _keywords _count _idx _comma _domain
}

magicnet_block_ensure_ad_selectors() {
    _selector_config="$1"
    _selector_tmp="${_selector_config}.magicnet-selectors.new"
    _selector_has_allow=0
    grep -q '"tag"[[:space:]]*:[[:space:]]*"ad-allow"' "$_selector_config" && _selector_has_allow=1
    (umask 077; awk -v has_allow="$_selector_has_allow" '
        function emit_block(comma) {
            print "    {"
            print "      \"type\": \"selector\","
            print "      \"tag\": \"ad-block\","
            print "      \"interrupt_exist_connections\": true,"
            print "      \"outbounds\": [\"block\", \"direct\", \"proxy\"],"
            print "      \"default\": \"block\""
            print "    }" comma
        }
        function emit_allow(comma) {
            print "    {"
            print "      \"type\": \"selector\","
            print "      \"tag\": \"ad-allow\","
            print "      \"interrupt_exist_connections\": true,"
            print "      \"outbounds\": [\"final\", \"direct\", \"proxy\"],"
            print "      \"default\": \"final\""
            print "    }" comma
        }
        function brace_delta(s, i, c, d) {
            d = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "{") d++
                if (c == "}") d--
            }
            return d
        }
        BEGIN { in_outbounds = 0; buffering = 0; depth = 0; buffer = ""; found_block = 0 }
        {
            if (buffering) {
                buffer = buffer $0 "\n"
                depth += brace_delta($0)
                if ($0 ~ /"tag"[[:space:]]*:[[:space:]]*"ad-block"/) tag = "block"
                if ($0 ~ /"tag"[[:space:]]*:[[:space:]]*"ad-allow"/) tag = "allow"
                if (depth <= 0) {
                    comma = ($0 ~ /},[[:space:]]*$/) ? "," : ""
                    if (tag == "block") {
                        emit_block(has_allow ? comma : ",")
                        found_block = 1
                        if (!has_allow) emit_allow(comma)
                    } else if (tag == "allow") {
                        emit_allow(comma)
                    } else {
                        printf "%s", buffer
                    }
                    buffering = 0; buffer = ""; tag = ""
                }
                next
            }
            if ($0 ~ /^  "outbounds"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_outbounds = 1
                print
                next
            }
            if (in_outbounds && $0 ~ /^    \{[[:space:]]*$/) {
                buffering = 1; buffer = $0 "\n"; depth = 1; tag = ""
                next
            }
            if (in_outbounds && $0 ~ /^  ][,]?[[:space:]]*$/) {
                if (!found_block) exit 42
                in_outbounds = 0
            }
            print
        }
    ' "$_selector_config" >"$_selector_tmp") || {
        _selector_rc=$?
        rm -f "$_selector_tmp"
        unset _selector_config _selector_tmp _selector_has_allow _selector_rc
        return 1
    }
    if ! chmod 600 "$_selector_tmp" ||
        ! mv -f "$_selector_tmp" "$_selector_config" ||
        ! chmod 600 "$_selector_config"; then
        rm -f "$_selector_tmp" 2>/dev/null || true
        unset _selector_config _selector_tmp _selector_has_allow
        return 1
    fi
    unset _selector_config _selector_tmp _selector_has_allow
}

magicnet_block_apply_singbox() {
    magicnet_block_normalize_allow_rules || return 1
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    magicnet_block_ensure_ad_selectors "$_config" || return 1
    _tmp="${_config}.magicnet-block.new"
    _rules_file="${MODDIR}/.tmp/magicnet-block-singbox.rules"
    if ! mkdir -p "${_rules_file%/*}" ||
        ! {
            magicnet_block_allow_singbox_rules &&
                magicnet_block_singbox_rules
        } >"$_rules_file"; then
        rm -f "$_rules_file" "$_tmp" 2>/dev/null || true
        return 1
    fi
    if magicnet_block_has_domains &&
        ! grep -q '"__magicnet_block__"' "$_rules_file"; then
        magicnet_warn "sing-box block rules were not generated"
        rm -f "$_rules_file" "$_tmp" 2>/dev/null || true
        return 1
    fi
    if magicnet_block_list_values "$(magicnet_block_allow_file)" | grep -q . &&
        ! grep -q '"__magicnet_ad_allow__"' "$_rules_file"; then
        magicnet_warn "sing-box block allow rules were not generated"
        rm -f "$_rules_file" "$_tmp" 2>/dev/null || true
        return 1
    fi
    if ! (umask 077; awk -v rules_file="$_rules_file" '
        BEGIN {
            in_route = 0
            in_rules = 0
            buffering = 0
            buffer = ""
            skip_custom = 0
            inserted = 0
        }
        function reset_buffer() {
            buffer = ""
            buffering = 0
            skip_custom = 0
        }
        function route_rule_precedes_ads(rule) {
            return rule ~ /"action"[[:space:]]*:/ ||
                (rule ~ /"protocol"[[:space:]]*:[[:space:]]*"icmp"/ &&
                 rule ~ /"outbound"[[:space:]]*:[[:space:]]*"block"/) ||
                rule ~ /"__magicnet_app_proxy__"/
        }
        function flush_rule() {
            if (!skip_custom) {
                if (!inserted && !route_rule_precedes_ads(buffer)) {
                    while ((getline rule_line < rules_file) > 0) {
                        print rule_line
                    }
                    close(rules_file)
                    inserted = 1
                }
                printf "%s", buffer
            }
            reset_buffer()
        }
        {
            if (buffering) {
                buffer = buffer $0 "\n"
                if ($0 ~ /"__magicnet_(ad_allow|block)__"/) {
                    skip_custom = 1
                }
                if ($0 ~ /^      }[,]?[[:space:]]*$/) {
                    flush_rule()
                }
                next
            }
            if ($0 ~ /^  "route"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/) {
                in_route = 1
                print
                next
            }
            if (in_route && $0 ~ /^  }[,]?[[:space:]]*$/) {
                in_route = 0
                print
                next
            }
            if (in_route && $0 ~ /^    "rules"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/) {
                in_rules = 1
                print
                next
            }
            if (in_rules && $0 ~ /^    ][,]?[[:space:]]*$/) {
                if (!inserted) {
                    while ((getline rule_line < rules_file) > 0) {
                        print rule_line
                    }
                    close(rules_file)
                    inserted = 1
                }
                in_rules = 0
                print
                next
            }
            if (in_rules && $0 ~ /^      \{[[:space:]]*$/) {
                buffering = 1
                buffer = $0 "\n"
                skip_custom = 0
                next
            }
            print
        }
    ' "$_config" >"$_tmp"); then
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    if magicnet_block_has_domains; then
        if ! grep -q '"__magicnet_block__"' "$_tmp"; then
            magicnet_warn "sing-box block rules were not inserted"
            rm -f "$_tmp" 2>/dev/null || true
            return 1
        fi
    elif grep -q '"__magicnet_block__"' "$_tmp"; then
        magicnet_warn "sing-box block marker was not removed"
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    if magicnet_block_list_values "$(magicnet_block_allow_file)" | grep -q .; then
        if ! grep -q '"__magicnet_ad_allow__"' "$_tmp"; then
            magicnet_warn "sing-box block allow rules were not inserted"
            rm -f "$_tmp" 2>/dev/null || true
            return 1
        fi
    elif grep -q '"__magicnet_ad_allow__"' "$_tmp"; then
        magicnet_warn "sing-box block allow marker was not removed"
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    if ! chmod 600 "$_tmp" || ! mv -f "$_tmp" "$_config" || ! chmod 600 "$_config"; then
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_block_apply_unlocked() {
    _block_rc=0
    magicnet_block_apply_singbox || _block_rc=1
    return "$_block_rc"
}

magicnet_block_apply() {
    magicnet_with_config_lock magicnet_block_apply_unlocked
}
