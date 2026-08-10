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
        if ! cp "$_cache_file" "$_source_file"; then
            rm -f "$_source_file" 2>/dev/null || true
            return 1
        fi
        return 0
    fi
    return 1
}

# A single per-subscription response limit. Keep this fixed so scheduled
# refreshes cannot be expanded through an environment override.
MAGICNET_SUB_MAX_RESPONSE_BYTES=8388608
MAGICNET_SUB_RESOLVE_TIMEOUT=10

magicnet_singbox_subscription_parse_authority() {
    _subscription_url="$1"
    _subscription_scheme=${_subscription_url%%://*}
    case "$_subscription_scheme" in
        [hH][tT][tT][pP][sS]) _subscription_rest=${_subscription_url#*://} ;;
        *) return 1 ;;
    esac
    case "$_subscription_url" in *[[:space:]]*) return 1 ;; esac
    _subscription_authority=${_subscription_rest%%/*}
    _subscription_authority=${_subscription_authority%%\?*}
    _subscription_authority=${_subscription_authority%%\#*}
    [ -n "$_subscription_authority" ] || return 1
    case "$_subscription_authority" in *@*) return 1 ;; esac

    case "$_subscription_authority" in
        \[* )
            _subscription_after_open=${_subscription_authority#\[}
            _subscription_host=${_subscription_after_open%%\]*}
            [ "$_subscription_host" != "$_subscription_after_open" ] || return 1
            _subscription_suffix=${_subscription_after_open#*\]}
            case "$_subscription_suffix" in ''|:[0-9]*) ;; *) return 1 ;; esac
            _subscription_port=${_subscription_suffix#:}
            case "$_subscription_host" in *[!0-9A-Fa-f:.]*|'') return 1 ;; esac
            ;;
        *)
            case "$_subscription_authority" in
                *:*)
                    _subscription_host=${_subscription_authority%:*}
                    _subscription_port=${_subscription_authority##*:}
                    case "$_subscription_host" in *:*) return 1 ;; esac
                    ;;
                *)
                    _subscription_host=$_subscription_authority
                    _subscription_port=
                    ;;
            esac
            case "$_subscription_host" in
                ''|.*|*.) return 1 ;;
                *[!A-Za-z0-9.-]*|*..*) return 1 ;;
                -*|*.-*|*-.?*) return 1 ;;
            esac
            ;;
    esac
    if [ -n "$_subscription_port" ]; then
        case "$_subscription_port" in *[!0-9]*) return 1 ;; esac
        [ "$_subscription_port" -ge 1 ] 2>/dev/null &&
            [ "$_subscription_port" -le 65535 ] 2>/dev/null || return 1
    else
        _subscription_port=443
    fi
}

magicnet_singbox_public_ipv4() {
    _subscription_ipv4="$1"
    case "$_subscription_ipv4" in *[!0-9.]*|*..*|.*|*.) return 1 ;; esac
    _subscription_old_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086 # splitting the already character-checked IPv4 octets
    set -- $_subscription_ipv4
    IFS=$_subscription_old_ifs
    [ "$#" -eq 4 ] || return 1
    for _subscription_octet in "$@"; do
        [ "$_subscription_octet" -ge 0 ] 2>/dev/null &&
            [ "$_subscription_octet" -le 255 ] 2>/dev/null || return 1
    done
    _subscription_first=$1
    _subscription_second=$2
    _subscription_third=$3
    [ "$_subscription_first" -ne 0 ] &&
        [ "$_subscription_first" -ne 10 ] &&
        [ "$_subscription_first" -ne 127 ] &&
        [ "$_subscription_first" -lt 224 ] || return 1
    [ "$_subscription_first" -ne 100 ] ||
        { [ "$_subscription_second" -lt 64 ] || [ "$_subscription_second" -gt 127 ]; } || return 1
    [ "$_subscription_first" -ne 169 ] || [ "$_subscription_second" -ne 254 ] || return 1
    [ "$_subscription_first" -ne 172 ] ||
        { [ "$_subscription_second" -lt 16 ] || [ "$_subscription_second" -gt 31 ]; } || return 1
    if [ "$_subscription_first" -eq 192 ]; then
        case "$_subscription_second/$_subscription_third" in
            0/*|2/*|168/*|31/196|52/193|88/99|175/48) return 1 ;;
        esac
    fi
    [ "$_subscription_first" -ne 198 ] ||
        {
            {
                [ "$_subscription_second" -lt 18 ] ||
                [ "$_subscription_second" -gt 19 ];
            } && [ "$_subscription_second" -ne 51 ];
        } || return 1
    [ "$_subscription_first" -ne 203 ] ||
        [ "$_subscription_second" -ne 0 ] ||
        [ "$_subscription_third" -ne 113 ] || return 1
}

magicnet_singbox_public_ipv6() (
    _subscription_ipv6="$1"
    case "$_subscription_ipv6" in *:*) ;; *) return 1 ;; esac
    case "$_subscription_ipv6" in *[!0-9A-Fa-f:]*|'') return 1 ;; esac

    _subscription_left=
    _subscription_right=
    _subscription_count=0
    _subscription_left_values=
    _subscription_right_values=
    _subscription_values=
    case "$_subscription_ipv6" in
        *::*)
            _subscription_left=${_subscription_ipv6%%::*}
            _subscription_right=${_subscription_ipv6#*::}
            case "$_subscription_left" in *::*|:*|*:) return 1 ;; esac
            case "$_subscription_right" in *::*|:*|*:) return 1 ;; esac
            if [ -n "$_subscription_left" ]; then
                _subscription_old_ifs=$IFS
                IFS=:
                # shellcheck disable=SC2086 # splitting character-checked hextets
                set -- $_subscription_left
                IFS=$_subscription_old_ifs
                for _subscription_hextet in "$@"; do
                    [ -n "$_subscription_hextet" ] || return 1
                    [ "${#_subscription_hextet}" -le 4 ] || return 1
                    case "$_subscription_hextet" in *[!0-9A-Fa-f]*) return 1 ;; esac
                    _subscription_value=$(printf '%d' "0x$_subscription_hextet" 2>/dev/null) || return 1
                    if [ -n "$_subscription_left_values" ]; then
                        _subscription_left_values="$_subscription_left_values $_subscription_value"
                    else
                        _subscription_left_values=$_subscription_value
                    fi
                    _subscription_count=$((_subscription_count + 1))
                done
            else
                # A leading `::` compresses zero-valued hextets, so the
                # first address group is zero even when the right side starts
                # with a non-zero group.
                :
            fi
            if [ -n "$_subscription_right" ]; then
                _subscription_old_ifs=$IFS
                IFS=:
                # shellcheck disable=SC2086 # splitting character-checked hextets
                set -- $_subscription_right
                IFS=$_subscription_old_ifs
                for _subscription_hextet in "$@"; do
                    [ -n "$_subscription_hextet" ] || return 1
                    [ "${#_subscription_hextet}" -le 4 ] || return 1
                    case "$_subscription_hextet" in *[!0-9A-Fa-f]*) return 1 ;; esac
                    _subscription_value=$(printf '%d' "0x$_subscription_hextet" 2>/dev/null) || return 1
                    if [ -n "$_subscription_right_values" ]; then
                        _subscription_right_values="$_subscription_right_values $_subscription_value"
                    else
                        _subscription_right_values=$_subscription_value
                    fi
                    _subscription_count=$((_subscription_count + 1))
                done
            fi
            # `::` must compress at least one hextet; eight explicit hextets
            # would make the address overlong rather than compressed.
            [ "$_subscription_count" -lt 8 ] || return 1
            ;;
        *)
            case "$_subscription_ipv6" in :*|*:) return 1 ;; esac
            _subscription_old_ifs=$IFS
            IFS=:
            # shellcheck disable=SC2086 # splitting character-checked hextets
            set -- $_subscription_ipv6
            IFS=$_subscription_old_ifs
            [ "$#" -eq 8 ] || return 1
            for _subscription_hextet in "$@"; do
                [ -n "$_subscription_hextet" ] || return 1
                [ "${#_subscription_hextet}" -le 4 ] || return 1
                case "$_subscription_hextet" in *[!0-9A-Fa-f]*) return 1 ;; esac
                _subscription_value=$(printf '%d' "0x$_subscription_hextet" 2>/dev/null) || return 1
                if [ -n "$_subscription_values" ]; then
                    _subscription_values="$_subscription_values $_subscription_value"
                else
                    _subscription_values=$_subscription_value
                fi
            done
            ;;
    esac

    case "$_subscription_ipv6" in
        *::*)
            _subscription_missing=$((8 - _subscription_count))
            [ "$_subscription_missing" -ge 1 ] || return 1
            _subscription_values=$_subscription_left_values
            _subscription_index=0
            while [ "$_subscription_index" -lt "$_subscription_missing" ]; do
                if [ -n "$_subscription_values" ]; then
                    _subscription_values="$_subscription_values 0"
                else
                    _subscription_values=0
                fi
                _subscription_index=$((_subscription_index + 1))
            done
            if [ -n "$_subscription_right_values" ]; then
                if [ -n "$_subscription_values" ]; then
                    _subscription_values="$_subscription_values $_subscription_right_values"
                else
                    _subscription_values=$_subscription_right_values
                fi
            fi
            ;;
    esac
    _subscription_old_ifs=$IFS
    IFS=' '
    # shellcheck disable=SC2086 # splitting normalized decimal hextet values
    set -- $_subscription_values
    IFS=$_subscription_old_ifs
    [ "$#" -eq 8 ] || return 1
    _subscription_segment1=$1
    _subscription_segment2=$2
    _subscription_segment3=$3
    _subscription_segment4=$4
    _subscription_segment5=$5
    _subscription_segment6=$6
    _subscription_first_value=$_subscription_segment1
    # Unspecified, loopback and IPv4-mapped forms are not usable public
    # subscription endpoints even when their textual shape is valid.
    [ "$_subscription_first_value" -ne 0 ] || return 1
    [ "$_subscription_first_value" -lt 64512 ] || [ "$_subscription_first_value" -gt 65023 ] || return 1
    [ "$_subscription_first_value" -lt 65152 ] || [ "$_subscription_first_value" -gt 65215 ] || return 1
    [ "$_subscription_first_value" -lt 65280 ] || return 1
    # Match the Rust resolver policy for documentation, benchmarking,
    # discard, Teredo, and well-known NAT64 ranges.
    [ "$_subscription_segment1" -eq 256 ] &&
        [ "$_subscription_segment2" -eq 0 ] &&
        [ "$_subscription_segment3" -eq 0 ] &&
        [ "$_subscription_segment4" -eq 0 ] && return 1
    [ "$_subscription_segment1" -eq 100 ] &&
        [ "$_subscription_segment2" -eq 65435 ] &&
        [ "$_subscription_segment3" -eq 0 ] &&
        [ "$_subscription_segment4" -eq 0 ] &&
        [ "$_subscription_segment5" -eq 0 ] &&
        [ "$_subscription_segment6" -eq 0 ] && return 1
    if [ "$_subscription_segment1" -eq 8193 ] && {
        [ "$_subscription_segment2" -eq 0 ] ||
            { [ "$_subscription_segment2" -eq 2 ] && [ "$_subscription_segment3" -eq 0 ]; } ||
            [ "$_subscription_segment2" -eq 3512 ] ||
            { [ "$_subscription_segment2" -ge 16 ] && [ "$_subscription_segment2" -le 31 ]; } ||
            { [ "$_subscription_segment2" -ge 32 ] && [ "$_subscription_segment2" -le 47 ]; }
    }; then
        return 1
    fi
    return 0
)

magicnet_singbox_public_address() (
    _subscription_address="$1"
    case "$_subscription_address" in
        *.*)
            _subscription_tail=${_subscription_address##*:}
            magicnet_singbox_public_ipv4 "$_subscription_tail" || return 1
            case "$_subscription_address" in
                *:*) _subscription_address="${_subscription_address%:*}:0:0" ;;
                *) return 0 ;;
            esac
            ;;
    esac
    magicnet_singbox_public_ipv6 "$_subscription_address"
)

magicnet_singbox_subscription_resolve_public() {
    _subscription_url="$1"
    magicnet_singbox_subscription_parse_authority "$_subscription_url" || return 1
    [ -x "${MODDIR}/cli" ] || return 1
    timeout "$MAGICNET_SUB_RESOLVE_TIMEOUT" \
        "${MODDIR}/cli" sub resolve-host "$_subscription_host" "$_subscription_port" 2>/dev/null |
        while IFS= read -r _subscription_address; do
            magicnet_singbox_public_address "$_subscription_address" || exit 1
            case "$_subscription_address" in
                *:*) _subscription_resolve_address="[$_subscription_address]" ;;
                *) _subscription_resolve_address=$_subscription_address ;;
            esac
            printf '%s|%s|%s\n' "$_subscription_host" "$_subscription_port" "$_subscription_resolve_address"
        done
}

magicnet_singbox_try_fetch_subscription() {
    _url="$1"
    _download_file="$2"
    _connect_timeout="$3"
    _max_time="$4"
    _resolve_file="${_download_file}.resolve"
    _stream_fifo="${_download_file}.stream"
    command -v curl >/dev/null 2>&1 || return 127
    rm -f "$_download_file" "$_resolve_file" "$_stream_fifo"
    magicnet_singbox_subscription_resolve_public "$_url" >"$_resolve_file" || {
        rm -f "$_download_file" "$_resolve_file" "$_stream_fifo"
        return 1
    }
    [ -s "$_resolve_file" ] || {
        rm -f "$_download_file" "$_resolve_file" "$_stream_fifo"
        return 1
    }
    mkfifo "$_stream_fifo" || {
        rm -f "$_download_file" "$_resolve_file" "$_stream_fifo"
        return 1
    }
    set -- -fsS --noproxy '*' --max-redirs 0 --proto '=https' --proto-redir '=https' \
        --max-filesize "$MAGICNET_SUB_MAX_RESPONSE_BYTES"
    [ -z "${MAGICNET_SUB_USER_AGENT:-}" ] || set -- "$@" --user-agent "$MAGICNET_SUB_USER_AGENT"
    while IFS='|' read -r _resolved_host _resolved_port _resolved_address; do
        set -- "$@" --resolve "${_resolved_host}:${_resolved_port}:${_resolved_address}"
    done <"$_resolve_file"
    set -- "$@" --connect-timeout "$_connect_timeout" --max-time "$_max_time" -o - "$_url"
    env -u http_proxy -u https_proxy -u all_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
        timeout "$_max_time" curl "$@" >"$_stream_fifo" &
    _curl_pid=$!
    # Consume the FIFO exactly once. `head -c` keeps reading short pipe reads
    # until it reaches the budget plus one byte or EOF, so unknown-length and
    # chunked bodies are rejected without reopening a FIFO after curl exits.
    # `wait` preserves curl/HTTP/timeout failure separately.
    head -c "$((MAGICNET_SUB_MAX_RESPONSE_BYTES + 1))" <"$_stream_fifo" >"$_download_file"
    _stream_result=$?
    if [ "$_stream_result" -ne 0 ]; then
        kill "$_curl_pid" 2>/dev/null || true
    fi
    wait "$_curl_pid"
    _fetch_result=$?
    rm -f "$_resolve_file" "$_stream_fifo"
    if [ "$_stream_result" -ne 0 ] || [ "$_fetch_result" -ne 0 ] ||
        [ ! -s "$_download_file" ] ||
        [ "$(wc -c <"$_download_file")" -gt "$MAGICNET_SUB_MAX_RESPONSE_BYTES" ]; then
        rm -f "$_download_file" "$_resolve_file" "$_stream_fifo"
        return 1
    fi
}

magicnet_singbox_normalize_subscription_file() {
    _source_file="$1"
    _tmp_file="${_source_file}.normalized"

    if ! tr -d '\r' <"$_source_file" >"$_tmp_file"; then
        rm -f "$_tmp_file" 2>/dev/null || true
        return 1
    fi
    if ! mv -f "$_tmp_file" "$_source_file"; then
        rm -f "$_tmp_file" 2>/dev/null || true
        return 1
    fi
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
    _user_agent_file=$(magicnet_singbox_subscription_user_agent_file)
    MAGICNET_SUB_USER_AGENT=
    if [ -s "$_user_agent_file" ]; then
        IFS= read -r MAGICNET_SUB_USER_AGENT <"$_user_agent_file" || true
    fi
    export MAGICNET_SUB_USER_AGENT

    if [ -z "$_url" ]; then
        error "Subscription URL is empty in $_url_file"
        return 1
    fi

    mkdir -p "${_source_file%/*}" || return 1
    rm -f "$_download_file"

    _connect_timeout="${MAGICNET_SUB_CONNECT_TIMEOUT:-10}"
    _max_time="${MAGICNET_SUB_MAX_TIME:-45}"

    if [ -n "${MAGICNET_SUB_PROXY:-}" ]; then
        error "Explicit subscription proxy is unsupported because it bypasses destination verification"
        rm -f "$_download_file"
        magicnet_singbox_use_cached_subscription "$_source_file" "$_cache_file" "$_identity_file" "$_expected_identity" || return 1
        return 0
    fi

    magicnet_singbox_try_fetch_subscription "$_url" "$_download_file" "$_connect_timeout" "$_max_time"
    _fetch_rc=$?
    if [ "$_fetch_rc" -eq 127 ]; then
        error "No downloader found with HTTPS address pinning: curl"
        return 1
    fi
    if [ "$_fetch_rc" -ne 0 ]; then
        warn "Failed to download subscription ${_label} with curl"
        rm -f "$_download_file"
        magicnet_singbox_use_cached_subscription "$_source_file" "$_cache_file" "$_identity_file" "$_expected_identity" || return 1
        return 0
    fi

    [ -s "$_download_file" ] || {
        error "Downloaded subscription ${_label} is empty"
        rm -f "$_download_file"
        magicnet_singbox_use_cached_subscription "$_source_file" "$_cache_file" "$_identity_file" "$_expected_identity" || return 1
        return 0
    }

    if ! mv -f "$_download_file" "$_source_file"; then
        rm -f "$_download_file" 2>/dev/null || true
        return 1
    fi
    if ! magicnet_singbox_normalize_subscription_file "$_source_file"; then
        rm -f "$_source_file" "${_source_file}.normalized" 2>/dev/null || true
        return 1
    fi
    unset _fetch_rc
}

magicnet_singbox_fetch_subscription() {
    if [ -n "${MAGICNET_SUB_SOURCE_FILE:-}" ]; then
        magicnet_singbox_fetch_local_subscription "$1"
        return $?
    fi
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

    mkdir -p "$_source_dir" "$_cache_dir" || return 1
    : >"$_sources_file" || return 1
    : >"$_cache_map" || return 1

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
            if ! printf '%s\n' "$_source_file" >>"$_sources_file"; then
                error "Failed to record subscription source #${_index}"
                return 1
            fi
            if [ -n "$_fingerprint" ]; then
                if ! printf '%s|%s|%s|%s\n' "${_source_file##*/}" "$_cache_file" "$_identity_file" "$_fingerprint" >>"$_cache_map"; then
                    error "Failed to record subscription cache metadata #${_index}"
                    return 1
                fi
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

