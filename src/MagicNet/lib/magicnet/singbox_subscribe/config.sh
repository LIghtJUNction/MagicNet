magicnet_singbox_build_outbounds_file() {
    _nodes_dir="$1"
    _out_file="$2"
    _tags_file="$3"
    _first=1
    _imported=0
    _skipped=0

    _first_tag=""
    : >"$_tags_file"
    printf '[' >"${_out_file}.nodes"
    for _node_file in "$_nodes_dir"/node-*.yaml "$_nodes_dir"/node-*.link; do
        [ -f "$_node_file" ] || continue
        case "$_node_file" in
        *.link) _json=$(magicnet_singbox_emit_share_link_json "$_node_file" 2>/dev/null) ;;
        *) _json=$(magicnet_singbox_emit_node_json "$_node_file" 2>/dev/null) ;;
        esac
        if [ -n "$_json" ]; then
            _tag=$(printf '%s' "$_json" | sed -n 's/.*"tag":"\([^"]*\)".*/\1/p')
            if magicnet_singbox_is_info_tag "$_tag"; then
                _skipped=$((_skipped + 1))
                continue
            fi
            [ "$_first" -eq 1 ] || printf ',' >>"${_out_file}.nodes"
            printf '%s' "$_json" >>"${_out_file}.nodes"
            printf '%s\n' "$_tag" >>"$_tags_file"
            [ -n "$_first_tag" ] || _first_tag="$_tag"
            _first=0
            _imported=$((_imported + 1))
        else
            _skipped=$((_skipped + 1))
        fi
    done
    printf ']' >>"${_out_file}.nodes"

    if magicnet_singbox_build_outbounds_file_with_jq "${_out_file}.nodes" "$_tags_file" "$_out_file"; then
        printf '%s %s\n' "$_imported" "$_skipped"
        return 0
    fi

    _first_tag=$(magicnet_singbox_pick_default_proxy_tag "$_tags_file")

    {
        printf '  "outbounds": [\n'
        magicnet_singbox_emit_selector_block "$_tags_file" "$_first_tag"
        _nodes=$(sed 's/^\[//; s/\]$//' "${_out_file}.nodes")
        if [ -n "$_nodes" ]; then
            printf ',\n    %s' "$_nodes"
        fi
        printf ',\n'
        printf '    {\n      "type": "direct",\n      "tag": "direct"\n    },\n'
        printf '    {\n      "type": "block",\n      "tag": "block"\n    }\n'
        printf '  ],'
    } >"$_out_file"

    printf '%s %s\n' "$_imported" "$_skipped"
}

