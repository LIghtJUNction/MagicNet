# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

type magicnet_source_primitives >/dev/null 2>&1 || {
    if [ -n "${BASH_VERSION:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
        # BASH_SOURCE is guarded by the Bash-only branch above.
        # shellcheck disable=SC3054
        . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/primitives.sh"
    else
        . "${MODDIR}/lib/magicnet/primitives.sh"
    fi
}
magicnet_source_primitives
type magicnet_singbox_config_file >/dev/null 2>&1 || . "$(magicnet_lib_dir)/subscribe_bootstrap.sh"

magicnet_singbox_tag_is_reserved() {
    case "$1" in
    proxy-auto | proxy | select | lan | hotspot | ad-block | ad-allow | cn-direct | \
        chain | chain-hop1 | chain-exit | chain-auto | magicnet-chain-* | \
        apple-cn | microsoft-cn | google-cn | icloud | bing | dns-guard | network-test | \
        ai-proxy | ai-chatgpt | ai-chatgpt-auto | ai-gemini | ai-gemini-auto | \
        ai-grok | ai-grok-auto | ai-claude | ai-claude-auto | proxy-rule | dev-proxy | \
        social-proxy | media-proxy | game-proxy | telegram-proxy | google-proxy | youtube-proxy | github-proxy | discord-proxy | netflix-proxy | spotify-proxy | twitter-proxy | whatsapp-proxy | download-direct | \
        final | direct | block | warp)
        return 0
        ;;
    *) return 1 ;;
    esac
}

