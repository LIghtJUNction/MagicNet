magicnet_singbox_download_proxy_args() {
    _proxy="${MAGICNET_SUB_PROXY:-}"
    if [ -z "$_proxy" ] && command -v curl >/dev/null 2>&1; then
        curl -sS --max-time 2 http://127.0.0.1:9090/proxies >/dev/null 2>&1 &&
            _proxy="http://127.0.0.1:7892"
    fi
    [ -n "$_proxy" ] && printf '%s\n%s\n' "--proxy" "$_proxy"
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

    if command -v curl >/dev/null 2>&1; then
        # shellcheck disable=SC2046
        curl -fsSL $(magicnet_singbox_download_proxy_args) --connect-timeout "$_connect_timeout" --max-time "$_max_time" "$_url" -o "$_download_file" || {
            error "Failed to download subscription ${_label} with curl"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ] && {
                warn "Using legacy cached subscription: $_fallback_file"
                cp "$_fallback_file" "$_source_file"
                return 0
            }
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -T "$_max_time" -qO "$_download_file" "$_url" || {
            error "Failed to download subscription ${_label} with wget"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ] && {
                warn "Using legacy cached subscription: $_fallback_file"
                cp "$_fallback_file" "$_source_file"
                return 0
            }
            return 1
        }
    elif command -v sing-box >/dev/null 2>&1; then
        sing-box tools fetch "$_url" >"$_download_file" || {
            error "Failed to download subscription ${_label} with sing-box"
            [ -s "$_source_file" ] && {
                warn "Using cached subscription: $_source_file"
                return 0
            }
            [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ] && {
                warn "Using legacy cached subscription: $_fallback_file"
                cp "$_fallback_file" "$_source_file"
                return 0
            }
            return 1
        }
    else
        error "No downloader found: curl, wget or sing-box tools fetch"
        return 1
    fi

    [ -s "$_download_file" ] || {
        error "Downloaded subscription ${_label} is empty"
        [ -s "$_source_file" ] && {
            warn "Using cached subscription: $_source_file"
            return 0
        }
        [ -n "$_fallback_file" ] && [ -s "$_fallback_file" ] && {
            warn "Using legacy cached subscription: $_fallback_file"
            cp "$_fallback_file" "$_source_file"
            return 0
        }
        return 1
    }

    mv -f "$_download_file" "$_source_file"
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

