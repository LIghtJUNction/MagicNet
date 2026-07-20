#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

# Shared helpers for GitHub release driven build hooks.

hook_sha256() {
    local file="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $2}'
    fi
}

hook_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

hook_current_version() {
    local version_file="$1"

    if [ -f "$version_file" ]; then
        cat "$version_file"
    else
        printf '%s\n' "none"
    fi
}

github_latest_tag() {
    local repo="$1"
    local attempt
    local tag

    for attempt in 1 2 3; do
        tag=""
        if tag=$(gh release view --repo "$repo" --json tagName --template '{{.tagName}}' 2>/dev/null) \
            && [ -n "$tag" ]; then
            printf '%s' "$tag"
            return 0
        fi
        [ "$attempt" -eq 3 ] || sleep 1
    done

    return 1
}

github_asset_names() {
    local repo="$1"
    local tag="$2"
    local api_json

    gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' 2>/dev/null && return 0

    api_json=$(gh api "repos/$repo/releases/tags/$tag" 2>/dev/null || true)
    [ -n "$api_json" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$api_json" | jq -r '.assets[].name'
    else
        printf '%s\n' "$api_json" | grep -o '"name":[[:space:]]*"[^"]*"' | sed -E 's/"name":[[:space:]]*"([^"]*)"/\1/'
    fi
}

hook_select_asset() {
    local asset_names="$1"
    local pattern
    local asset

    shift
    for pattern in "$@"; do
        asset=$(printf '%s\n' "$asset_names" | grep -iE "$pattern" | head -n1 || true)
        if [ -n "$asset" ]; then
            printf '%s\n' "$asset"
            return 0
        fi
    done

    return 1
}

github_asset_digest() {
    local repo="$1"
    local tag="$2"
    local asset="$3"
    local digest
    local api_json
    local line_number

    digest=$(gh release view "$tag" --repo "$repo" --json assets --jq ".assets[] | select(.name==\"$asset\") | .digest" 2>/dev/null || true)
    if [ -n "$digest" ] && [ "$digest" != "null" ]; then
        printf '%s\n' "${digest#sha256:}"
        return 0
    fi

    api_json=$(gh api "repos/$repo/releases/tags/$tag" 2>/dev/null || true)
    [ -n "$api_json" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$api_json" |
            jq -r --arg NAME "$asset" '.assets[] | select(.name==$NAME) | .digest' 2>/dev/null |
            sed 's/^sha256://'
        return 0
    fi

    line_number=$(printf '%s\n' "$api_json" | grep -n "\"name\"[[:space:]]*:[[:space:]]*\"$asset\"" | head -n1 | cut -d: -f1) || true
    [ -n "$line_number" ] || return 1

    printf '%s\n' "$api_json" |
        tail -n +"$line_number" |
        head -n 20 |
        grep -m1 '"digest"' |
        sed -E 's/.*"digest":[[:space:]]*"(sha256:)?([0-9a-fA-F]+)".*/\2/'
}

github_download_asset() {
    local repo="$1"
    local tag="$2"
    local asset="$3"
    local output_dir="$4"
    local fallback_url="${5:-}"
    local output_path="$output_dir/$asset"

    mkdir -p "$output_dir"
    rm -f "$output_path" 2>/dev/null || true

    if command -v timeout >/dev/null 2>&1; then
        timeout "${GITHUB_DOWNLOAD_TIMEOUT:-120}" gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$output_dir" --clobber >/dev/null 2>&1 && {
            printf '%s\n' "$output_path"
            return 0
        }
    elif gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$output_dir" --clobber >/dev/null 2>&1; then
        printf '%s\n' "$output_path"
        return 0
    fi

    if [ -z "$fallback_url" ]; then
        fallback_url="https://github.com/$repo/releases/download/$tag/$asset"
    fi

    if curl -fL --connect-timeout 20 --max-time "${GITHUB_DOWNLOAD_TIMEOUT:-120}" -o "$output_path" "$fallback_url"; then
        printf '%s\n' "$output_path"
        return 0
    fi

    rm -f "$output_path" 2>/dev/null || true
    return 1
}

github_verify_asset_digest() {
    local repo="$1"
    local tag="$2"
    local asset="$3"
    local file="$4"
    local remote_hash
    local local_hash

    remote_hash=$(github_asset_digest "$repo" "$tag" "$asset" 2>/dev/null || true)
    remote_hash="${remote_hash#sha256:}"

    if [ -z "$remote_hash" ] || [ "$remote_hash" = "null" ]; then
        log_warn "未获取到远端 sha256，跳过校验"
        return 0
    fi

    local_hash=$(hook_sha256 "$file" 2>/dev/null || true)
    if [ -z "$local_hash" ]; then
        log_warn "无法计算本地文件 sha256，跳过校验"
        return 0
    fi

    if [ "$(hook_lower "$local_hash")" != "$(hook_lower "$remote_hash")" ]; then
        log_error "错误：下载文件 sha256 校验失败 (local=$local_hash remote=$remote_hash)"
        return 1
    fi

    log_info "sha256 校验通过"
}

hook_make_temp_dir() {
    mktemp -d "${KAM_MODULE_ROOT}/.tmp.release.XXXXXX" 2>/dev/null || mktemp -d
}

hook_extract_binary() {
    local archive="$1"
    local tmp_dir="$2"
    local exact_name="$3"
    local fuzzy_name="${4:-*}"
    local base_name

    case "$archive" in
        *.tar.gz|*.tgz)
            require_command tar "tar not found!"
            tar -xzf "$archive" -C "$tmp_dir"
            ;;
        *.gz)
            require_command gunzip "gunzip not found!"
            cp "$archive" "$tmp_dir/"
            base_name=$(basename "$archive")
            gunzip -f "$tmp_dir/$base_name"
            ;;
        *.zip)
            require_command unzip "unzip not found!"
            unzip -o "$archive" -d "$tmp_dir" >/dev/null
            ;;
        *)
            cp "$archive" "$tmp_dir/"
            ;;
    esac

    HOOK_EXTRACTED_BINARY=$(find "$tmp_dir" -type f -name "$exact_name" -print -quit 2>/dev/null || true)
    if [ -z "$HOOK_EXTRACTED_BINARY" ]; then
        HOOK_EXTRACTED_BINARY=$(find "$tmp_dir" -type f -name "$fuzzy_name" -print -quit 2>/dev/null || true)
    fi

    [ -n "$HOOK_EXTRACTED_BINARY" ] && [ -f "$HOOK_EXTRACTED_BINARY" ]
}