magicnet_singbox_build_outbounds_file_with_jq() {
    _nodes_json="$1"
    _tags_file="$2"
    _out_file="$3"
    command -v jq >/dev/null 2>&1 || return 1
    _tags_json="${_out_file}.tags.json"
    jq -R -s 'split("\n") | map(select(length > 0))' "$_tags_file" >"$_tags_json" || return 1
    jq -n -r --slurpfile nodes "$_nodes_json" --slurpfile tags "$_tags_json" '
      def with_base($outs; $fallback):
        reduce ([$fallback] + $outs + ["direct", "block"])[] as $item
          ([]; if ($item == "" or index($item)) then . else . + [$item] end);
    def selector($tag; $outs; $fallback):
      (with_base($outs; $fallback)) as $items
      | {"type": "selector", "tag": $tag, "outbounds": $items, "default": $items[0]};
    def proxy_tag_score($tag):
      if ($tag | test("免费|Free|free|公益|试用|下载专用|剩余|到期|过期|套餐|官网|订阅|Traffic|traffic|Expire|expire|Expired|expired|Subscription|subscription|官方网站|更新订阅")) then 0
      elif ($tag | test("IEPL|IPLC|专线|S[0-9]+|倍率|x1|x2|香港|日本|新加坡|美国|台湾|韩国")) then 2
      else 1
      end;
    def preferred_proxy_tag($tags):
      (([ $tags[]? | select(proxy_tag_score(.) == 2) ][0])
       // ([ $tags[]? | select(proxy_tag_score(.) == 1) ][0])
       // ($tags[0] // "direct"));
      ($nodes[0] // []
        | map(select(
            ((.server // "") != "")
            and ((.server_port // 0) != 0)
            and (((.tag // "") | test("剩余流量|到期|过期|套餐|官网|订阅|Traffic|traffic|Expire|expire|Expired|expired|Subscription|subscription|官方网站|更新订阅")) | not)
            and (
              (.type == "shadowsocks" and ((.method // "") != "") and ((.password // "") != ""))
              or (.type == "vmess" and ((.uuid // "") != ""))
              or (.type == "vless" and ((.uuid // "") != ""))
              or (.type == "trojan" and ((.password // "") != ""))
              or (.type == "hysteria2" and ((.password // "") != ""))
              or (.type == "anytls" and ((.password // "") != ""))
              or (.type == "tuic" and ((.uuid // "") != "") and ((.password // "") != ""))
            )
          ))
      ) as $nodes
      | ([ $nodes[]? | .tag // empty ] | map(select(length > 0))) as $tags
      | [
          selector("proxy"; $tags; preferred_proxy_tag($tags)),
          selector("select"; ["proxy", "direct"]; "proxy"),
          selector("lan"; ["direct"]; "direct"),
          selector("ad-block"; ["block", "direct"]; "block"),
          selector("cn-direct"; ["direct"]; "direct"),
          selector("apple-cn"; ["direct", "proxy"]; "direct"),
          selector("microsoft-cn"; ["direct", "proxy"]; "direct"),
          selector("google-cn"; ["proxy", "direct"]; "proxy"),
          selector("icloud"; ["direct", "proxy"]; "direct"),
          selector("bing"; ["proxy", "direct"]; "proxy"),
          selector("dns-guard"; ["proxy", "block", "direct"]; "proxy"),
          selector("network-test"; ["proxy", "direct"]; "proxy"),
          selector("ai-proxy"; ["proxy", "direct"]; "proxy"),
          selector("proxy-rule"; ["proxy", "direct"]; "proxy"),
          selector("dev-proxy"; ["proxy", "direct"]; "proxy"),
          selector("social-proxy"; ["proxy", "direct"]; "proxy"),
          selector("media-proxy"; ["proxy", "direct"]; "proxy"),
          selector("game-proxy"; ["proxy", "direct"]; "proxy"),
          selector("telegram-proxy"; ["proxy", "direct"]; "proxy"),
          selector("download-direct"; ["direct", "proxy"]; "direct"),
          selector("final"; ["proxy", "direct", "block"]; "proxy")
        ] + $nodes + [
          {"type": "direct", "tag": "direct"},
          {"type": "block", "tag": "block"}
        ]
      | "  \"outbounds\": " + tojson + ","
    ' >"$_out_file" || return 1
}

magicnet_singbox_count_valid_outbounds_nodes() {
    _nodes_json="$1"
    command -v jq >/dev/null 2>&1 || return 1
    jq -n -r --slurpfile nodes "$_nodes_json" '
      ($nodes[0] // []
        | map(select(
            ((.server // "") != "")
            and ((.server_port // 0) != 0)
            and (((.tag // "") | test("剩余流量|到期|过期|套餐|官网|订阅|Traffic|traffic|Expire|expire|Expired|expired|Subscription|subscription|官方网站|更新订阅")) | not)
            and (
              (.type == "shadowsocks" and ((.method // "") != "") and ((.password // "") != ""))
              or (.type == "vmess" and ((.uuid // "") != ""))
              or (.type == "vless" and ((.uuid // "") != ""))
              or (.type == "trojan" and ((.password // "") != ""))
              or (.type == "hysteria2" and ((.password // "") != ""))
              or (.type == "anytls" and ((.password // "") != ""))
              or (.type == "tuic" and ((.uuid // "") != "") and ((.password // "") != ""))
            )
          ))
        | length
      ) // 0
    '
}

magicnet_singbox_emit_selector_block() {
    _tags_file="$1"
    _first_tag="$2"
    magicnet_emit_selector_json "proxy" "$(cat "$_tags_file")" "$_first_tag"
    printf ',\n'
    magicnet_emit_selector_json "select" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    magicnet_singbox_emit_static_selectors
    unset _tags_file _first_tag
}

magicnet_singbox_pick_default_proxy_tag() {
    _tags_file="$1"
    awk '
        NF {
            tag = $0
            if (first == "") {
                first = tag
            }
            if (tag ~ /免费|Free|free|公益|试用|下载专用|剩余|到期|过期|套餐|官网|订阅|Traffic|traffic|Expire|expire|Expired|expired|Subscription|subscription|官方网站|更新订阅/) {
                next
            }
            if (tag ~ /IEPL|IPLC|专线|S[0-9]+|倍率|x1|x2|香港|日本|新加坡|美国|台湾|韩国/) {
                print tag
                found = 1
                exit
            }
            if (fallback == "") {
                fallback = tag
            }
        }
        END {
            if (!found) {
                if (fallback != "") {
                    print fallback
                } else {
                    print first
                }
            }
        }
    ' "$_tags_file"
    unset _tags_file
}

magicnet_singbox_emit_static_selectors() {
    for _pair in \
        "lan::direct" "ad-block::block" "cn-direct::direct" \
        "apple-cn::direct" "microsoft-cn::direct" "google-cn::proxy" "icloud::direct"; do
        _name=${_pair%%:*}
        _default=${_pair##*:}
        printf ',\n'
        magicnet_emit_selector_json "$_name" "" "$_default"
    done
    printf ',\n'
    magicnet_emit_selector_json "bing" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    printf ',\n'
    magicnet_emit_selector_json "dns-guard" "$(printf '%s\n%s\n%s\n' "proxy" "block" "direct")" "proxy"
    printf ',\n'
    magicnet_emit_selector_json "network-test" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    for _name in ai-proxy proxy-rule dev-proxy social-proxy media-proxy game-proxy telegram-proxy; do
        printf ',\n'
        magicnet_emit_selector_json "$_name" "$(printf '%s\n%s\n' "proxy" "direct")" "proxy"
    done
    printf ',\n'
    magicnet_emit_selector_json "download-direct" "$(printf '%s\n%s\n' "direct" "proxy")" "direct"
    printf ',\n'
    magicnet_emit_selector_json "final" "$(printf '%s\n%s\n%s\n' "proxy" "direct" "block")" "proxy"
    unset _pair _name _default
}

magicnet_singbox_sanitize_generated_config() {
    _sanitize_config_file="$1"
    _sanitize_jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_sanitize_jq" ] || {
        unset _sanitize_config_file _sanitize_jq
        return 0
    }

    _sanitize_tmp_file="${_sanitize_config_file}.sanitized"
    "$_sanitize_jq" '
      def has_match($rule):
        [
          "inbound",
          "clash_mode",
          "package_name",
          "domain",
          "domain_suffix",
          "domain_keyword",
          "rule_set",
          "network",
          "port",
          "protocol",
          "ip_cidr",
          "ip_is_private",
          "source_ip_cidr",
          "source_port",
          "process_name",
          "user",
          "user_id"
        ] | any(. as $key | $rule | has($key));
      .outbounds = ((.outbounds // [])
        | if any(.tag == "dns-guard") then .
          else . + [{"type": "selector", "tag": "dns-guard", "outbounds": ["proxy", "block", "direct"], "default": "proxy"}]
          end)
      | .route.rules = ((.route.rules // [])
        | map(select(((has("outbound") and (has_match(.) | not) and (has("action") | not)) | not))))
    ' "$_sanitize_config_file" >"$_sanitize_tmp_file" && mv -f "$_sanitize_tmp_file" "$_sanitize_config_file"
    _sanitize_rc=$?
    [ "$_sanitize_rc" -eq 0 ] || rm -f "$_sanitize_tmp_file" 2>/dev/null || true
    _sanitize_return="$_sanitize_rc"
    unset _sanitize_config_file _sanitize_jq _sanitize_tmp_file _sanitize_rc
    return "$_sanitize_return"
}

magicnet_singbox_update_config_with_nodes() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    _outbounds_file="$1"
    _tmp_file="${_config_file}.new"

    awk -v repl="$_outbounds_file" '
        function count_delta(s, i, c, d) {
            d = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "[") d++
                if (c == "]") d--
            }
            return d
        }
        BEGIN {
            while ((getline line < repl) > 0) {
                replacement = replacement line "\n"
            }
            close(repl)
            skipping = 0
            depth = 0
            found = 0
        }
        skipping == 0 && $0 ~ /^[[:space:]]*"outbounds"[[:space:]]*:/ {
            found = 1
            if (prev != "") {
                sub(/,[[:space:]]*$/, "", prev)
                sub(/[[:space:]]*$/, ",", prev)
                print prev
                prev = ""
            }
            printf "%s", replacement
            depth = count_delta($0)
            skipping = 1
            next
        }
        skipping == 1 {
            depth += count_delta($0)
            if (depth <= 0) {
                skipping = 0
            }
            next
        }
        skipping == 0 && found == 0 && $0 ~ /^  "(route|experimental)"[[:space:]]*:/ {
            if (prev != "") {
                sub(/,[[:space:]]*$/, "", prev)
                sub(/[[:space:]]*$/, ",", prev)
                print prev
                prev = ""
            }
            printf "%s", replacement
            found = 1
        }
        {
            if (prev != "") print prev
            prev = $0
        }
        END {
            if (prev != "") print prev
        }
    ' "$_config_file" >"$_tmp_file"

    magicnet_singbox_sanitize_generated_config "$_tmp_file" || {
        error "Generated sing-box config failed sanitization"
        return 1
    }

    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$_tmp_file" -D "${_config_file%/*}" >/dev/null || {
            error "Generated sing-box config failed validation"
            return 1
        }
    fi

    mv -f "$_tmp_file" "$_config_file"
}

magicnet_singbox_replay_cached_outbounds() {
    _cached_outbounds="${MODDIR}/.config/sing-box/.subscription-work/outbounds.json"
    [ -s "$_cached_outbounds" ] || {
        unset _cached_outbounds
        return 1
    }
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks)"' \
        "$_cached_outbounds" || {
        unset _cached_outbounds
        return 1
    }

    _config_file=$(magicnet_singbox_subscription_config_file)
    _previous_config="${_config_file}.cache-replay.previous"
    cp -f "$_config_file" "$_previous_config" || {
        unset _cached_outbounds _config_file _previous_config
        return 1
    }
    if magicnet_singbox_update_config_with_nodes "$_cached_outbounds" &&
        magicnet_singbox_verify_subscription_ready; then
        rm -f "$_previous_config"
        unset _cached_outbounds _config_file _previous_config
        return 0
    fi

    mv -f "$_previous_config" "$_config_file" 2>/dev/null || true
    unset _cached_outbounds _config_file _previous_config
    return 1
}

magicnet_singbox_pids() {
    for _proc_comm in /proc/[0-9]*/comm; do
        [ -r "$_proc_comm" ] || continue
        if [ "$(cat "$_proc_comm" 2>/dev/null)" = "sing-box" ]; then
            _pid=${_proc_comm#/proc/}
            printf '%s\n' "${_pid%/comm}"
        fi
    done
}

magicnet_singbox_is_running() {
    [ -n "$(magicnet_singbox_pids)" ]
}

magicnet_singbox_restart_if_running() {
    magicnet_singbox_is_running || return 0

    for _pid in $(magicnet_singbox_pids); do
        kill "$_pid" 2>/dev/null || true
    done
    sleep 1
    if magicnet_singbox_is_running; then
        for _pid in $(magicnet_singbox_pids); do
            kill -9 "$_pid" 2>/dev/null || true
        done
        sleep 1
    fi
    ip link delete magicnet0 2>/dev/null || true
    ip link delete tun0 2>/dev/null || true

    _config_file=$(magicnet_singbox_subscription_config_file)
    _work_dir="${_config_file%/*}"
    _log_file="${MODDIR}/.log/sing-box.log"
    mkdir -p "${MODDIR}/.log"
    nohup sing-box run -c "$_config_file" -D "$_work_dir" >"$_log_file" 2>&1 &
    sleep 2
    magicnet_singbox_is_running
}

magicnet_singbox_api_has_nodes() {
    _api=$(curl -sS --max-time 5 http://127.0.0.1:9090/proxies 2>/dev/null || curl -sS --max-time 5 http://127.0.0.1:9090/providers/proxies 2>/dev/null || true)
    [ -n "$_api" ] || return 1
    printf '%s' "$_api" | grep -Eq '"type":"(VLESS|Hysteria2|Trojan|VMess|Shadowsocks|Selector)"'
}

magicnet_singbox_config_has_nodes() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks)"' "$_config_file"
}

magicnet_singbox_google_works() {
    curl -fsSI --max-time "${MAGICNET_GOOGLE_TEST_MAX_TIME:-15}" \
        -x http://127.0.0.1:7892 \
        https://www.google.com >/dev/null 2>&1
}

magicnet_singbox_verify_subscription_ready() {
    if magicnet_singbox_is_running; then
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

    magicnet_singbox_config_has_nodes || {
        error "sing-box generated config contains no proxy nodes"
        return 1
    }
}
