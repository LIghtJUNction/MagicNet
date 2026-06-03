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

magicnet_block_load_conf() {
    _conf="$(magicnet_block_conf)"
    if [ -f "$_conf" ]; then
        . "$_conf"
    fi
    MAGICNET_BLOCK_ENABLED="${MAGICNET_BLOCK_ENABLED:-1}"
    MAGICNET_BLOCK_COMMUNITY_ENABLED="${MAGICNET_BLOCK_COMMUNITY_ENABLED:-1}"
    MAGICNET_BLOCK_URL="${MAGICNET_BLOCK_URL:-https://raw.githubusercontent.com/LIghtJUNction/MagicMihomo/main/ruleset/magicnet/ban.yaml}"
    unset _conf
}

magicnet_block_list_values() {
    _file="$1"
    [ -f "$_file" ] || return 0
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++'
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

magicnet_block_mihomo_rules() {
    magicnet_block_load_conf
    [ "$MAGICNET_BLOCK_ENABLED" = "1" ] || return 0
    magicnet_block_all_rules | while IFS=, read -r _type _value; do
        [ -n "$_type" ] && [ -n "$_value" ] || continue
        case "$_type" in
            DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD) printf '  - %s,%s,REJECT\n' "$_type" "$_value" ;;
        esac
    done
}

magicnet_block_mihomo_normalize_rules_indent() {
    awk '
        BEGIN { in_rules = 0 }
        /^rules:[[:space:]]*$/ {
            in_rules = 1
            print
            next
        }
        in_rules && /^-[[:space:]]/ {
            print "  " $0
            next
        }
        { print }
    '
}

magicnet_block_apply_mihomo() {
    _config="${MODDIR}/.config/mihomo/config.yaml"
    [ -f "$_config" ] || return 0
    _tmp="${_config}.magicnet-block.new"
    _rules_file="${MODDIR}/.tmp/magicnet-block-mihomo.rules"
    mkdir -p "${_rules_file%/*}"
    magicnet_block_mihomo_rules >"$_rules_file"
    if awk -v rules_file="$_rules_file" '
        BEGIN {
            skip = 0
            cleanup_after_block = 0
            inserted = 0
        }
        skip {
            if ($0 ~ /^[[:space:]]*#[[:space:]]*MAGICNET_BLOCK_END/) {
                skip = 0
                cleanup_after_block = 1
            }
            next
        }
        $0 ~ /^[[:space:]]*#[[:space:]]*MAGICNET_BLOCK_START/ {
            skip = 1
            next
        }
        cleanup_after_block && $0 ~ /^-[[:space:]]*(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD),.*REJECT[[:space:]]*$/ {
            next
        }
        cleanup_after_block && $0 ~ /^  -[[:space:]]*(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD),.*REJECT[[:space:]]*$/ {
            next
        }
        cleanup_after_block && $0 ~ /^[[:space:]]*#[[:space:]]*MAGICNET_BLOCK_END[[:space:]]*$/ {
            next
        }
        cleanup_after_block {
            cleanup_after_block = 0
        }
        $0 ~ /^[[:space:]]*-[[:space:]]*RULE-SET,mnban,REJECT[[:space:]]*$/ {
            next
        }
        {
            print
            if (!inserted && $0 ~ /^rules:[[:space:]]*$/) {
                if ((getline first_rule < rules_file) > 0) {
                    print "  # MAGICNET_BLOCK_START"
                    print first_rule
                    while ((getline rule_line < rules_file) > 0) {
                        print rule_line
                    }
                    close(rules_file)
                    print "  # MAGICNET_BLOCK_END"
                }
                inserted = 1
            }
        }
    ' "$_config" | magicnet_block_mihomo_normalize_rules_indent >"$_tmp"; then
        if command -v mihomo >/dev/null 2>&1; then
            mihomo -t -f "$_tmp" -d "${_config%/*}" >/dev/null 2>&1 || {
                magicnet_warn "mihomo config failed validation after blocklist apply"
                rm -f "$_tmp" 2>/dev/null || true
                return 1
            }
        fi
        mv -f "$_tmp" "$_config"
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
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
    printf '        "outbound": "block"\n'
    printf '      },\n'
    unset _rules _domains _suffixes _keywords _count _idx _comma _domain
}

magicnet_block_apply_singbox() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _tmp="${_config}.magicnet-block.new"
    _rules_file="${MODDIR}/.tmp/magicnet-block-singbox.rules"
    mkdir -p "${_rules_file%/*}"
    magicnet_block_singbox_rules >"$_rules_file"
    if awk -v rules_file="$_rules_file" '
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
        function flush_rule() {
            if (!skip_custom) {
                printf "%s", buffer
                if (!inserted && buffer ~ /"action"[[:space:]]*:[[:space:]]*"sniff"/) {
                    while ((getline rule_line < rules_file) > 0) {
                        print rule_line
                    }
                    close(rules_file)
                    inserted = 1
                }
            }
            reset_buffer()
        }
        {
            if (buffering) {
                buffer = buffer $0 "\n"
                if ($0 ~ /"__magicnet_block__"/) {
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
    ' "$_config" >"$_tmp" && mv -f "$_tmp" "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
}

magicnet_block_apply_unlocked() {
    _block_rc=0
    magicnet_block_apply_mihomo || _block_rc=1
    magicnet_block_apply_singbox || _block_rc=1
    return "$_block_rc"
}

magicnet_block_apply() {
    magicnet_with_config_lock magicnet_block_apply_unlocked
}
