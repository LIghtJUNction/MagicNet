magicnet_singbox_use_cached_subscription() {
    _source_file="$1"
    _fallback_file="$2"
    if [ "${MAGICNET_SUB_REQUIRE_FRESH:-0}" = "1" ]; then
        error "Subscription download failed and fresh subscription is required"
        return 1
    fi
    if [ -s "$_source_file" ]; then
        warn "Using cached subscription: $_source_file"
        return 0
    fi
    if [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ]; then
        warn "Using legacy cached subscription: $_fallback_file"
        cp "$_fallback_file" "$_source_file"
        return 0
    fi
    return 1
}

magicnet_singbox_try_fetch_subscription() {
    _method="$1"
    _url="$2"
    _download_file="$3"
    _connect_timeout="$4"
    _max_time="$5"
    case "$_method" in
        curl)
            command -v curl >/dev/null 2>&1 || return 127
            if [ -n "${MAGICNET_SUB_PROXY:-}" ]; then
                env -u http_proxy -u https_proxy -u all_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
                    timeout "$_max_time" curl -fsSL --proxy "$MAGICNET_SUB_PROXY" --connect-timeout "$_connect_timeout" --max-time "$_max_time" "$_url" -o "$_download_file"
            else
                env -u http_proxy -u https_proxy -u all_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
                    timeout "$_max_time" curl -fsSL --noproxy '*' --connect-timeout "$_connect_timeout" --max-time "$_max_time" "$_url" -o "$_download_file"
            fi
            ;;
        wget)
            command -v wget >/dev/null 2>&1 || return 127
            env -u http_proxy -u https_proxy -u all_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
                timeout "$_max_time" wget -T "$_max_time" -qO "$_download_file" "$_url"
            ;;
        sing-box)
            command -v sing-box >/dev/null 2>&1 || return 127
            env -u http_proxy -u https_proxy -u all_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
                timeout "$_max_time" sing-box tools fetch "$_url" >"$_download_file"
            ;;
        *)
            return 127
            ;;
    esac
}

magicnet_singbox_normalize_subscription_file() {
    _source_file="$1"
    _tmp_file="${_source_file}.normalized"

    tr -d '\r' <"$_source_file" >"$_tmp_file" && mv -f "$_tmp_file" "$_source_file"
}

magicnet_singbox_fetch_one_subscription() {
    _url="$1"
    _source_file="$2"
    _fallback_file="$3"
    _label="$4"
    _url_file=$(magicnet_singbox_subscription_url_file)
    _download_file="${_source_file}.download"

    if [ -z "$_url" ]; then
        error "Subscription URL is empty in $_url_file"
        return 1
    fi

    mkdir -p "${_source_file%/*}"
    rm -f "$_download_file"

    _connect_timeout="${MAGICNET_SUB_CONNECT_TIMEOUT:-10}"
    _max_time="${MAGICNET_SUB_MAX_TIME:-45}"

    _fetched=0
    _tried=0
    if [ -n "${MAGICNET_SUB_PROXY:-}" ]; then
        _methods="curl"
    else
        _methods="curl wget sing-box"
    fi
    for _method in $_methods; do
        rm -f "$_download_file"
        magicnet_singbox_try_fetch_subscription "$_method" "$_url" "$_download_file" "$_connect_timeout" "$_max_time"
        _fetch_rc=$?
        [ "$_fetch_rc" -eq 127 ] && continue
        _tried=1
        if [ "$_fetch_rc" -eq 0 ] && [ -s "$_download_file" ]; then
            _fetched=1
            break
        fi
        warn "Failed to download subscription ${_label} with ${_method}"
    done

    if [ "$_tried" -eq 0 ]; then
        error "No downloader found: curl, wget or sing-box tools fetch"
        return 1
    fi
    if [ "$_fetched" -ne 1 ]; then
        [ -z "${MAGICNET_SUB_PROXY:-}" ] || error "Explicit subscription proxy failed; refusing alternate egress"
        magicnet_singbox_use_cached_subscription "$_source_file" "$_fallback_file" || return 1
        return 0
    fi

    [ -s "$_download_file" ] || {
        error "Downloaded subscription ${_label} is empty"
        magicnet_singbox_use_cached_subscription "$_source_file" "$_fallback_file" || return 1
        return 0
    }

    mv -f "$_download_file" "$_source_file"
    magicnet_singbox_normalize_subscription_file "$_source_file" || return 1
    unset _fetched _tried _method _fetch_rc
}

magicnet_singbox_fetch_subscription() {
    _url_file=$(magicnet_singbox_subscription_url_file)
    _source_dir=$(magicnet_singbox_subscription_source_dir)
    _legacy_source_file=$(magicnet_singbox_subscription_source_file)
    _sources_file="$1"

    if [ ! -s "$_url_file" ]; then
        error "Missing subscription URL file: $_url_file"
        return 1
    fi

    mkdir -p "$_source_dir"
    : >"$_sources_file"

    _index=0
    _ok=0
    while IFS= read -r _url || [ -n "$_url" ]; do
        _url=$(printf '%s' "$_url" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$_url" ] || continue

        _index=$((_index + 1))
        _source_file="${_source_dir}/subscription-${_index}.yaml"
        _fallback_file=""
        [ "$_index" -eq 1 ] && _fallback_file="$_legacy_source_file"

        if magicnet_singbox_fetch_one_subscription "$_url" "$_source_file" "$_fallback_file" "#${_index}"; then
            printf '%s\n' "$_source_file" >>"$_sources_file"
            _ok=$((_ok + 1))
        else
            warn "Skipping subscription #${_index}"
        fi
    done <"$_url_file"

    if [ "$_index" -eq 0 ]; then
        error "Subscription URL file is empty: $_url_file"
        return 1
    fi
    if [ "$_ok" -le 0 ]; then
        error "No subscription source is available"
        return 1
    fi
}
