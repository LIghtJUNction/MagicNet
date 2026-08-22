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

    if ! command -v curl >/dev/null 2>&1; then
        printf '%s\n' "$_bootstrap_fallback"
        unset _bootstrap_ipv6_mode _bootstrap_ipv6_available _bootstrap_ipv6_first
        unset _bootstrap_candidates _bootstrap_fallback
        return 0
    fi
    for _bootstrap_candidate in $_bootstrap_candidates; do
        _bootstrap_family=${_bootstrap_candidate%%:*}
        _bootstrap_server=${_bootstrap_candidate#*:}
        if [ "$_bootstrap_family" = "6" ]; then
            _bootstrap_resolve="dns.alidns.com:443:[${_bootstrap_server}]"
            _bootstrap_curl_family="-6"
        else
            _bootstrap_resolve="dns.alidns.com:443:${_bootstrap_server}"
            _bootstrap_curl_family=""
        fi
        if curl $_bootstrap_curl_family -ksS --connect-timeout 2 --max-time 3 \
            --resolve "$_bootstrap_resolve" \
            -o /dev/null https://dns.alidns.com/dns-query >/dev/null 2>&1; then
            printf '%s\n' "$_bootstrap_server"
            unset _bootstrap_ipv6_mode _bootstrap_ipv6_available _bootstrap_ipv6_first
            unset _bootstrap_candidates _bootstrap_candidate _bootstrap_family
            unset _bootstrap_server _bootstrap_resolve _bootstrap_curl_family _bootstrap_fallback
            return 0
        fi
    done
    printf '%s\n' "$_bootstrap_fallback"
    unset _bootstrap_ipv6_mode _bootstrap_ipv6_available _bootstrap_ipv6_first
    unset _bootstrap_candidates _bootstrap_candidate _bootstrap_family
    unset _bootstrap_server _bootstrap_resolve _bootstrap_curl_family _bootstrap_fallback
}

magicnet_dns_apply_singbox() {
    _profile="$(magicnet_dns_profile)"
    _bootstrap_server="$(magicnet_dns_bootstrap_server)"
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || {
        unset _profile _bootstrap_server _config
        return 0
    }
    _jq="${MODDIR}/bin/jq"
    [ -x "$_jq" ] || {
        magicnet_warn "packaged jq is unavailable; DNS profile apply rejected"
        unset _profile _bootstrap_server _config _jq
        return 1
    }
    _tmp="${_config}.magicnet-dns.new"
    (umask 077; "$_jq" --arg profile "$_profile" --arg bootstrap_server "$_bootstrap_server" '
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
      | if $profile == "default" then .dns.final = "bootstrap-local-dns"
        else .dns.final = "cloudflare-profile-dns"
        end
    ' "$_config" >"$_tmp") && chmod 600 "$_tmp" && mv -f "$_tmp" "$_config" && chmod 600 "$_config"
    _rc=$?
    [ "$_rc" -eq 0 ] || rm -f "$_tmp" 2>/dev/null || true
    unset _profile _bootstrap_server _config _jq _tmp
    return "$_rc"
}

magicnet_dns_apply_unlocked() {
    magicnet_dns_apply_singbox
}

magicnet_dns_apply() {
    magicnet_with_config_lock magicnet_dns_apply_unlocked
}