magicnet_singbox_ai_selectors_canonical() (
    _ai_config="$1"
    _ai_expected_proxy_url="${2:-https://www.gstatic.com/generate_204}"
    _ai_expected_proxy_interval="${3:-3m}"
    _ai_jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_ai_jq" ] || return 1
    _ai_lib="$(magicnet_jq_ai_tags_lib)"
    "$_ai_jq" -L "$_ai_lib" \
        --arg expected_proxy_url "$_ai_expected_proxy_url" \
        --arg expected_proxy_interval "$_ai_expected_proxy_interval" \
        -e 'include "ai-node-tags";
      def proxy_node:
        ((.tag // "") | startswith("magicnet-chain-") | not)
          and (.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
          or .type == "hysteria2" or .type == "anytls" or .type == "tuic" or .type == "socks");
      def reserved_tag:
        . as $tag
        | [
            "proxy-auto", "proxy", "select", "lan", "hotspot", "ad-block", "ad-allow", "cn-direct",
            "chain", "chain-hop1", "chain-exit", "chain-auto",
            "apple-cn", "microsoft-cn", "google-cn", "icloud", "bing", "dns-guard", "network-test",
            "ai-proxy", "ai-chatgpt", "ai-chatgpt-auto", "ai-gemini", "ai-gemini-auto",
            "ai-grok", "ai-grok-auto", "ai-claude", "ai-claude-auto", "proxy-rule", "dev-proxy",
            "social-proxy", "media-proxy", "game-proxy", "telegram-proxy", "google-proxy", "youtube-proxy", "github-proxy", "discord-proxy", "netflix-proxy", "spotify-proxy", "twitter-proxy", "whatsapp-proxy", "download-direct",
            "final", "direct", "block", "warp"
          ]
        | index($tag) != null or ($tag | startswith("magicnet-chain-"));
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
            elif .type == "socks" then
              (.version == "4" or .version == "4a" or .version == "5")
                and (((has("username") | not) and (has("password") | not))
                  or ((.username | type == "string" and length > 0)
                    and (.password | type == "string" and length > 0)))
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
      | ([.outbounds[]? | select(.tag == "chain")]) as $chain_groups
      | (($chain_groups | length) == 1) as $chain_active
      | [.outbounds[]? | select(proxy_node)] as $nodes
      | [$nodes[] | .tag] as $node_tags
      | ($node_tags | prioritize_ai_tags) as $ai_tags
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
            and (($proxies[0].outbounds == ($node_tags + ["proxy-auto", "direct", "block"]))
              or ($proxies[0].outbounds == ($node_tags + ["proxy-auto", "chain", "direct", "block"])
                and ($chain_groups | length) == 1))
            and (($proxies[0].default == $node_tags[0])
              or ($proxies[0].default == "chain" and ($chain_groups | length) == 1))
          else
            ($proxy_autos | length) == 0
              and $proxies[0].type == "selector"
              and $proxies[0].tag == "proxy"
              and $proxies[0].outbounds == ["block"]
              and $proxies[0].default == "block"
          end)
        and ($ai_proxies | length) == 1
        and ($ai_proxies[0].type == "selector")
        and (if $chain_active
             then $ai_proxies[0].type == "selector"
               and $ai_proxies[0].outbounds == ["chain", "block"]
               and $ai_proxies[0].default == "chain"
             else (($ai_proxies[0].outbounds == ["block"]
                and $ai_proxies[0].default == "block" and ($ai_tags | length) == 0)
               or (($ai_proxies[0].outbounds | length) > 0
                and $ai_proxies[0].default == $ai_proxies[0].outbounds[0]
                and $ai_proxies[0].outbounds == $ai_tags
                and ($ai_proxies[0].outbounds | all(. as $member
                  | ($node_tags | index($member) != null)
                    and ($member | blocked_ai_node_tag | not)))))
             end)
        and ($auto_groups | length) == (if ($ai_tags | length) > 0 then 4 else 0 end)
        and ($services | all(. as $service
          | ($service.name + "-auto") as $auto_name
          | ([ $groups[] | select(.tag == $service.name) ]) as $service_groups
          | ([ $auto_groups[] | select(.tag == $auto_name) ]) as $service_auto_groups
          | ($service_groups | length) == 1
            and $service_groups[0].type == "selector"
            and $service_groups[0].default
              == (if $chain_active then "chain"
                  elif ($ai_tags | length) > 0 then $ai_tags[0]
                  else "block" end)
            and ($service_groups[0].outbounds
              == (if $chain_active then ["chain", "block", $auto_name]
                  elif ($ai_tags | length) > 0 then ($ai_tags + ["block", $auto_name])
                  else ["block"] end))
            and ($service_groups[0].outbounds | all(. as $member | $tags | index($member) != null))
            and (if $chain_active then
              ($service_auto_groups | length) == 1
                and $service_auto_groups[0].type == "urltest"
                and $service_auto_groups[0].outbounds == ["chain"]
                and $service_auto_groups[0].url == $service.url
                and $service_auto_groups[0].interval == "10m"
                and $service_auto_groups[0].tolerance == 30
                and $service_auto_groups[0].idle_timeout == "10m"
                and $service_auto_groups[0].interrupt_exist_connections == false
            elif ($ai_tags | length) > 0 then
              ($service_auto_groups | length) == 1
                and $service_auto_groups[0].type == "urltest"
                and $service_auto_groups[0].outbounds == $ai_proxies[0].outbounds
                and ($service_auto_groups[0].outbounds | all(. as $member
                  | ($node_tags | index($member) != null) and ($member | blocked_ai_node_tag | not)))
                and $service_auto_groups[0].url == $service.url
                and $service_auto_groups[0].interval == "10m"
                and $service_auto_groups[0].tolerance == 30
                and $service_auto_groups[0].idle_timeout == "10m"
                and $service_auto_groups[0].interrupt_exist_connections == false
              else ($service_auto_groups | length) == 0
              end)))
    ' "$_ai_config" >/dev/null 2>&1
)

magicnet_json_array_csv() (
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
)

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

magicnet_uri_query_value() {
    _key="$1"
    _query="$2"
    _query_value=$(printf '%s' "$_query" | tr '&' '\n' |
        sed -n "s/^${_key}=//p" | tail -n 1)
    if [ -n "$_query_value" ]; then
        magicnet_percent_decode "$_query_value"
        _rc=$?
        unset _query_value
        return "$_rc"
    fi
    unset _query_value
    return 0
}

magicnet_b64_decode() {
    _value=$(printf '%s' "$1" | tr '_-' '/+')
    case "$_value" in
    '' | *[!A-Za-z0-9+/=]*) return 1 ;;
    esac
    _unpadded=${_value%%=*}
    _padding=${_value#"$_unpadded"}
    case "$_padding" in
    '' | '=' | '==') ;;
    *) return 1 ;;
    esac
    _length=${#_unpadded}
    [ "$_length" -gt 0 ] || return 1
    [ $((_length % 4)) -ne 1 ] || return 1
    if [ -n "$_padding" ]; then
        [ $(((${#_value}) % 4)) -eq 0 ] || return 1
        case "${#_padding}:$((_length % 4))" in
        1:3 | 2:2) ;;
        *) return 1 ;;
        esac
    fi
    _pad=$(( (4 - (_length % 4)) % 4 ))
    case "$_pad" in
    0) _value="$_unpadded" ;;
    1) _value="${_unpadded}=" ;;
    2) _value="${_unpadded}==" ;;
    3) return 1 ;;
    esac
    printf '%s' "$_value" | base64 -d 2>/dev/null
}

