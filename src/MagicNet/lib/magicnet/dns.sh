magicnet_dns_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/dns.conf"
}

magicnet_dns_profile() {
    _profile="${MAGICNET_DNS_PROFILE:-}"
    if [ -z "$_profile" ]; then
        _profile="$(magicnet_conf_value "$(magicnet_dns_conf)" MAGICNET_DNS_PROFILE 2>/dev/null || true)"
    fi
    case "${_profile:-default}" in
        default|cloudflare-doh|cloudflare-dot|cloudflare-udp) printf '%s\n' "${_profile:-default}" ;;
        cloudflare|doh) printf '%s\n' "cloudflare-doh" ;;
        dot) printf '%s\n' "cloudflare-dot" ;;
        udp|1.1.1.1) printf '%s\n' "cloudflare-udp" ;;
        *) printf '%s\n' "default" ;;
    esac
    unset _profile
}

magicnet_dns_bootstrap_server() {
    _bootstrap_ipv6_mode="${MAGICNET_IPV6_MODE:-}"
    [ -n "$_bootstrap_ipv6_mode" ] ||
        _bootstrap_ipv6_mode="$(magicnet_network_policy_value MAGICNET_IPV6_MODE 2>/dev/null || true)"
    _bootstrap_ipv6_available=0
    if command -v ip >/dev/null 2>&1 &&
        ip -6 route show default 2>/dev/null | grep -q '^default'; then
        _bootstrap_ipv6_available=1
    fi
    _bootstrap_ipv6_first=0
    [ "$_bootstrap_ipv6_mode" = "prefer_ipv6" ] && _bootstrap_ipv6_first=1

    if [ "$_bootstrap_ipv6_first" -eq 1 ] && [ "$_bootstrap_ipv6_available" -eq 1 ]; then
        _bootstrap_candidates="6:2400:3200::1 6:2400:3200:baba::1 4:223.6.6.6 4:223.5.5.5"
        _bootstrap_fallback="2400:3200::1"
    else
        _bootstrap_candidates="4:223.6.6.6 4:223.5.5.5"
        _bootstrap_fallback="223.6.6.6"
        [ "$_bootstrap_ipv6_mode" = "ipv4_only" ] ||
            [ "$_bootstrap_ipv6_available" -eq 0 ] ||
            _bootstrap_candidates="$_bootstrap_candidates 6:2400:3200::1 6:2400:3200:baba::1"
    fi

    # Config materialization must not perform synchronous Internet probes.
    # A stopped TUN can make each curl attempt consume its full timeout and a
    # manual start used to probe as many as four addresses.  Select the first
    # policy-compatible static bootstrap address; sing-box owns reachability
    # and retry behavior after the core is running.
    _bootstrap_server=${_bootstrap_candidates%% *}
    _bootstrap_server=${_bootstrap_server#*:}
    [ -n "$_bootstrap_server" ] || _bootstrap_server="$_bootstrap_fallback"
    printf '%s\n' "$_bootstrap_server"
    unset _bootstrap_ipv6_mode _bootstrap_ipv6_available _bootstrap_ipv6_first
    unset _bootstrap_candidates _bootstrap_server _bootstrap_fallback
}

magicnet_dns_apply_singbox() {
    _profile="$(magicnet_dns_profile)"
    _bootstrap_server="$(magicnet_dns_bootstrap_server)"
    _config="$(magicnet_singbox_config_file)"
    [ -f "$_config" ] || {
        unset _profile _bootstrap_server _config
        return 0
    }
    _jq="$(magicnet_require_jq "packaged jq is unavailable; DNS profile apply rejected")" || {
        unset _profile _bootstrap_server _config
        return 1
    }
    _tmp="${_config}.magicnet-dns.new"
    magicnet_jq_install_config "$_config" "$_tmp" "$_jq" --arg profile "$_profile" --arg bootstrap_server "$_bootstrap_server" \
        --argjson dns_capture_singbox_mark "${MAGICNET_DNS_CAPTURE_SINGBOX_MARK:-1073741824}" -e '
      def cf_udp($tag; $server):
        {"type":"udp","tag":$tag,"server":$server,"detour":"proxy"};
      def cf_tls($tag; $server):
        {"type":"tls","tag":$tag,"server":$server,"server_port":853,"detour":"proxy","tls":{"server_name":"cloudflare-dns.com"}};
      def cf_https($tag; $server):
        {"type":"https","tag":$tag,"server":$server,"server_port":443,"detour":"proxy","path":"/dns-query","tls":{"server_name":"cloudflare-dns.com"}};
      def default_bootstrap:
        {"type":"https","tag":"bootstrap-local-dns","server":$bootstrap_server,"server_port":443,"path":"/dns-query","headers":{"Host":"dns.alidns.com"},"tls":{"server_name":"dns.alidns.com"}};
      def server_for($profile; $tag; $server):
        if $profile == "cloudflare-udp" then cf_udp($tag; $server)
        elif $profile == "cloudflare-dot" then cf_tls($tag; $server)
        else cf_https($tag; $server)
        end;
      .dns.servers = (
        (.dns.servers // [])
        | map(select((.tag // "") as $tag |
          ($tag != "bootstrap-local-dns" and
           $tag != "cloudflare-profile-dns" and
           $tag != "cloudflare-backup-dns")))
        | (if $profile == "default" then [default_bootstrap]
           else [default_bootstrap,
                 server_for($profile; "cloudflare-profile-dns"; "1.1.1.1"),
                 server_for($profile; "cloudflare-backup-dns"; "1.0.0.1")]
           end) + .
      )
      # Direct UDP DNS servers are contacted by sing-box itself. Mark those
      # sockets so the kernel DNS redirect can exempt them without exempting
      # every UID-0 Android resolver query.
      | .dns.servers |= map(
          if (.type == "udp" and (.detour // "") == "") then
            .routing_mark = $dns_capture_singbox_mark
          else .
          end
        )
      | if $profile == "default" then .dns.final = "bootstrap-local-dns"
        else .dns.final = "cloudflare-profile-dns"
        end
    ' "$_config"
    _rc=$?
    unset _profile _bootstrap_server _config _jq _tmp
    return "$_rc"
}

magicnet_dns_apply_unlocked() {
    magicnet_dns_apply_singbox
}

magicnet_dns_apply() {
    magicnet_with_config_lock magicnet_dns_apply_unlocked
}
