magicnet_singbox_use_cached_subscription() {
    _source_file="$1"
    _cache_file="$2"
    _identity_file="$3"
    _expected_identity="$4"
    if [ "${MAGICNET_SUB_REQUIRE_FRESH:-0}" = "1" ]; then
        error "Subscription download failed and fresh subscription is required"
        return 1
    fi
    if [ -s "$_source_file" ]; then
        warn "Using staged subscription source"
        return 0
    fi
    if [ -n "$_cache_file" ] && [ -s "$_cache_file" ] &&
        [ -n "$_identity_file" ] && [ -s "$_identity_file" ] &&
        [ -n "$_expected_identity" ] &&
        [ "$(sed -n '1p' "$_identity_file" 2>/dev/null)" = "$_expected_identity" ]; then
        warn "Using identity-verified subscription cache"
        cp "$_cache_file" "$_source_file"
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

magicnet_singbox_local_subscription_proxy() {
    command -v curl >/dev/null 2>&1 || return 1
    env -u http_proxy -u https_proxy -u all_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
        timeout "${MAGICNET_SUB_PROXY_PROBE_TIMEOUT:-3}" \
        curl -fsS --noproxy '*' --max-time "${MAGICNET_SUB_PROXY_PROBE_TIMEOUT:-3}" \
        http://127.0.0.1:9090/version >/dev/null 2>&1 || return 1
    printf '%s\n' "http://127.0.0.1:7892"
}

magicnet_singbox_normalize_subscription_file() {
    _source_file="$1"
    _tmp_file="${_source_file}.normalized"

    tr -d '\r' <"$_source_file" >"$_tmp_file" && mv -f "$_tmp_file" "$_source_file"
}

magicnet_singbox_fetch_one_subscription() {
    _url="$1"
    _source_file="$2"
    _cache_file="$3"
    _identity_file="$4"
    _expected_identity="$5"
    _label="$6"
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

    if [ "$_fetched" -ne 1 ] && [ -z "${MAGICNET_SUB_PROXY:-}" ]; then
        _local_proxy=$(magicnet_singbox_local_subscription_proxy 2>/dev/null || true)
        if [ -n "$_local_proxy" ]; then
            rm -f "$_download_file"
            (
                MAGICNET_SUB_PROXY="$_local_proxy"
                magicnet_singbox_try_fetch_subscription curl "$_url" "$_download_file" "$_connect_timeout" "$_max_time"
            )
            _fetch_rc=$?
            _tried=1
            if [ "$_fetch_rc" -eq 0 ] && [ -s "$_download_file" ]; then
                _fetched=1
            else
                warn "Failed to download subscription ${_label} with local sing-box proxy"
            fi
        fi
    fi

    if [ "$_tried" -eq 0 ]; then
        error "No downloader found: curl, wget or sing-box tools fetch"
        return 1
    fi
    if [ "$_fetched" -ne 1 ]; then
        [ -z "${MAGICNET_SUB_PROXY:-}" ] || error "Explicit subscription proxy failed; refusing alternate egress"
        magicnet_singbox_use_cached_subscription "$_source_file" "$_cache_file" "$_identity_file" "$_expected_identity" || return 1
        return 0
    fi

    [ -s "$_download_file" ] || {
        error "Downloaded subscription ${_label} is empty"
        magicnet_singbox_use_cached_subscription "$_source_file" "$_cache_file" "$_identity_file" "$_expected_identity" || return 1
        return 0
    }

    mv -f "$_download_file" "$_source_file"
    magicnet_singbox_normalize_subscription_file "$_source_file" || return 1
    unset _fetched _tried _method _fetch_rc _local_proxy
}

magicnet_singbox_fetch_subscription() {
    _url_file=$(magicnet_singbox_subscription_url_file)
    _generation_dir=${1%/*}
    _source_dir="${_generation_dir}/sources"
    _cache_dir=$(magicnet_singbox_subscription_cache_dir)
    _cache_map="${_generation_dir}/cache-map.txt"
    _sources_file="$1"

    if [ ! -s "$_url_file" ]; then
        error "Missing subscription URL file: $_url_file"
        return 1
    fi

    mkdir -p "$_source_dir" "$_cache_dir"
    : >"$_sources_file"
    : >"$_cache_map"

    _index=0
    _ok=0
    while IFS= read -r _url || [ -n "$_url" ]; do
        _url=$(printf '%s' "$_url" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$_url" ] || continue

        _index=$((_index + 1))
        _fingerprint=
        if _fingerprint=$(magicnet_singbox_subscription_fingerprint "$_url" 2>/dev/null) &&
            printf '%s' "$_fingerprint" | grep -Eq '^[0-9a-fA-F]{64}$'; then
            _fingerprint=$(printf '%s' "$_fingerprint" | tr 'A-F' 'a-f')
            _source_file="${_source_dir}/${_fingerprint}.yaml"
            _cache_file="${_cache_dir}/${_fingerprint}.yaml"
            _identity_file="${_cache_file}.identity"
        else
            warn "Subscription #${_index}: persistent cache disabled because SHA-256 is unavailable"
            _source_file="${_source_dir}/fresh-${_index}.yaml"
            _cache_file=""
            _identity_file=""
        fi

        if magicnet_singbox_fetch_one_subscription "$_url" "$_source_file" "$_cache_file" "$_identity_file" "$_fingerprint" "#${_index}"; then
            printf '%s\n' "$_source_file" >>"$_sources_file"
            if [ -n "$_fingerprint" ]; then
                printf '%s|%s|%s|%s\n' "${_source_file##*/}" "$_cache_file" "$_identity_file" "$_fingerprint" >>"$_cache_map"
            fi
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
    MAGICNET_SUB_CONFIGURED_COUNT="$_index"
    MAGICNET_SUB_SOURCE_COUNT="$_ok"
    MAGICNET_SUB_CACHE_MAP_FILE="$_cache_map"
    export MAGICNET_SUB_CONFIGURED_COUNT MAGICNET_SUB_SOURCE_COUNT MAGICNET_SUB_CACHE_MAP_FILE
}
