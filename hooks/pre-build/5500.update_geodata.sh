#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

# Ensure gh is available
require_command gh "gh not installed!"

# Assets (kept for fallback curl download if needed)
export geoip=https://github.com/DustinWin/ruleset_geodata/releases/download/mihomo-geodata/geoip-all.dat
export geosite=https://github.com/DustinWin/ruleset_geodata/releases/download/mihomo-geodata/geosite-all.dat

# Repository / release tag used by gh
REPO="DustinWin/ruleset_geodata"
TAG="mihomo-geodata"
API_PATH="repos/$REPO/releases/tags/$TAG"

# Destination directory for data and hash files
DATA_DIR="$KAM_MODULE_ROOT/.config/mihomo"
HASH_DIR="$KAM_MODULE_ROOT/.local/state/geodata"
mkdir -p "$DATA_DIR"
mkdir -p "$HASH_DIR"

# Compute sha256 of a file (portable)
compute_sha256() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$f" | awk '{print $2}'
    else
        echo ""
    fi
}

# Get remote sha256 (hex only) using gh (preferred) and fallback to parsing API JSON.
# Returns the hex string on stdout, or empty if not available.
get_remote_hash() {
    local asset="$1"

    # Try `gh release view` with --json / --jq first (preferred, authed)
    if command -v gh >/dev/null 2>&1; then
        local digest
        digest=$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name==\"$asset\") | .digest" 2>/dev/null || true)
        if [ -n "$digest" ] && [ "$digest" != "null" ]; then
            # strip potential 'sha256:' prefix
            echo "${digest#sha256:}"
            return 0
        fi
    fi

    # Fallback: try gh api to fetch release JSON, then parse (jq if present)
    local api_json
    if command -v gh >/dev/null 2>&1; then
        api_json=$(gh api "$API_PATH" 2>/dev/null || true)
    else
        api_json=$(curl -sS "https://api.github.com/$API_PATH" || true)
    fi

    if [ -z "$api_json" ]; then
        echo ""
        return 1
    fi

    if command -v jq >/dev/null 2>&1; then
        echo "$api_json" | jq -r --arg NAME "$asset" '.assets[] | select(.name==$NAME) | .digest' 2>/dev/null | sed 's/^sha256://'
        return 0
    fi

    # Grep + sed fallback
    local ln
    ln=$(echo "$api_json" | grep -n "\"name\":[[:space:]]*\"$asset\"" | head -n1 | cut -d: -f1) || true
    if [ -z "$ln" ]; then
        echo ""
        return 2
    fi
    echo "$api_json" | tail -n +"$ln" | head -n 20 | grep -m1 '"digest"' | sed -E 's/.*"digest":[[:space:]]*"(sha256:)?([0-9a-fA-F]+)".*/\2/'
}

# Download asset only when necessary (compare by hash). Uses gh release download; falls back to curl if needed.
download_if_needed() {
    local asset_name="$1"   # e.g. geoip-all.dat
    local url="$2"          # fallback direct URL
    local local_file="$3"   # destination file (e.g. GeoIP.dat)
    local hash_file="$4"    # destination hash file (e.g. geoip.hash)

    local remote_hash
    remote_hash=$(get_remote_hash "$asset_name" 2>/dev/null || true)
    remote_hash="${remote_hash#sha256:}"  # just in case

    # If remote hash available and matches saved hash and file exists -> skip
    if [ -n "$remote_hash" ] && [ -f "$hash_file" ] && [ -f "$local_file" ]; then
        if [ "$(cat "$hash_file")" = "$remote_hash" ]; then
            echo "$asset_name: up to date (remote hash matched)"
            return 0
        fi
    fi

    # If remote hash not available, check local hash vs saved hash as an optimization
    if [ -z "$remote_hash" ] && [ -f "$hash_file" ] && [ -f "$local_file" ]; then
        local saved
        saved=$(cat "$hash_file" 2>/dev/null || true)
        if [ -n "$saved" ]; then
            local current
            current=$(compute_sha256 "$local_file")
            if [ -n "$current" ] && [ "$current" = "$saved" ]; then
                echo "$asset_name: up to date (local hash matched)"
                return 0
            fi
        fi
    fi

    echo "$asset_name: downloading..."

    local tmp="$local_file.tmp"
    rm -f "$tmp" "$DATA_DIR/$asset_name" 2>/dev/null || true

    # Prefer gh release download
    if command -v gh >/dev/null 2>&1; then
        if ! gh release download "$TAG" --repo "$REPO" --pattern "$asset_name" --dir "$DATA_DIR" --clobber >/dev/null 2>&1; then
            echo "$asset_name: gh release download failed; attempting curl fallback" >&2
            # fallthrough to curl fallback below
        fi
    fi

    # If asset not present in DATA_DIR (or gh failed), try curl fallback
    if [ ! -f "$DATA_DIR/$asset_name" ]; then
        if [ -n "$url" ]; then
            if ! curl -sSL -f "$url" -o "$DATA_DIR/$asset_name"; then
                echo "$asset_name: download failed (both gh and curl attempts failed)" >&2
                rm -f "$DATA_DIR/$asset_name" 2>/dev/null || true
                return 1
            fi
        else
            echo "$asset_name: no download URL available and gh failed" >&2
            return 1
        fi
    fi

    # Move downloaded asset to tmp for verification
    mv "$DATA_DIR/$asset_name" "$tmp" 2>/dev/null || {
        echo "$asset_name: failed to move downloaded file" >&2
        rm -f "$tmp" "$DATA_DIR/$asset_name" 2>/dev/null || true
        return 1
    }

    # Compute sha256 of downloaded file
    local computed
    computed=$(compute_sha256 "$tmp" 2>/dev/null || true)

    # If remote hash known, verify it
    if [ -n "$remote_hash" ] && [ -n "$computed" ] && [ "$computed" != "$remote_hash" ]; then
        echo "$asset_name: hash mismatch after download (computed=$computed remote=$remote_hash)" >&2
        rm -f "$tmp"
        return 1
    fi

    # Move into final location
    mv "$tmp" "$local_file"

    # Save the hash (prefer remote hash, otherwise use computed)
    if [ -n "$remote_hash" ]; then
        echo "$remote_hash" > "$hash_file"
    elif [ -n "$computed" ]; then
        echo "$computed" > "$hash_file"
    else
        rm -f "$hash_file" 2>/dev/null || true
    fi

    echo "$asset_name: updated"
    return 0
}

# Pre-fetch release metadata to speed up multiple lookups (optional)
# Try gh first (authenticated), fallback to curl
if command -v gh >/dev/null 2>&1; then
    api_json=$(gh api "$API_PATH" 2>/dev/null || true)
else
    api_json=$(curl -sS "https://api.github.com/$API_PATH" || true)
fi

# Update the two assets (only download when changed)
download_if_needed "geoip-all.dat" "$geoip" "$DATA_DIR/GeoIP.dat" "$HASH_DIR/geoip.hash" "$api_json"
download_if_needed "geosite-all.dat" "$geosite" "$DATA_DIR/GeoSite.dat" "$HASH_DIR/geosite.hash" "$api_json"
