magicnet_singbox_apply_transparent_mode() {
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || return 0
    _dns_strategy="$(magicnet_singbox_dns_strategy_for_mode "$_config" "tun")"
    _tun_mtu="$(magicnet_tun_mtu)"
    _udp_timeout="$(magicnet_udp_timeout)"
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || {
        magicnet_warn "packaged jq is unavailable; transparent config apply rejected"
        return 1
    }
    _tmp="${_config}.transparent-mode.new"
    # shellcheck disable=SC2016
    if (umask 077; "$_jq" \
        --arg dns_strategy "$_dns_strategy" \
        --argjson tun_mtu "$_tun_mtu" \
        --arg udp_timeout "$_udp_timeout" '
        def mixed_in:
          {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": 7892
          };
        def dns_in:
          {
            "type": "direct",
            "tag": "magicnet-dns-in",
            "listen": "127.0.0.1",
            "listen_port": 1053
          };
        def tun_in:
          {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "magicnet0",
            "address": [
              "172.19.0.1/30",
              "fdfe:dcba:9876::1/126"
            ],
            "auto_route": true,
            "auto_redirect": true,
            "strict_route": true,
            "exclude_uid": [
              0
            ],
            "route_exclude_address": [
              "192.168.0.0/16",
              "10.0.0.0/8",
              "172.16.0.0/12",
              "100.64.0.0/10",
              "127.0.0.0/8",
              "169.254.0.0/16",
              "224.0.0.0/4",
              "::1/128",
              "fc00::/7",
              "fe80::/10",
              "ff00::/8",
              "fd7a:115c:a1e0::/48"
            ],
            "stack": "mixed",
            "mtu": $tun_mtu,
            "udp_timeout": $udp_timeout
          };
        def managed_inbound:
          ((.type // "") as $type | ($type == "tun" or $type == "tproxy" or $type == "redirect"))
          or ((.tag // "") == "mixed-in")
          or ((.tag // "") | startswith("magicnet-"));
        def references_managed_inbound:
          (.inbound // []) as $inbound
          | (if ($inbound | type) == "array" then $inbound else [$inbound] end)
          | map(select(type == "string" and startswith("magicnet-")))
          | length > 0;
        def dns_hijack_rule:
          {"inbound": ["magicnet-dns-in"], "action": "hijack-dns"};
        def ipv6_reject_rule:
          {"ip_version": 6, "action": "reject", "method": "default", "no_drop": true};
        def legacy_ipv6_block_rule:
          {"ip_version": 6, "outbound": "block"};
        def normalized_ipv6_reject_rule:
          {"ip_version": 6, "action": "reject", "no_drop": true};
        def is_managed_ipv6_guard:
          . == legacy_ipv6_block_rule or . == normalized_ipv6_reject_rule or . == ipv6_reject_rule;
        def is_dns_hijack_rule:
          (.action // "") == "hijack-dns";
        def is_icmp_block_rule:
          (.protocol // "") == "icmp" and (.outbound // "") == "block";
        def is_sniff_rule:
          (.action // "") == "sniff";
        def normalize_sniff_rule:
          if (.action // "") == "sniff" then
            .inbound = ["mixed-in", "tun-in"]
          else
            .
          end;
        def sniff_rule:
          {"inbound": ["mixed-in", "tun-in"], "action": "sniff"};
        .inbounds = (
          ((.inbounds // [])
            | map(select(managed_inbound | not)))
          + [mixed_in]
          + [dns_in]
          + [tun_in]
        )
        | .route.rules = (
          ((.route.rules // [])
            | map(select(references_managed_inbound | not))
            | map(select(is_managed_ipv6_guard | not))
            | map(normalize_sniff_rule)) as $rules
          | ([dns_hijack_rule] + (if any($rules[]?; is_sniff_rule) then $rules else [sniff_rule] + $rules end)) as $managed_rules
          | if $dns_strategy == "ipv4_only" then
              [$managed_rules[] | select(is_sniff_rule)]
              + [dns_hijack_rule]
              + [$managed_rules[] | select(is_icmp_block_rule)]
              + [ipv6_reject_rule]
              + [$managed_rules[] | select((is_sniff_rule or is_dns_hijack_rule or is_icmp_block_rule or is_managed_ipv6_guard) | not)]
            else
              $managed_rules
            end
        )
        | if $dns_strategy != "" then .dns.strategy = $dns_strategy else . end
    ' "$_config" >"$_tmp") && chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config"; then
        :
    else
        rm -f "$_tmp" 2>/dev/null || true
        unset _dns_strategy _tun_mtu _udp_timeout _jq
        return 1
    fi
    import __singbox__
    singbox_prepare_route_config "$_config" || true
    unset _dns_strategy _tun_mtu _udp_timeout _jq
}

magicnet_transparent_apply_unlocked() {
    _transparent_rc=0
    magicnet_singbox_apply_transparent_mode || _transparent_rc=1
    return "$_transparent_rc"
}

magicnet_transparent_apply() {
    magicnet_with_config_lock magicnet_transparent_apply_unlocked
}