magicnet_singbox_normalize_port() {
    _port="$1"
    case "$_port" in
    '' | *[!0-9]*) return 1 ;;
    esac
    _port=$(printf '%s' "$_port" | sed 's/^0*//')
    [ -n "$_port" ] || return 1
    [ "${#_port}" -le 5 ] || return 1
    [ "$_port" -ge 1 ] 2>/dev/null && [ "$_port" -le 65535 ] 2>/dev/null || return 1
    printf '%s\n' "$_port"
}

magicnet_percent_decode() {
    _value="$1"
    _out=""
    while [ -n "$_value" ]; do
        case "$_value" in
        %*)
            _hex=${_value#%}
            [ "${#_hex}" -ge 2 ] || return 1
            _hex=${_hex%"${_hex#??}"}
            case "$_hex" in
            *[!0-9A-Fa-f]*) return 1 ;;
            *)
                _out="${_out}\\x${_hex}"
                _value=${_value#???}
                ;;
            esac
            ;;
        +*)
            # `+` is a literal URI character; spaces must be percent-encoded.
            _out="${_out}+"
            _value=${_value#?}
            ;;
        *)
            _char=${_value%"${_value#?}"}
            case "$_char" in
            \\) _out="${_out}\\\\" ;;
            *) _out="${_out}${_char}" ;;
            esac
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

