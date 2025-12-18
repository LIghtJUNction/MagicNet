#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# Network utilities - internal implementation (_network.sh)
# -----------------------------------------------------------------------------
# Provides:
#   - _check_network_impl [host] [timeout]
#       check basic reachability (default host=8.8.8.8, timeout=3)
#
#   - _get_local_ip_impl
#       prints a reasonable local IP address (or empty string if undetectable)
#
#   - _download_file_impl <url> [output] [timeout_seconds] [retries]
#       downloads a URL to output (or basename(url) if omitted). Uses curl or wget.
#       Returns exit code of downloader or 1 if no downloader available.
#
# Design notes:
#   - This file is an INTERNAL implementation. Public wrappers should call these
#     functions and expose smaller, stable APIs.
#   - Prefer minimal dependencies and robust fallbacks suitable for Android and other minimal environments.
# =============================================================================

# Internal logger helper (prefer msg/err helpers if available)
_net_dbg() {
    msg "[NET] $*" 2>/dev/null || printf '%s\n' "$*"
}
_net_err() {
    err "[NET] $*" 2>/dev/null || printf 'ERROR: %s\n' "$*" >&2
}

# _check_network_impl [host] [timeout]
# Return 0 if reachable, non-zero otherwise.
_check_network_impl() {
    host="${1:-8.8.8.8}"
    timeout="${2:-3}"

    # Prefer ping when available
    if command -v ping >/dev/null 2>&1; then
        # BusyBox/inetutils compatibility: try -c 1 and -W (timeout in sec)
        if ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1; then
            return 0
        fi
        # fallback: try -c 1 -w (some implementations)
        if ping -c 1 -w "$timeout" "$host" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Fallback: check for a default route - if exists, assume network up (best-effort)
    if command -v ip >/dev/null 2>&1; then
        if ip route get "$host" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v route >/dev/null 2>&1; then
        if route -n 2>/dev/null | grep -qE 'UG'; then
            return 0
        fi
    fi

    # As last fallback when curl is available, try a TCP connect to host:80
    if command -v curl >/dev/null 2>&1; then
        if curl -sS --connect-timeout "$timeout" "http://$host/" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# _get_local_ip_impl
# Prints the best-effort primary local IP or empty string if unknown.
_get_local_ip_impl() {
    # Try ip route get (works on most modern systems)
    if command -v ip >/dev/null 2>&1; then
        # This prints a line that usually contains 'src <ip>'
        ipaddr=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){ if($i=="src"){print $(i+1); exit }}}')
        if [ -n "$ipaddr" ]; then
            printf '%s' "$ipaddr"
            return 0
        fi
    fi

    # Try hostname -I (space-separated list), pick first
    if command -v hostname >/dev/null 2>&1; then
        ipaddr=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -n "$ipaddr" ]; then
            printf '%s' "$ipaddr"
            return 0
        fi
    fi

    # Try ifconfig (less portable)
    if command -v ifconfig >/dev/null 2>&1; then
        ipaddr=$(ifconfig 2>/dev/null | awk '/inet / && $1!="127.0.0.1" {print $2; exit}' | sed 's/addr://g')
        if [ -n "$ipaddr" ]; then
            printf '%s' "$ipaddr"
            return 0
        fi
    fi

    # Unknown
    printf ''
    return 1
}

# _download_file_impl <url> [output] [timeout_seconds] [retries]
# Returns 0 on success, non-zero otherwise.
_download_file_impl() {
    url="$1"
    output="$2"
    timeout="${3:-30}"
    retries="${4:-0}"

    if [ -z "$url" ]; then
        _net_err "download_file: url is required"
        return 1
    fi

    # Default output is basename of URL
    if [ -z "$output" ]; then
        # Strip query params for filename guessing
        base="$(basename "${url%%\?*}")"
        output="${base:-download.tmp}"
    fi

    # Use a temporary file for atomic write
    tmpdir="${TMPDIR:-/data/local/tmp:/tmp:/var/tmp}"
    # choose first writable tmp dir
    for d in $(printf '%s\n' "$tmpdir" | tr ':' '\n'); do
        if [ -d "$d" ] && [ -w "$d" ]; then
            tmpfile="$d/tmp.download.$$.$RANDOM"
            break
        fi
    done
    # fallback
    : "${tmpfile:="/tmp/tmp.download.$$"}"
    rm -f "$tmpfile" 2>/dev/null || true

    # Helper to cleanup on failure/success
    _download_cleanup() {
        [ -f "$tmpfile" ] && rm -f "$tmpfile" 2>/dev/null || true
    }

    # Try curl
    if command -v curl >/dev/null 2>&1; then
        attempt=0
        while :; do
            attempt=$((attempt + 1))
            # -f: fail on HTTP errors; -S: show errors; -L follow redirects
            if curl -fSL --connect-timeout "$timeout" -o "$tmpfile" "$url" >/dev/null 2>&1; then
                mv "$tmpfile" "$output" 2>/dev/null || cp "$tmpfile" "$output"
                chmod 0644 "$output" 2>/dev/null || true
                return 0
            else
                _net_dbg "curl attempt $attempt failed for $url"
            fi
            [ "$attempt" -gt "$retries" ] && break
            sleep 1
        done
        _download_cleanup
        _net_err "curl failed to download $url"
        return 2
    fi

    # Try wget
    if command -v wget >/dev/null 2>&1; then
        attempt=0
        while :; do
            attempt=$((attempt + 1))
            if wget -q -T "$timeout" -O "$tmpfile" "$url"; then
                mv "$tmpfile" "$output" 2>/dev/null || cp "$tmpfile" "$output"
                chmod 0644 "$output" 2>/dev/null || true
                return 0
            else
                _net_dbg "wget attempt $attempt failed for $url"
            fi
            [ "$attempt" -gt "$retries" ] && break
            sleep 1
        done
        _download_cleanup
        _net_err "wget failed to download $url"
        return 2
    fi

    _net_err "No suitable downloader found (curl or wget required)"
    _download_cleanup
    return 3
}

# Convenience small helpers (thin)
# _network_wait_for (host timeout attempts)
# Waits for network reachability up to attempts (sleep 1 between)
_network_wait_for_impl() {
    host="${1:-8.8.8.8}"
    timeout="${2:-3}"
    attempts="${3:-30}" # defaults to 30 cycles
    i=0
    while [ "$i" -lt "$attempts" ]; do
        if _check_network_impl "$host" "$timeout"; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

# End of _network.sh
