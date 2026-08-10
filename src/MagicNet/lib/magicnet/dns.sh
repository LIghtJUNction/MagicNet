magicnet_dns_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/dns.conf"
}

magicnet_dns_profile() {
    _profile="${MAGICNET_DNS_PROFILE:-}"
    if [ -z "$_profile" ] && [ -f "$(magicnet_dns_conf)" ]; then
        . "$(magicnet_dns_conf)" 2>/dev/null || true
        _profile="${MAGICNET_DNS_PROFILE:-}"
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

magicnet_dns_apply_singbox() {
    _profile="$(magicnet_dns_profile)"
    _config="${MODDIR}/.config/sing-box/config.json"
    [ -f "$_config" ] || {
        unset _profile _config
        return 0
    }
    _jq="$(command -v jq 2>/dev/null || true)"
    [ -n "$_jq" ] || {
        magicnet_warn "jq not found; DNS profile apply skipped"
        unset _profile _config _jq
        return 1
    }
    _tmp="${_config}.magicnet-dns.new"
    (umask 077; "$_jq" --arg profile "$_profile" '
      def cf_udp($tag; $server):
        {"type":"udp","tag":$tag,"server":$server,"detour":"proxy"};
      def cf_tls($tag; $server):
        {"type":"tls","tag":$tag,"server":$server,"server_port":853,"detour":"proxy","tls":{"server_name":"cloudflare-dns.com"}};
      def cf_https($tag; $server):
        {"type":"https","tag":$tag,"server":$server,"server_port":443,"detour":"proxy","path":"/dns-query","tls":{"server_name":"cloudflare-dns.com"}};
      def default_bootstrap:
        {"type":"https","tag":"bootstrap-local-dns","server":"223.5.5.5","server_port":443,"path":"/dns-query","headers":{"Host":"dns.alidns.com"},"tls":{"server_name":"dns.alidns.com"}};
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
    unset _profile _config _jq _tmp
    return "$_rc"
}

magicnet_dns_apply_unlocked() {
    magicnet_dns_apply_singbox
}

magicnet_dns_apply() {
    magicnet_with_config_lock magicnet_dns_apply_unlocked
}