github_download_if_changed() {
    local repo="$1"
    local tag="$2"
    local asset="$3"
    local fallback_url="$4"
    local local_file="$5"
    local hash_file="$6"
    local remote_hash
    local current_hash
    local tmp

    remote_hash=$(github_asset_digest "$repo" "$tag" "$asset" 2>/dev/null || true)
    remote_hash="${remote_hash#sha256:}"

    if [ -n "$remote_hash" ] && [ "$remote_hash" != "null" ] && [ -f "$hash_file" ] && [ -f "$local_file" ] && [ "$(cat "$hash_file")" = "$remote_hash" ]; then
        log_info "$asset: up to date (remote hash matched)"
        return 0
    fi

    if { [ -z "$remote_hash" ] || [ "$remote_hash" = "null" ]; } && [ -f "$hash_file" ] && [ -f "$local_file" ]; then
        current_hash=$(hook_sha256 "$local_file" 2>/dev/null || true)
        if [ -n "$current_hash" ] && [ "$current_hash" = "$(cat "$hash_file")" ]; then
            log_info "$asset: up to date (local hash matched)"
            return 0
        fi
    fi

    log_info "$asset: downloading..."
    tmp="$local_file.tmp"
    rm -f "$tmp" 2>/dev/null || true

    github_download_asset "$repo" "$tag" "$asset" "$(dirname "$local_file")" "$fallback_url" >/dev/null || {
        log_error "$asset: download failed"
        return 1
    }

    mv "$(dirname "$local_file")/$asset" "$tmp"
    github_verify_asset_digest "$repo" "$tag" "$asset" "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    current_hash=$(hook_sha256 "$tmp" 2>/dev/null || true)
    mv "$tmp" "$local_file"

    if [ -n "$remote_hash" ] && [ "$remote_hash" != "null" ]; then
        printf '%s\n' "$remote_hash" > "$hash_file"
    elif [ -n "$current_hash" ]; then
        printf '%s\n' "$current_hash" > "$hash_file"
    else
        rm -f "$hash_file" 2>/dev/null || true
    fi

    log_success "$asset: updated"
}
