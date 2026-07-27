# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

magicnet_json_escape() {
    printf '%s' "$1" |
        tr '\r\n\t' '   ' |
        sed 's/[[:cntrl:]]//g; s/\\/\\\\/g; s/"/\\"/g'
}

magicnet_singbox_tag_is_reserved() {
    case "$1" in
    proxy-auto | proxy | select | lan | ad-block | ad-allow | cn-direct | \
        apple-cn | microsoft-cn | google-cn | icloud | bing | dns-guard | network-test | \
        ai-proxy | ai-chatgpt | ai-chatgpt-auto | ai-gemini | ai-gemini-auto | \
        ai-grok | ai-grok-auto | ai-claude | ai-claude-auto | proxy-rule | dev-proxy | \
        social-proxy | media-proxy | game-proxy | telegram-proxy | download-direct | \
        final | direct | block | warp)
        return 0
        ;;
    *) return 1 ;;
    esac
}

magicnet_singbox_ai_selectors_canonical() {
    _ai_config="$1"
    _ai_expected_proxy_url="${2:-https://www.gstatic.com/generate_204}"
    _ai_expected_proxy_interval="${3:-3m}"
    if command -v jq >/dev/null 2>&1; then
        jq -e \
            --arg expected_proxy_url "$_ai_expected_proxy_url" \
            --arg expected_proxy_interval "$_ai_expected_proxy_interval" '
          def mainland_node_tag:
            test("中国|大陆|内地|香港|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西|(^|[^A-Za-z0-9])(?:Hong[ _-]?Kong(?:[ _-]?[0-9]+)?|HKG?[ _-]?[0-9]+|China|Mainland|HK|HKG|CN|Beijing|Shanghai|Guangzhou|Shenzhen|Chongqing|Tianjin|Hebei|Shanxi|Liaoning|Jilin|Heilongjiang|Jiangsu|Zhejiang|Anhui|Fujian|Jiangxi|Shandong|Henan|Hubei|Hunan|Guangdong|Hainan|Sichuan|Guizhou|Yunnan|Shaanxi|Gansu|Qinghai|Inner[ _-]?Mongolia|Guangxi|Tibet|Ningxia|Xinjiang)([^A-Za-z0-9]|$)"; "i");
          def proxy_node:
            .type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
              or .type == "hysteria2" or .type == "anytls" or .type == "tuic";
          def reserved_tag:
            . as $tag
            | [
                "proxy-auto", "proxy", "select", "lan", "ad-block", "ad-allow", "cn-direct",
                "apple-cn", "microsoft-cn", "google-cn", "icloud", "bing", "dns-guard", "network-test",
                "ai-proxy", "ai-chatgpt", "ai-chatgpt-auto", "ai-gemini", "ai-gemini-auto",
                "ai-grok", "ai-grok-auto", "ai-claude", "ai-claude-auto", "proxy-rule", "dev-proxy",
                "social-proxy", "media-proxy", "game-proxy", "telegram-proxy", "download-direct",
                "final", "direct", "block", "warp"
              ]
            | index($tag) != null;
          def valid_proxy_node:
            (.tag | type == "string" and length > 0 and (reserved_tag | not))
              and (.server | type == "string" and length > 0)
              and (.server_port
                | type == "number" and . == floor and . >= 1 and . <= 65535)
              and (if .type == "shadowsocks" then
                  (.method | type == "string" and length > 0)
                    and (.password | type == "string" and length > 0)
                elif .type == "vmess" or .type == "vless" then
                  (.uuid | type == "string" and length > 0)
                elif .type == "trojan" or .type == "hysteria2" or .type == "anytls" then
                  (.password | type == "string" and length > 0)
                elif .type == "tuic" then
                  (.uuid | type == "string" and length > 0)
                    and (.password | type == "string" and length > 0)
                else false
                end);
          [
            {name: "ai-chatgpt", url: "https://chatgpt.com/"},
            {name: "ai-gemini", url: "https://gemini.google.com/"},
            {name: "ai-grok", url: "https://grok.com/"},
            {name: "ai-claude", url: "https://claude.ai/"}
          ] as $services
          | ($services | map(.name)) as $names
          | ($services | map(.name + "-auto")) as $auto_names
          | [.outbounds[]? | select(.tag as $tag | $names | index($tag))] as $groups
          | [.outbounds[]? | select(.tag as $tag | $auto_names | index($tag))] as $auto_groups
          | ([.outbounds[]? | select(.tag == "ai-proxy")]) as $ai_proxies
          | ([.outbounds[]? | select(.tag == "proxy")]) as $proxies
          | ([.outbounds[]? | select(.tag == "proxy-auto")]) as $proxy_autos
          | [.outbounds[]? | select(proxy_node)] as $nodes
          | [$nodes[] | .tag] as $node_tags
          | ([ $node_tags[]? | select(mainland_node_tag | not) ]) as $ai_tags
          | ([.outbounds[]?.tag] | unique) as $tags
          | ($groups | length) == 4
            and ($nodes | all(valid_proxy_node))
            and ($node_tags | length) == ($node_tags | unique | length)
            and ($proxies | length) == 1
            and (if ($node_tags | length) > 0 then
              ($proxy_autos | length) == 1
                and $proxy_autos[0].type == "urltest"
                and $proxy_autos[0].tag == "proxy-auto"
                and $proxy_autos[0].outbounds == $node_tags
                and $proxy_autos[0].url == $expected_proxy_url
                and $proxy_autos[0].interval == $expected_proxy_interval
                and $proxy_autos[0].tolerance == 30
                and $proxy_autos[0].idle_timeout == "10m"
                and $proxy_autos[0].interrupt_exist_connections == false
                and $proxies[0].type == "selector"
                and $proxies[0].tag == "proxy"
                and $proxies[0].outbounds == ($node_tags + ["proxy-auto", "direct", "block"])
                and $proxies[0].default == $node_tags[0]
              else
                ($proxy_autos | length) == 0
                  and $proxies[0].type == "selector"
                  and $proxies[0].tag == "proxy"
                  and $proxies[0].outbounds == ["block"]
                  and $proxies[0].default == "block"
              end)
            and ($ai_proxies | length) == 1
            and ($ai_proxies[0].type == "selector")
            and (($ai_proxies[0].outbounds == ["block"] and $ai_proxies[0].default == "block" and ($ai_tags | length) == 0)
              or (($ai_proxies[0].outbounds | length) > 0
                and $ai_proxies[0].default == $ai_proxies[0].outbounds[0]
                and ($ai_proxies[0].outbounds | all(. as $member | ($node_tags | index($member) != null) and ($member | mainland_node_tag | not)))))
            and ($auto_groups | length) == (if ($ai_tags | length) > 0 then 4 else 0 end)
            and ($services | all(. as $service
              | ($service.name + "-auto") as $auto_name
              | ([ $groups[] | select(.tag == $service.name) ]) as $service_groups
              | ([ $auto_groups[] | select(.tag == $auto_name) ]) as $service_auto_groups
              | ($service_groups | length) == 1
                and $service_groups[0].type == "selector"
                and $service_groups[0].default
                  == (if ($ai_tags | length) > 0 then $ai_tags[0] else "block" end)
                and ($service_groups[0].outbounds
                  == (if ($ai_tags | length) > 0 then ($ai_tags + ["block", $auto_name]) else ["block"] end))
                and ($service_groups[0].outbounds | all(. as $member | $tags | index($member) != null))
                and (if ($ai_tags | length) > 0 then
                  ($service_auto_groups | length) == 1
                    and $service_auto_groups[0].type == "urltest"
                    and $service_auto_groups[0].outbounds == $ai_proxies[0].outbounds
                    and ($service_auto_groups[0].outbounds | all(. as $member
                      | ($node_tags | index($member) != null) and ($member | mainland_node_tag | not)))
                    and $service_auto_groups[0].url == $service.url
                    and $service_auto_groups[0].interval == "10m"
                    and $service_auto_groups[0].tolerance == 30
                    and $service_auto_groups[0].idle_timeout == "10m"
                    and $service_auto_groups[0].interrupt_exist_connections == false
                  else ($service_auto_groups | length) == 0
                  end)))
        ' "$_ai_config" >/dev/null 2>&1
        _ai_rc=$?
    else
        awk \
            -v expected_proxy_url="$_ai_expected_proxy_url" \
            -v expected_proxy_interval="$_ai_expected_proxy_interval" '
          function mainland(value, folded) {
            folded = tolower(value)
            return value ~ /中国|大陆|内地|香港|北京|上海|广州|深圳|天津|重庆|江苏|浙江|福建|山东|河南|河北|湖北|湖南|四川|陕西|安徽|辽宁|吉林|黑龙江|海南|广西|贵州|云南|山西|江西/ ||
              folded ~ /(^|[^[:alnum:]])(hong[ _-]?kong([ _-]?[0-9]+)?|hkg?[ _-]?[0-9]+|china|mainland|hk|hkg|cn|beijing|shanghai|guangzhou|shenzhen|chongqing|tianjin|hebei|shanxi|liaoning|jilin|heilongjiang|jiangsu|zhejiang|anhui|fujian|jiangxi|shandong|henan|hubei|hunan|guangdong|hainan|sichuan|guizhou|yunnan|shaanxi|gansu|qinghai|inner[ _-]?mongolia|guangxi|tibet|ningxia|xinjiang)([^[:alnum:]]|$)/
          }
          function reserved_tag(value) {
            return value ~ /^(proxy-auto|proxy|select|lan|ad-block|ad-allow|cn-direct|apple-cn|microsoft-cn|google-cn|icloud|bing|dns-guard|network-test|ai-proxy|ai-chatgpt|ai-chatgpt-auto|ai-gemini|ai-gemini-auto|ai-grok|ai-grok-auto|ai-claude|ai-claude-auto|proxy-rule|dev-proxy|social-proxy|media-proxy|game-proxy|telegram-proxy|download-direct|final|direct|block|warp)$/
          }
          function skip_space(s, position, length_s) {
            length_s = length(s)
            while (position <= length_s && substr(s, position, 1) ~ /[[:space:]]/) position++
            return position
          }
          function json_skip_space(s) {
            json_position = skip_space(s, json_position)
          }
          function json_parse_string(s,    character, escape, hex) {
            if (substr(s, json_position, 1) != "\"") return 0
            json_position++
            while (json_position <= length(s)) {
              character = substr(s, json_position, 1)
              if (character == "\"") {
                json_position++
                return 1
              }
              if (character ~ /[[:cntrl:]]/) return 0
              if (character == "\\") {
                json_position++
                if (json_position > length(s)) return 0
                escape = substr(s, json_position, 1)
                if (escape == "u") {
                  hex = substr(s, json_position + 1, 4)
                  if (length(hex) != 4 || hex ~ /[^0-9A-Fa-f]/) return 0
                  json_position += 5
                  continue
                }
                if (escape !~ /^["\\\/bfnrt]$/) return 0
              }
              json_position++
            }
            return 0
          }
          function json_parse_number(s,    character) {
            if (substr(s, json_position, 1) == "-") json_position++
            character = substr(s, json_position, 1)
            if (character == "0") {
              json_position++
              if (substr(s, json_position, 1) ~ /[0-9]/) return 0
            } else if (character ~ /[1-9]/) {
              do json_position++
              while (substr(s, json_position, 1) ~ /[0-9]/)
            } else {
              return 0
            }
            if (substr(s, json_position, 1) == ".") {
              json_position++
              if (substr(s, json_position, 1) !~ /[0-9]/) return 0
              while (substr(s, json_position, 1) ~ /[0-9]/) json_position++
            }
            if (substr(s, json_position, 1) ~ /[eE]/) {
              json_position++
              if (substr(s, json_position, 1) ~ /[+-]/) json_position++
              if (substr(s, json_position, 1) !~ /[0-9]/) return 0
              while (substr(s, json_position, 1) ~ /[0-9]/) json_position++
            }
            return 1
          }
          function json_parse_array(s,    character) {
            json_position++
            json_skip_space(s)
            if (substr(s, json_position, 1) == "]") {
              json_position++
              return 1
            }
            while (json_position <= length(s)) {
              if (!json_parse_value(s)) return 0
              json_skip_space(s)
              character = substr(s, json_position, 1)
              if (character == "]") {
                json_position++
                return 1
              }
              if (character != ",") return 0
              json_position++
              json_skip_space(s)
            }
            return 0
          }
          function json_parse_object(s,    character) {
            json_position++
            json_skip_space(s)
            if (substr(s, json_position, 1) == "}") {
              json_position++
              return 1
            }
            while (json_position <= length(s)) {
              if (!json_parse_string(s)) return 0
              json_skip_space(s)
              if (substr(s, json_position, 1) != ":") return 0
              json_position++
              json_skip_space(s)
              if (!json_parse_value(s)) return 0
              json_skip_space(s)
              character = substr(s, json_position, 1)
              if (character == "}") {
                json_position++
                return 1
              }
              if (character != ",") return 0
              json_position++
              json_skip_space(s)
            }
            return 0
          }
          function json_parse_value(s,    character) {
            json_skip_space(s)
            character = substr(s, json_position, 1)
            if (character == "{") return json_parse_object(s)
            if (character == "[") return json_parse_array(s)
            if (character == "\"") return json_parse_string(s)
            if (character == "-" || character ~ /[0-9]/) return json_parse_number(s)
            if (substr(s, json_position, 4) == "true" || substr(s, json_position, 4) == "null") {
              json_position += 4
              return 1
            }
            if (substr(s, json_position, 5) == "false") {
              json_position += 5
              return 1
            }
            return 0
          }
          function json_syntax_valid(s) {
            json_position = 1
            json_skip_space(s)
            if (!json_parse_value(s)) return 0
            json_skip_space(s)
            return json_position > length(s)
          }
          function parse_string(s, start,    i, character, escaped, value) {
            parse_ok = 0
            parse_end = 0
            value = ""
            escaped = 0
            if (substr(s, start, 1) != "\"") return ""
            for (i = start + 1; i <= length(s); i++) {
              character = substr(s, i, 1)
              if (escaped) {
                value = value character
                escaped = 0
              } else if (character == "\\") {
                value = value character
                escaped = 1
              } else if (character == "\"") {
                parse_ok = 1
                parse_end = i
                return value
              } else {
                value = value character
              }
            }
            return ""
          }
          function clear_array(values,    key) {
            for (key in values) delete values[key]
          }
          function field_value_start(object, wanted,    i, character, object_depth, array_depth, key, end, position) {
            field_found = 0
            for (i = 1; i <= length(object); i++) {
              character = substr(object, i, 1)
              if (character == "\"") {
                key = parse_string(object, i)
                end = parse_end
                if (!parse_ok) return 0
                if (object_depth == 1 && array_depth == 0) {
                  position = skip_space(object, end + 1)
                  if (substr(object, position, 1) == ":" && key == wanted) {
                    field_found = 1
                    return skip_space(object, position + 1)
                  }
                }
                i = end
              } else if (character == "{") {
                object_depth++
              } else if (character == "}") {
                object_depth--
              } else if (character == "[") {
                array_depth++
              } else if (character == "]") {
                array_depth--
              }
            }
            return 0
          }
          function field_string(object, wanted,    position, value) {
            position = field_value_start(object, wanted)
            field_valid = field_found && substr(object, position, 1) == "\""
            if (!field_valid) return ""
            value = parse_string(object, position)
            field_valid = parse_ok
            return value
          }
          function field_nonempty_string(object, wanted,    value) {
            value = field_string(object, wanted)
            return field_valid && value != ""
          }
          function field_scalar(object, wanted,    position, end, character, value) {
            position = field_value_start(object, wanted)
            if (!field_found) {
              field_valid = 0
              return ""
            }
            end = position
            while (end <= length(object)) {
              character = substr(object, end, 1)
              if (character == "," || character == "}" || character ~ /[[:space:]]/) break
              end++
            }
            value = substr(object, position, end - position)
            field_valid = value != ""
            return value
          }
          function field_array(object, wanted, values,    position, character, count, end) {
            clear_array(values)
            position = field_value_start(object, wanted)
            if (!field_found || substr(object, position, 1) != "[") return -1
            position++
            count = 0
            while (position <= length(object)) {
              position = skip_space(object, position)
              character = substr(object, position, 1)
              if (character == "]") return count
              if (character != "\"") return -1
              values[++count] = parse_string(object, position)
              end = parse_end
              if (!parse_ok) return -1
              position = skip_space(object, end + 1)
              character = substr(object, position, 1)
              if (character == "]") return count
              if (character != ",") return -1
              position++
            }
            return -1
          }
          function collect_outbounds(config,    i, character, key, end, position, target_position,
                                     target_depth, in_outbounds, object_start, root_started, root_complete) {
            structure_depth = 0
            root_outbounds_count = 0
            for (i = 1; i <= length(config); i++) {
              character = substr(config, i, 1)
              if (structure_depth == 0 && character !~ /[[:space:]]/) {
                if (root_complete || (!root_started && character != "{")) return 0
              }
              if (character == "\"") {
                if (structure_depth == 0) return 0
                key = parse_string(config, i)
                end = parse_end
                if (!parse_ok) return 0
                if (!in_outbounds && structure_depth == 1 && structure_stack[1] == "{" && key == "outbounds") {
                  position = skip_space(config, end + 1)
                  if (substr(config, position, 1) == ":") {
                    root_outbounds_count++
                    position = skip_space(config, position + 1)
                    if (root_outbounds_count == 1 && substr(config, position, 1) == "[") target_position = position
                  }
                }
                i = end
                continue
              }
              if (character == "{") {
                if (structure_depth == 0) {
                  root_started = 1
                }
                if (in_outbounds && structure_depth == target_depth &&
                    structure_stack[structure_depth] == "[" && !object_start) {
                  object_start = i
                }
                structure_stack[++structure_depth] = "{"
              } else if (character == "}") {
                if (structure_depth < 1 || structure_stack[structure_depth] != "{") return 0
                if (object_start && structure_depth == target_depth + 1) {
                  objects[++object_count] = substr(config, object_start, i - object_start + 1)
                  object_start = 0
                }
                delete structure_stack[structure_depth]
                structure_depth--
                if (structure_depth == 0) root_complete = 1
              } else if (character == "[") {
                if (structure_depth == 0) return 0
                structure_stack[++structure_depth] = "["
                if (i == target_position) {
                  in_outbounds = 1
                  target_depth = structure_depth
                }
              } else if (character == "]") {
                if (structure_depth < 1 || structure_stack[structure_depth] != "[") return 0
                if (in_outbounds && structure_depth == target_depth) in_outbounds = 0
                delete structure_stack[structure_depth]
                structure_depth--
              }
            }
            return structure_depth == 0 && root_started && root_complete &&
              root_outbounds_count == 1 && target_position > 0 && !object_start && object_count > 0
          }
          BEGIN {
            IGNORECASE = 0
            split("ai-chatgpt ai-gemini ai-grok ai-claude", names)
            expected_url["ai-chatgpt"] = "https://chatgpt.com/"
            expected_url["ai-gemini"] = "https://gemini.google.com/"
            expected_url["ai-grok"] = "https://grok.com/"
            expected_url["ai-claude"] = "https://claude.ai/"
            for (i in names) {
              wanted[names[i]] = 1
              wanted_auto[names[i] "-auto"] = names[i]
            }
          }
          { config = config $0 "\n" }
          END {
            if (!json_syntax_valid(config) || !collect_outbounds(config)) exit 1
            for (i = 1; i <= object_count; i++) {
              tag = field_string(objects[i], "tag")
              tag_valid = field_valid
              if (tag_valid) tags[tag] = 1
              type = field_string(objects[i], "type")
              if (!field_valid) continue
              if (type ~ /^(shadowsocks|vmess|vless|trojan|hysteria2|anytls|tuic)$/) {
                node_server = field_string(objects[i], "server")
                server_valid = field_valid && node_server != ""
                node_port = field_scalar(objects[i], "server_port")
                port_valid = field_valid && node_port ~ /^[0-9]+$/ &&
                  node_port + 0 >= 1 && node_port + 0 <= 65535
                if (type == "shadowsocks") {
                  schema_valid = field_nonempty_string(objects[i], "method") &&
                    field_nonempty_string(objects[i], "password")
                } else if (type == "vmess" || type == "vless") {
                  schema_valid = field_nonempty_string(objects[i], "uuid")
                } else if (type == "trojan" || type == "hysteria2" || type == "anytls") {
                  schema_valid = field_nonempty_string(objects[i], "password")
                } else if (type == "tuic") {
                  schema_valid = field_nonempty_string(objects[i], "uuid") &&
                    field_nonempty_string(objects[i], "password")
                } else {
                  schema_valid = 0
                }
                if (!tag_valid || tag == "" || reserved_tag(tag) || !server_valid ||
                    !port_valid || !schema_valid) {
                  invalid_node = 1
                }
                if (tag in node_tags) {
                  duplicate_node_tag = 1
                } else {
                  node_tags[tag] = 1
                  node_order[++node_count] = tag
                  if (!mainland(tag)) {
                    eligible_nodes[tag] = 1
                    eligible_count++
                  }
                }
              }
            }
            if (duplicate_node_tag || invalid_node) bad = 1
            for (i = 1; i <= object_count; i++) {
              object = objects[i]
              tag = field_string(object, "tag")
              if (!field_valid) continue
              if (tag == "proxy") {
                proxy_count++
                proxy_object = object
                continue
              }
              if (tag == "proxy-auto") {
                proxy_auto_count++
                proxy_auto_object = object
                continue
              }
              if (tag == "ai-proxy") {
                ai_proxy_count++
                if (field_string(object, "type") != "selector" || !field_valid) bad = 1
                ai_member_count = field_array(object, "outbounds", ai_member)
                default_member = field_string(object, "default")
                if (!field_valid || ai_member_count < 0) bad = 1
                if (ai_member_count == 1 && ai_member[1] == "block") {
                  if (default_member != "block" || eligible_count != 0) bad = 1
                } else {
                  if (ai_member_count < 1 || default_member != ai_member[1]) bad = 1
                  for (j = 1; j <= ai_member_count; j++) {
                    if (!(ai_member[j] in eligible_nodes)) bad = 1
                  }
                }
                continue
              }
              if (tag in wanted) {
                count[tag]++
                group_object[tag] = object
              } else if (tag in wanted_auto) {
                auto_count[tag]++
                auto_object[tag] = object
              }
            }
            if (proxy_count != 1) bad = 1
            proxy = proxy_object
            if (field_string(proxy, "type") != "selector" || !field_valid) bad = 1
            proxy_member_count = field_array(proxy, "outbounds", proxy_member)
            proxy_default = field_string(proxy, "default")
            if (!field_valid || proxy_member_count < 0) bad = 1
            if (node_count > 0) {
              if (proxy_auto_count != 1 || proxy_default != node_order[1] ||
                  proxy_member_count != node_count + 3 || proxy_member[node_count + 1] != "proxy-auto" ||
                  proxy_member[node_count + 2] != "direct" || proxy_member[node_count + 3] != "block") bad = 1
              for (j = 1; j <= node_count; j++) {
                if (proxy_member[j] != node_order[j]) bad = 1
              }
              proxy_auto = proxy_auto_object
              if (field_string(proxy_auto, "type") != "urltest" || !field_valid ||
                  field_string(proxy_auto, "url") != expected_proxy_url || !field_valid ||
                  field_string(proxy_auto, "interval") != expected_proxy_interval || !field_valid ||
                  field_scalar(proxy_auto, "tolerance") != "30" || !field_valid ||
                  field_string(proxy_auto, "idle_timeout") != "10m" || !field_valid ||
                  field_scalar(proxy_auto, "interrupt_exist_connections") != "false" || !field_valid) bad = 1
              proxy_auto_member_count = field_array(proxy_auto, "outbounds", proxy_auto_member)
              if (proxy_auto_member_count != node_count) bad = 1
              for (j = 1; j <= proxy_auto_member_count; j++) {
                if (proxy_auto_member[j] != node_order[j]) bad = 1
              }
            } else {
              if (proxy_auto_count != 0 || proxy_default != "block" ||
                  proxy_member_count != 1 || proxy_member[1] != "block") bad = 1
            }
            if (ai_proxy_count != 1) bad = 1
            for (name in wanted) {
              if (count[name] != 1) {
                bad = 1
                continue
              }
              object = group_object[name]
              if (field_string(object, "type") != "selector" || !field_valid) bad = 1
              member_count = field_array(object, "outbounds", member)
              if (member_count < 0) bad = 1
              auto_tag = name "-auto"
              group_default = field_string(object, "default")
              if (!field_valid) bad = 1
              if (eligible_count > 0) {
                if (member_count != eligible_count + 2 || member[eligible_count + 1] != "block" || member[eligible_count + 2] != auto_tag ||
                    group_default != member[1] || !(member[1] in eligible_nodes)) bad = 1
                for (j = 1; j <= eligible_count; j++) {
                  if (member[j] != ai_member[j] || !(member[j] in eligible_nodes)) bad = 1
                }
                if (auto_count[auto_tag] != 1) {
                  bad = 1
                  continue
                }
                auto = auto_object[auto_tag]
                if (field_string(auto, "type") != "urltest" || !field_valid ||
                    field_string(auto, "interval") != "10m" || !field_valid ||
                    field_scalar(auto, "tolerance") != "30" || !field_valid ||
                    field_string(auto, "idle_timeout") != "10m" || !field_valid ||
                    field_scalar(auto, "interrupt_exist_connections") != "false" || !field_valid) bad = 1
                url = field_string(auto, "url")
                if (!field_valid) bad = 1
                if (url != expected_url[name]) bad = 1
                auto_member_count = field_array(auto, "outbounds", auto_member)
                if (auto_member_count != ai_member_count) bad = 1
                for (j = 1; j <= auto_member_count; j++) {
                  if (auto_member[j] != ai_member[j] || !(auto_member[j] in eligible_nodes)) bad = 1
                }
              } else {
                if (member_count != 1 || member[1] != "block" || group_default != "block" ||
                    auto_count[auto_tag] != 0) bad = 1
              }
            }
            exit bad ? 1 : 0
          }
        ' "$_ai_config"
        _ai_rc=$?
    fi
    unset _ai_config _ai_expected_proxy_url _ai_expected_proxy_interval
    return "$_ai_rc"
}

magicnet_json_array_csv() {
    _values="$1"
    _first=1
    printf '['
    _old_ifs=$IFS
    IFS=,
    for _value in $_values; do
        _value=$(printf '%s' "$_value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$_value" ] || continue
        [ "$_first" -eq 1 ] || printf ','
        printf '"%s"' "$(magicnet_json_escape "$_value")"
        _first=0
    done
    IFS=$_old_ifs
    printf ']'
}

magicnet_selector_tags_json() {
    _selector_tags="$1"
    _selector_fallback="$2"
    _selector_items=$(
        {
            while IFS= read -r _selector_raw_tag; do
                magicnet_json_escape "$_selector_raw_tag"
                printf '\n'
            done <<EOF
$_selector_tags
$_selector_fallback
direct
block
EOF
        } | awk 'NF && !seen[$0]++'
    )
    _selector_first=1
    printf '['
    while IFS= read -r _selector_tag; do
        [ -n "$_selector_tag" ] || continue
        [ "$_selector_first" -eq 1 ] || printf ', '
        printf '"%s"' "$_selector_tag"
        _selector_first=0
    done <<EOF
$_selector_items
EOF
    printf ']'
    unset _selector_tags _selector_fallback _selector_items _selector_first _selector_tag _selector_raw_tag
}

magicnet_selector_default_tag() {
    _tags="$1"
    _fallback="$2"
    _first=$(printf '%s\n' "$_tags" | awk 'NF{print; exit}')
    printf '%s\n' "${_first:-$_fallback}"
}

magicnet_emit_selector_json() {
    _tag="$1"
    _tags="$2"
    _fallback="${3:-direct}"
    printf '    {\n'
    printf '      "type": "selector",\n'
    printf '      "tag": "%s",\n' "$(magicnet_json_escape "$_tag")"
    printf '      "outbounds": '
    magicnet_selector_tags_json "$_tags" "$_fallback"
    printf ',\n'
    printf '      "default": "%s"\n' "$(magicnet_json_escape "$(magicnet_selector_default_tag "$_tags" "$_fallback")")"
    printf '    }'
}

magicnet_emit_selector_json_exact() {
    _exact_tag="$1"
    _exact_tags="$2"
    _exact_fallback="$3"
    _exact_items=$(printf '%s\n%s\n' "$_exact_fallback" "$_exact_tags" | awk 'NF && !seen[$0]++')
    _exact_first=1
    printf '    {\n'
    printf '      "type": "selector",\n'
    printf '      "tag": "%s",\n' "$(magicnet_json_escape "$_exact_tag")"
    printf '      "outbounds": ['
    while IFS= read -r _exact_item; do
        [ -n "$_exact_item" ] || continue
        [ "$_exact_first" -eq 1 ] || printf ', '
        printf '"%s"' "$(magicnet_json_escape "$_exact_item")"
        _exact_first=0
    done <<EOF
$_exact_items
EOF
    printf '],\n'
    printf '      "default": "%s"\n' "$(magicnet_json_escape "$_exact_fallback")"
    printf '    }'
    unset _exact_tag _exact_tags _exact_fallback _exact_items _exact_first _exact_item
}

magicnet_uri_query_value() {
    _key="$1"
    _query="$2"
    printf '%s' "$_query" | tr '&' '\n' |
        sed -n "s/^${_key}=//p" | tail -n 1
}

magicnet_b64_decode() {
    _value=$(printf '%s' "$1" | tr '_-' '/+')
    _pad=$(((${#_value} + 3) % 4))
    case "$_pad" in
    2) _value="${_value}==" ;;
    3) _value="${_value}=" ;;
    esac
    printf '%s' "$_value" | base64 -d 2>/dev/null
}

magicnet_percent_decode() {
    _value="$1"
    _out=""
    while [ -n "$_value" ]; do
        case "$_value" in
        %??*)
            _hex=${_value#%}
            _hex=${_hex%"${_hex#??}"}
            case "$_hex" in
            *[!0-9A-Fa-f]*)
                _out="${_out}%"
                _value=${_value#%}
                ;;
            *)
                _out="${_out}\\x${_hex}"
                _value=${_value#???}
                ;;
            esac
            ;;
        +*)
            _out="${_out} "
            _value=${_value#?}
            ;;
        *)
            _out="${_out}${_value%"${_value#?}"}"
            _value=${_value#?}
            ;;
        esac
    done
    printf '%b\n' "$_out"
}

magicnet_share_link_tag() {
    _link="$1"
    _fallback="$2"
    _tag=$(printf '%s' "$_link" | sed -n 's/.*#//p')
    [ "$_tag" != "$_link" ] && [ -n "$_tag" ] || _tag="$_fallback"
    _tag=$(magicnet_percent_decode "$_tag")
    printf '%s\n' "$_tag"
}

magicnet_tag_matches_any() {
    _tag="$1"
    shift
    for _needle in "$@"; do
        printf '%s' "$_tag" | grep -F "$_needle" >/dev/null 2>&1 && return 0
    done
    return 1
}

magicnet_singbox_is_info_tag() {
    _tag="$1"
    magicnet_tag_matches_any "$_tag" \
        "剩余流量" "到期" "过期" "过期时间" "套餐" "官网" "订阅" \
        "Traffic" "traffic" "Expire" "expire" "Expired" "expired" \
        "Subscription" "subscription" "官网地址" "官方网站" "更新订阅" &&
        return 0
    return 1
}

magicnet_singbox_subscription_filter_file() {
    if [ -n "${MAGICNET_SUB_FILTER_FILE:-}" ]; then
        printf '%s\n' "$MAGICNET_SUB_FILTER_FILE"
    elif [ -n "${MODDIR:-}" ]; then
        printf '%s\n' "${MODDIR}/.config/sing-box/subscription-filter.list"
    else
        printf '%s\n' /dev/null
    fi
}

magicnet_singbox_tag_matches_filter() {
    _filter_tag="$1"
    _filter_file=$(magicnet_singbox_subscription_filter_file)
    [ -n "$_filter_tag" ] && [ -s "$_filter_file" ] || {
        unset _filter_tag _filter_file
        return 1
    }
    while IFS= read -r _filter_keyword || [ -n "$_filter_keyword" ]; do
        _filter_keyword=$(printf '%s' "$_filter_keyword" | tr -d '\r')
        [ -n "$_filter_keyword" ] || continue
        if printf '%s' "$_filter_tag" | grep -i -F -e "$_filter_keyword" >/dev/null 2>&1; then
            unset _filter_tag _filter_file _filter_keyword
            return 0
        fi
    done <"$_filter_file"
    unset _filter_tag _filter_file _filter_keyword
    return 1
}

if ! command -v error >/dev/null 2>&1; then
    error() { printf '%s\n' "ERROR: $1"; }
fi

if ! command -v warn >/dev/null 2>&1; then
    warn() { printf '%s\n' "WARN: $1"; }
fi

if ! command -v success >/dev/null 2>&1; then
    success() { printf '%s\n' "$1"; }
fi

magicnet_yaml_value() {
    _key="$1"
    _value=$(
        sed -n "s/^[[:space:]]*${_key}:[[:space:]]*//p" "$_node_file" | tail -n 1
    )
    if [ -z "$_value" ]; then
        _value=$(
            sed -n "s/.*[{,][[:space:]]*${_key}:[[:space:]]*\\([^,}]*\\).*/\\1/p" "$_node_file" |
                tail -n 1
        )
    fi
    printf '%s\n' "$_value" |
        tr -d '\r' |
        sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//'
    unset _value
}

magicnet_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
    esac
}

magicnet_singbox_subscription_url_file() {
    printf '%s\n' "${MAGICNET_SUB_URL_FILE:-${MODDIR}/.config/sing-box/subscription.url}"
}

magicnet_singbox_subscription_user_agent_file() {
    printf '%s\n' "${MAGICNET_SUB_USER_AGENT_FILE:-${MODDIR}/.config/sing-box/subscription.user-agent}"
}

magicnet_singbox_subscription_source_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/subscription.yaml"
}

magicnet_singbox_subscription_source_dir() {
    printf '%s\n' "${MODDIR}/.config/sing-box"
}

magicnet_singbox_subscription_config_file() {
    printf '%s\n' "${MAGICNET_SUB_CONFIG_FILE:-${MODDIR}/.config/sing-box/config.json}"
}

magicnet_singbox_subscription_cache_dir() {
    printf '%s\n' "${MODDIR}/.state/sing-box/subscription-cache"
}

magicnet_singbox_subscription_status_file() {
    printf '%s\n' "${MODDIR}/.state/sing-box/subscription-status"
}

magicnet_subscription_schedule_file() {
    printf '%s\n' "${MODDIR}/.config/magicnet/subscription-refresh-hours"
}

magicnet_singbox_subscription_fingerprint() {
    _fingerprint_value="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$_fingerprint_value" | sha256sum | awk '{print $1}'
    elif command -v toybox >/dev/null 2>&1 && toybox sha256sum </dev/null >/dev/null 2>&1; then
        printf '%s' "$_fingerprint_value" | toybox sha256sum | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$_fingerprint_value" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
    else
        # Persistent cache identity is security-sensitive. CRC/cksum is not a
        # strong identity proof and must never select data for another URL.
        unset _fingerprint_value
        return 1
    fi
    unset _fingerprint_value
}