magicnet_singbox_fetch_local_subscription() {
    _local_input="${MAGICNET_SUB_SOURCE_FILE:-${MODDIR}/.config/sing-box/subscription.local}"
    _local_generation_dir=${1%/*}
    _local_source_dir="${_local_generation_dir}/sources"
    _local_source_file="${_local_source_dir}/local-source.txt"
    _local_cache_map="${_local_generation_dir}/cache-map.txt"

    if [ ! -f "$_local_input" ] || [ ! -s "$_local_input" ]; then
        error "Local subscription source is missing or empty"
        return 1
    fi
    _local_size=$(wc -c <"$_local_input" 2>/dev/null | tr -d ' ')
    case "$_local_size" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$_local_size" -gt "$MAGICNET_SUB_MAX_RESPONSE_BYTES" ]; then
        error "Local subscription source exceeds the 8 MiB limit"
        return 1
    fi

    mkdir -p "$_local_source_dir" || return 1
    : >"$1" || return 1
    : >"$_local_cache_map" || return 1
    cp -f "$_local_input" "$_local_source_file" || return 1
    magicnet_singbox_normalize_subscription_file "$_local_source_file" || return 1
    [ -s "$_local_source_file" ] || return 1
    printf '%s\n' "$_local_source_file" >"$1" || return 1
    MAGICNET_SUB_CONFIGURED_COUNT=1
    MAGICNET_SUB_SOURCE_COUNT=1
    MAGICNET_SUB_CACHE_MAP_FILE="$_local_cache_map"
    export MAGICNET_SUB_CONFIGURED_COUNT MAGICNET_SUB_SOURCE_COUNT MAGICNET_SUB_CACHE_MAP_FILE
    unset _local_input _local_generation_dir _local_source_dir _local_source_file
    unset _local_cache_map _local_size
}