magicnet_singbox_native_yaml() (
    # One bounded lexer backs both scalar lookup and fallback completeness.
    # It handles flat block/flow mappings and literal quoted keys/scalars;
    # YAML tags, aliases, collections, block scalars and double-quote escapes
    # in consumed fields require the full converter instead of literal output.
    LC_ALL=C awk -v mode="$1" -v wanted="${3:-}" '
        # KernelSU BusyBox awk can crash when sub() trims UTF-8 strings.
        # Byte scans preserve the same C-locale whitespace without that path.
        function ltrim(value) {
            while (length(value) && index(ws, substr(value, 1, 1))) value = substr(value, 2)
            return value
        }
        function rtrim(value) {
            while (length(value) && index(ws, substr(value, length(value), 1))) value = substr(value, 1, length(value) - 1)
            return value
        }
        function trim(value) { value = ltrim(value); return rtrim(value) }
        function quoted_end(value, quote, i, c) {
            quote = substr(value, 1, 1)
            for (i = 2; i <= length(value); i++) {
                c = substr(value, i, 1)
                if (quote == "\"" && c == "\\") { i++; continue }
                if (c != quote) continue
                if (quote == apostrophe && substr(value, i + 1, 1) == quote) { i++; continue }
                return i
            }
            return 0
        }
        function scalar(value, is_flow, quote, end, rest, i, c) {
            scalar_ok = 1
            value = trim(value)
            quote = substr(value, 1, 1)
            if (quote == "\"" || quote == apostrophe) {
                end = quoted_end(value)
                if (!end) { scalar_ok = 0; return "" }
                rest = trim(substr(value, end + 1))
                if (rest != "" && substr(rest, 1, 1) != "#") scalar_ok = 0
                value = substr(value, 2, end - 2)
                if (quote == "\"" && index(value, "\\")) scalar_ok = 0
                if (quote == apostrophe) gsub(apostrophe apostrophe, apostrophe, value)
                return value
            }
            # A hash is a YAML comment only at the start or after whitespace.
            for (i = 1; i <= length(value); i++) {
                if (substr(value, i, 1) == "#" && (i == 1 || index(ws, substr(value, i - 1, 1)))) {
                    value = rtrim(substr(value, 1, i - 1)); break
                }
            }
            if (value == "" || index("!&*|>[{", substr(value, 1, 1)) || value ~ /^(~|null|Null|NULL)$/) scalar_ok = 0
            if (is_flow && (index(value, "[") || index(value, "]") ||
                            index(value, "{") || index(value, "}"))) scalar_ok = 0
            if (value ~ /:[[:space:]]/) scalar_ok = 0
            return value
        }
        function field(text, is_flow, quote, end, key, raw, value) {
            text = ltrim(text)
            quote = substr(text, 1, 1)
            if (quote == "\"" || quote == apostrophe) {
                end = quoted_end(text)
                if (!end) { bad = 1; return }
                key = substr(text, 2, end - 2)
                text = ltrim(substr(text, end + 1))
                if (substr(text, 1, 1) != ":") return
                if (index(key, "\\") || index(key, apostrophe apostrophe)) { bad = 1; return }
                raw = ltrim(substr(text, 2))
            } else {
                end = index(text, ":")
                if (!end) return
                key = rtrim(substr(text, 1, end - 1))
                raw = ltrim(substr(text, end + 1))
            }
            if (mode == "source" && key ~ /^(<<|ws-opts|grpc-opts|http-opts|h2-opts|reality-opts|plugin|plugin-opts|obfs|alpn|client-fingerprint|fingerprint)$/) bad = 1
            if ((mode == "value" && key == wanted) ||
                (mode == "node" && key ~ /^(name|type|server|port|cipher|password|version|username|uuid|alterId|network|tls|servername|sni|flow|client-fingerprint|fingerprint|skip-cert-verify|insecure|congestion-controller|congestion_control|udp-relay-mode|udp_relay_mode)$/)) {
                value = scalar(raw, is_flow)
                if (mode == "node" && !scalar_ok) bad = 1
                if (mode == "node" && key ~ /^(tls|skip-cert-verify|insecure)$/ &&
                    tolower(value) !~ /^(1|0|true|false|yes|no|on|off)$/) bad = 1
                if (mode == "value") result = value
            }
        }
        function flow(line, i, c, quote, depth, begin, significant, rest) {
            depth = 0; begin = 2; significant = ""
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (quote != "") {
                    if (quote == "\"" && c == "\\") { i++; continue }
                    if (c != quote) continue
                    if (quote == apostrophe && substr(line, i + 1, 1) == quote) { i++; continue }
                    quote = ""; significant = c; continue
                }
                if ((c == "\"" || c == apostrophe) && (significant == "" || index(":{[,", significant))) {
                    quote = c; continue
                }
                if (c == "{" || c == "[") depth++
                else if (c == "}" || c == "]") {
                    depth--
                    if (depth == 0) {
                        field(substr(line, begin, i - begin), 1)
                        rest = trim(substr(line, i + 1))
                        if (rest != "" && substr(rest, 1, 1) != "#") bad = 1
                        return
                    }
                } else if (c == "," && depth == 1) {
                    field(substr(line, begin, i - begin), 1); begin = i + 1
                }
                if (!index(ws, c)) significant = c
            }
            # Multiline/unterminated flow mappings exceed the native grammar.
            bad = 1
        }
        BEGIN { ws = " \t\r\n\v\f"; apostrophe = sprintf("%c", 39) }
        {
            line = ltrim($0)
            if (substr(line, 1, 1) == "-") line = ltrim(substr(line, 2))
            if (line == "" || substr(line, 1, 1) == "#") next
            if (substr(line, 1, 1) == "{") flow(line)
            else field(line, 0)
        }
        END {
            if (bad) exit 1
            if (mode == "value") printf "%s\n", result
        }
    ' "$2"
)

magicnet_yaml_value() (
    # Dynamically scoped by the current isolated node parser/completeness check.
    # shellcheck disable=SC2154
    magicnet_singbox_native_yaml value "$_node_file" "$1"
)

magicnet_singbox_native_clash_complete() (
    magicnet_singbox_native_yaml source "$1"
)

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

magicnet_singbox_subscription_cache_dir() {
    printf '%s\n' "${MODDIR}/.state/sing-box/subscription-cache"
}

magicnet_singbox_subscription_status_file() {
    printf '%s\n' "${MODDIR}/.state/sing-box/subscription-status"
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

magicnet_singbox_source_is_clash() {
    LC_ALL=C awk '
        BEGIN { ws = " \t\r\n\v\f"; bom = sprintf("%c%c%c", 239, 187, 191) }
        {
            line = $0
            if (NR == 1 && substr(line, 1, 3) == bom) line = substr(line, 4)
            while (length(line) && index(ws, substr(line, 1, 1))) line = substr(line, 2)
            if (substr(line, 1, 8) != "proxies:") next
            line = substr(line, 9)
            while (length(line) && index(ws, substr(line, 1, 1))) line = substr(line, 2)
            if (line == "" || substr(line, 1, 1) == "#" || substr(line, 1, 1) == "[") { found = 1; exit }
        }
        END { exit !found }
    ' "$1"
}
