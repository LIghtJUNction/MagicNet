#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

# Shared helpers for locked GitHub release build hooks.

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

hook_current_version() {
    local version_file="$1"

    if [ -f "$version_file" ]; then
        cat "$version_file"
    else
        printf '%s\n' "none"
    fi
}

hook_verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        log_error "invalid locked sha256 for $(basename "$file")"
        return 1
    fi
    if [ ! -f "$file" ]; then
        log_error "missing release artifact: $file"
        return 1
    fi

    actual=$(hook_sha256 "$file" 2>/dev/null || true)
    if [[ ! "$actual" =~ ^[0-9A-Fa-f]{64}$ ]]; then
        log_error "cannot calculate sha256 for $(basename "$file")"
        return 1
    fi
    if [ "${actual,,}" != "$expected" ]; then
        log_error "sha256 verification failed for $(basename "$file")"
        return 1
    fi
}

hook_locked_cache_is_valid() {
    local artifact="$1"
    local version_file="$2"
    local expected_tag="$3"
    local expected_sha256="$4"

    [ -f "$artifact" ] \
        && [ "$(hook_current_version "$version_file")" = "$expected_tag" ] \
        && hook_verify_sha256 "$artifact" "$expected_sha256"
}

hook_download_locked_asset() {
    local repo="$1"
    local tag="$2"
    local asset="$3"
    local output_dir="$4"
    local output_path
    local url

    case "$repo" in
        */*) ;;
        *) log_error "invalid locked release repository"; return 1 ;;
    esac
    case "$tag" in
        ""|*/*) log_error "invalid locked release tag"; return 1 ;;
    esac
    case "$asset" in
        ""|*/*) log_error "invalid locked release asset"; return 1 ;;
    esac

    mkdir -p "$output_dir" || return 1
    output_path="$output_dir/$asset"
    url="https://github.com/$repo/releases/download/$tag/$asset"
    rm -f "$output_path"

    if ! curl -fL --connect-timeout 20 --max-time "${GITHUB_DOWNLOAD_TIMEOUT:-120}" -o "$output_path" "$url"; then
        rm -f "$output_path"
        return 1
    fi

    printf '%s\n' "$output_path"
}

hook_make_temp_dir() {
    mktemp -d "${KAM_MODULE_ROOT}/.tmp.release.XXXXXX" 2>/dev/null || mktemp -d
}

hook_validate_archive_member_path() {
    local member="$1"

    case "$member" in
        /*|\\*|../*|*/../*|..|..\\*|*\\..\\*)
            log_error "unsafe archive member path: $member"
            return 1
            ;;
    esac
}

hook_preflight_archive() {
    local archive="$1"
    local member
    local entry
    local type

    case "$archive" in
        *.tar.gz|*.tgz)
            require_command tar "tar not found!"
            tar -tzf "$archive" >/dev/null || return 1
            while IFS= read -r member; do
                hook_validate_archive_member_path "$member" || return 1
            done < <(tar -tzf "$archive")
            LC_ALL=C tar -tvzf "$archive" >/dev/null || return 1
            while IFS= read -r entry; do
                type="${entry:0:1}"
                case "$type" in
                    -|d) ;;
                    *)
                        log_error "unsafe non-regular archive member: $entry"
                        return 1
                        ;;
                esac
            done < <(LC_ALL=C tar -tvzf "$archive")
            ;;
        *.zip)
            require_command unzip "unzip not found!"
            require_command zipinfo "zipinfo not found!"
            unzip -Z -1 "$archive" >/dev/null || return 1
            while IFS= read -r member; do
                hook_validate_archive_member_path "$member" || return 1
            done < <(unzip -Z -1 "$archive")
            zipinfo -l "$archive" >/dev/null || return 1
            while IFS= read -r entry; do
                case "$entry" in
                    -*) ;;
                    d*) ;;
                    [bclps]*)
                        log_error "unsafe non-regular archive member: $entry"
                        return 1
                        ;;
                    *) ;;
                esac
            done < <(zipinfo -l "$archive")
            ;;
        *)
            log_error "unsupported release archive: $archive"
            return 1
            ;;
    esac
}

hook_extract_archive() {
    local archive="$1"
    local destination="$2"

    hook_preflight_archive "$archive" || return 1
    mkdir -p "$destination" || return 1
    case "$archive" in
        *.tar.gz|*.tgz) tar -xzf "$archive" -C "$destination" ;;
        *.zip) unzip -o "$archive" -d "$destination" >/dev/null ;;
    esac
}

hook_extract_binary() {
    local archive="$1"
    local tmp_dir="$2"
    local exact_name="$3"
    local fuzzy_name="${4:-*}"

    hook_extract_archive "$archive" "$tmp_dir" || return 1
    HOOK_EXTRACTED_BINARY=$(find "$tmp_dir" -type f -name "$exact_name" -print -quit 2>/dev/null || true)
    if [ -z "$HOOK_EXTRACTED_BINARY" ]; then
        HOOK_EXTRACTED_BINARY=$(find "$tmp_dir" -type f -name "$fuzzy_name" -print -quit 2>/dev/null || true)
    fi

    [ -n "$HOOK_EXTRACTED_BINARY" ] && [ -f "$HOOK_EXTRACTED_BINARY" ]
}
