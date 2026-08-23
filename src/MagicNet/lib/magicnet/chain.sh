# shellcheck shell=ash
#
# Materialize the local two-hop sing-box proxy chain.
#
# The policy file contains node tags only.  The subscription pipeline owns the
# real node credentials; this module only creates deterministic child
# outbounds with a detour to the selected upstream group.

magicnet_singbox_chain_policy_file() {
    printf '%s\n' "${MODDIR}/.config/magicnet/proxy-chain.json"
}

magicnet_singbox_chain_apply() {
    _chain_config="${1:-$(magicnet_singbox_config_file)}"
    _chain_policy_file="$(magicnet_singbox_chain_policy_file)"
    _chain_jq="$(magicnet_require_jq "packaged jq is unavailable; refusing to materialize the proxy chain")" || {
        unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp _chain_rc
        return 1
    }
    [ -s "$_chain_config" ] || {
        unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp _chain_rc
        return 1
    }
    [ -s "$_chain_policy_file" ] || {
        unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp _chain_rc
        return 0
    }

    _chain_policy="$($_chain_jq -c -e . "$_chain_policy_file" 2>/dev/null)" || {
        magicnet_warn "proxy chain policy is not valid JSON"
        unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp _chain_rc
        return 1
    }

    _chain_tmp="${_chain_config}.chain.$$"
    _chain_ai_lib="$(magicnet_jq_ai_tags_lib)"
    # shellcheck disable=SC2016
    if ! (umask 077; "$_chain_jq" -L "$_chain_ai_lib" \
        --argjson policy "$_chain_policy" \
        --arg prefix "magicnet-chain-" \
        -e 'include "ai-node-tags";
      def managed_tag($tag):
        (($tag | type) == "string" and ($tag | startswith($prefix)))
        or (["chain", "chain-hop1", "chain-exit", "chain-auto"] | index($tag) != null);
      def valid_tag:
        type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
      def unique_strings:
        reduce .[] as $item ([]; if index($item) == null then . + [$item] else . end);
      def proxy_node:
        (.tag | valid_tag and (managed_tag(.) | not))
          and (.server | type == "string" and length > 0)
          and (.server_port | type == "number" and . == floor and . >= 1 and . <= 65535)
          and (.type == "shadowsocks" or .type == "vmess" or .type == "vless"
            or .type == "trojan" or .type == "hysteria2" or .type == "anytls"
            or .type == "tuic" or .type == "socks");
      def policy_tags($key):
        if (($policy[$key] // []) | type) == "array"
        then ($policy[$key] | map(select(valid_tag)) | unique_strings)
        else error("proxy chain policy field must be an array: " + $key)
        end;
      (.outbounds // []) as $all
      | ($all | map(select((.tag // "") as $tag | (managed_tag($tag) | not)))) as $clean
      | ($clean | map(select(proxy_node) | .tag) | unique_strings) as $node_tags
      | ($clean
          | map(select(proxy_node and ((.detour // "") == "")) | .tag)
          | unique_strings) as $chain_safe_tags
      | ($node_tags | prioritize_ai_tags) as $ai_tags
      | (policy_tags("upstream")) as $requested_upstream
      | (policy_tags("exit")) as $requested_exit
      | ($requested_upstream
          | map(. as $tag | select(($chain_safe_tags | index($tag)) != null))) as $upstream
      | ($requested_exit
          | map(. as $tag | select(($chain_safe_tags | index($tag)) != null))) as $exit
      | (($policy.enabled // false) == true) as $enabled
      | ($policy.mode // "manual") as $mode
      | if ($mode != "manual" and $mode != "auto")
        then error("proxy chain mode must be manual or auto")
        elif $enabled and (($upstream | length) == 0 or ($exit | length) == 0)
        then error("enabled proxy chain requires at least one valid upstream and exit node")
        else
          ($enabled and ($upstream | length) > 0 and ($exit | length) > 0) as $chain_valid
          | ($exit
              | map(. as $source
                  | $clean[]
                  | select(.tag == $source)
                  | del(.detour)
                  | .tag = ("magicnet-chain-exit::" + $source)
                  | .detour = "chain-hop1"
                  | .network = "tcp")) as $chain_nodes
          | ($chain_nodes | map(.tag)) as $chain_exit_tags
          | ($clean | map(select(.tag == "proxy" and .type == "selector")) | .[0]) as $old_proxy
          | ($old_proxy.default // "") as $old_default
          | (if $chain_valid then "chain"
             elif (($node_tags | index($old_default)) != null
                or $old_default == "proxy-auto"
                or $old_default == "direct"
                or $old_default == "block") then $old_default
             elif ($node_tags | length) > 0 then $node_tags[0]
             else "block"
             end) as $proxy_default
          | (if ($node_tags | length) > 0
             then (($node_tags + ["proxy-auto"]
               + (if $chain_valid then ["chain"] else [] end)
               + ["direct", "block"]) | unique_strings)
             else ["block"]
             end) as $proxy_members
          | {"type":"selector", "tag":"proxy", "outbounds":$proxy_members,
             "default":$proxy_default} as $proxy
          | ($clean
              | map(if $chain_valid and .tag == "ai-proxy"
                   then .outbounds = ["chain", "block"] | .default = "chain"
                   elif $chain_valid
                     and (.tag == "ai-chatgpt" or .tag == "ai-gemini"
                       or .tag == "ai-grok" or .tag == "ai-claude")
                   then .outbounds = ["chain", "block", (.tag + "-auto")]
                     | .default = "chain"
                   elif $chain_valid
                     and (.tag == "ai-chatgpt-auto" or .tag == "ai-gemini-auto"
                       or .tag == "ai-grok-auto" or .tag == "ai-claude-auto")
                   then .outbounds = ["chain"]
                   elif ($chain_valid | not) and .tag == "ai-proxy"
                   then if ($ai_tags | length) > 0
                        then .outbounds = $ai_tags | .default = $ai_tags[0]
                        else .outbounds = ["block"] | .default = "block"
                        end
                   elif ($chain_valid | not)
                     and (.tag == "ai-chatgpt" or .tag == "ai-gemini"
                       or .tag == "ai-grok" or .tag == "ai-claude")
                   then if ($ai_tags | length) > 0
                        then .outbounds = ($ai_tags + ["block", (.tag + "-auto")])
                          | .default = $ai_tags[0]
                        else .outbounds = ["block"] | .default = "block"
                        end
                   elif ($chain_valid | not)
                     and (.tag == "ai-chatgpt-auto" or .tag == "ai-gemini-auto"
                       or .tag == "ai-grok-auto" or .tag == "ai-claude-auto")
                   then if ($ai_tags | length) > 0
                        then .outbounds = $ai_tags
                        else empty
                        end
                   else .
                   end)) as $policy_clean
          | (if $chain_valid
             then [
               {"type":"selector", "tag":"chain-hop1",
                "outbounds":($upstream + ["block"]), "default":$upstream[0]},
               $chain_nodes[],
               {"type":"selector", "tag":"chain-exit",
                "outbounds":($chain_exit_tags + ["block"]), "default":$chain_exit_tags[0]},
               {"type":"urltest", "tag":"chain-auto", "outbounds":$chain_exit_tags,
                "url":"https://www.gstatic.com/generate_204", "interval":"3m",
                "tolerance":30, "idle_timeout":"10m",
                "interrupt_exist_connections":false},
               {"type":"selector", "tag":"chain",
                "outbounds":(["chain-exit", "chain-auto", "block"]),
                "default":(if $mode == "auto" then "chain-auto" else "chain-exit" end)}
             ]
             else []
             end) as $chain_outbounds
          | .outbounds = ($chain_outbounds + [$proxy]
              + ($policy_clean | map(select((.tag // "") != "proxy"))))
        end
    ' "$_chain_config" >"$_chain_tmp"); then
        rm -f "$_chain_tmp" 2>/dev/null || true
        unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp _chain_rc
        return 1
    fi

    chmod 600 "$_chain_tmp" || {
        rm -f "$_chain_tmp" 2>/dev/null || true
        unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp _chain_rc
        return 1
    }
    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$_chain_tmp" -D "${_chain_config%/*}" >/dev/null 2>&1 || {
            magicnet_warn "generated sing-box proxy chain failed validation"
            rm -f "$_chain_tmp" 2>/dev/null || true
            unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp _chain_rc
            return 1
        }
    fi
    mv -f "$_chain_tmp" "$_chain_config" || {
        rm -f "$_chain_tmp" 2>/dev/null || true
        unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp _chain_rc
        return 1
    }
    chmod 600 "$_chain_config"
    _chain_rc=$?
    unset _chain_config _chain_policy_file _chain_jq _chain_policy _chain_tmp
    return "$_chain_rc"
}
