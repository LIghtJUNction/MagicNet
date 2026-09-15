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

# Resolve the reviewed lock for COMPONENT and ensure CACHE_FILE contains the
# verified immutable asset. VERSION_FILE tracks the successfully promoted
# component version, so a failed install never makes an unpromoted cache look
# current. The resolved RELEASE_LOCK_* variables remain available to callers.
hook_prepare_locked_asset() {
    local component="$1"
    local cache_file="$2"
    local version_file="$3"
    local tmp_dir
    local download_path

    if ! type release_lock_lookup >/dev/null 2>&1 || ! type release_lock_is_valid >/dev/null 2>&1; then
        log_error "$component: release lock helpers are not loaded"
        return 1
    fi
    if ! release_lock_lookup "$component" || ! release_lock_is_valid; then
        log_error "$component: invalid repository release lock"
        return 1
    fi

    mkdir -p "$(dirname "$cache_file")" || return 1
    if hook_locked_cache_is_valid "$cache_file" "$version_file" "$RELEASE_LOCK_TAG" "$RELEASE_LOCK_SHA256"; then
        log_info "$component: using verified locked cache ($RELEASE_LOCK_TAG)"
        return 0
    fi

    tmp_dir=$(hook_make_temp_dir) || {
        log_error "$component: failed to create release staging directory"
        return 1
    }
    download_path="$tmp_dir/$RELEASE_LOCK_ASSET"

    if ! hook_download_locked_asset "$RELEASE_LOCK_REPO" "$RELEASE_LOCK_TAG" "$RELEASE_LOCK_ASSET" "$tmp_dir" >/dev/null \
        || ! hook_verify_sha256 "$download_path" "$RELEASE_LOCK_SHA256"; then
        rm -rf "$tmp_dir"
        log_error "$component: locked download or verification failed; existing installation was not changed"
        return 1
    fi

    if ! mv -f "$download_path" "$cache_file"; then
        rm -rf "$tmp_dir"
        log_error "$component: failed to promote verified release cache"
        return 1
    fi
    rm -rf "$tmp_dir"
}

hook_atomic_install_file() {
    local source="$1"
    local target="$2"
    local mode="${3:-0644}"
    local staged="${target}.new.$$"

    mkdir -p "$(dirname "$target")" || return 1
    rm -f "$staged"
    if ! cp "$source" "$staged" \
        || ! chmod "$mode" "$staged" \
        || ! mv -f "$staged" "$target"; then
        rm -f "$staged"
        return 1
    fi
}

hook_atomic_write() {
    local target="$1"
    local value="$2"
    local staged="${target}.new.$$"

    mkdir -p "$(dirname "$target")" || return 1
    rm -f "$staged"
    if ! printf '%s\n' "$value" >"$staged" \
        || ! mv -f "$staged" "$target"; then
        rm -f "$staged"
        return 1
    fi
}

hook_release_asset_api_url() {
    local metadata_path="$1"
    local asset="$2"
    local parser=""

    if command -v python3 >/dev/null 2>&1; then
        parser=python3
    elif command -v python >/dev/null 2>&1; then
        parser=python
    fi

    if [ -n "$parser" ]; then
        "$parser" - "$metadata_path" "$asset" <<'PY'
import json
import re
import sys

path, wanted = sys.argv[1:]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
for item in data.get("assets", []):
    if item.get("name") != wanted:
        continue
    url = item.get("url", "")
    if re.fullmatch(r"https://api\.github\.com/repos/[^/]+/[^/]+/releases/assets/[0-9]+", url):
        print(url)
        raise SystemExit(0)
raise SystemExit(1)
PY
        return
    fi

    # Minimal parser fallback for build hosts without Python. Only accept GitHub's
    # canonical release-asset API URL and an exact asset-name match.
    awk -v wanted="$asset" '
        /"url": "https:\/\/api\.github\.com\/repos\/[^\"]+\/releases\/assets\/[0-9]+"/ {
            candidate = $0
            sub(/^.*"url": "/, "", candidate)
            sub(/".*$/, "", candidate)
        }
        /"name": "/ {
            name = $0
            sub(/^.*"name": "/, "", name)
            sub(/".*$/, "", name)
            if (name == wanted && candidate != "") {
                print candidate
                exit
            }
        }
    ' "$metadata_path"
}

hook_download_locked_asset() {
    local repo="$1"
    local tag="$2"
    local asset="$3"
    local output_dir="$4"
    local output_path
    local url
    local attempt
    local metadata_path
    local asset_api_url
    local github_token

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
    for attempt in 1 2 3; do
        rm -f "$output_path"

        if curl -fL --connect-timeout 20 --max-time "${GITHUB_DOWNLOAD_TIMEOUT:-120}" -o "$output_path" "$url"; then
            printf '%s\n' "$output_path"
            return 0
        fi

        rm -f "$output_path"
        [ "$attempt" -eq 3 ] || sleep 1
    done

    # The browser-style release endpoint and GitHub's REST asset endpoint can
    # traverse different edges. Resolve the exact asset through the public REST
    # API, then request its binary stream. This remains an official GitHub path;
    # callers still verify the immutable lock SHA256 before promoting the file.
    metadata_path="$output_dir/.${asset}.release.json"
    rm -f "$metadata_path" "$output_path"
    if curl -fsSL \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        --connect-timeout 20 \
        --max-time "${GITHUB_DOWNLOAD_TIMEOUT:-120}" \
        -o "$metadata_path" \
        "https://api.github.com/repos/$repo/releases/tags/$tag"; then
        asset_api_url=$(hook_release_asset_api_url "$metadata_path" "$asset" 2>/dev/null || true)
        rm -f "$metadata_path"
        if [[ "$asset_api_url" =~ ^https://api\.github\.com/repos/[^/]+/[^/]+/releases/assets/[0-9]+$ ]] \
            && curl -fL \
                -H 'Accept: application/octet-stream' \
                -H 'X-GitHub-Api-Version: 2022-11-28' \
                --connect-timeout 20 \
                --max-time "${GITHUB_DOWNLOAD_TIMEOUT:-120}" \
                -o "$output_path" \
                "$asset_api_url"; then
            printf '%s\n' "$output_path"
            return 0
        fi
    fi
    rm -f "$metadata_path" "$output_path"

    # Last resort for environments with a credential that can read the locked
    # repository. A repository-scoped Actions token may not have cross-repo
    # access, so this path is deliberately secondary to the public REST fallback.
    github_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [ -n "$github_token" ] && command -v gh >/dev/null 2>&1; then
        if GH_TOKEN="$github_token" gh release download "$tag" \
            --repo "$repo" \
            --pattern "$asset" \
            --dir "$output_dir" >/dev/null 2>&1 \
            && [ -f "$output_path" ]; then
            printf '%s\n' "$output_path"
            return 0
        fi
        rm -f "$output_path"
    fi

    return 1
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

hook_archive_format() {
    local archive="$1"
    local first_member

    case "$archive" in
        *.tar.gz|*.tgz)
            printf '%s\n' tar
            ;;
        *.zip)
            printf '%s\n' zip
            ;;
        *.archive)
            if command -v tar >/dev/null 2>&1 \
                && IFS= read -r first_member < <(tar -tzf "$archive" 2>/dev/null) \
                && [ -n "$first_member" ]; then
                printf '%s\n' tar
            elif command -v unzip >/dev/null 2>&1 && command -v zipinfo >/dev/null 2>&1 \
                && unzip -Z -1 "$archive" >/dev/null 2>&1; then
                printf '%s\n' zip
            else
                log_error "unsupported release archive: $archive"
                return 1
            fi
            ;;
        *)
            log_error "unsupported release archive: $archive"
            return 1
            ;;
    esac
}

hook_preflight_archive() {
    local archive="$1"
    local archive_format
    local member
    local entry
    local type

    HOOK_PREFLIGHT_ARCHIVE_FORMAT=""
    archive_format=$(hook_archive_format "$archive") || return 1

    case "$archive_format" in
        tar)
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
        zip)
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
    esac

    HOOK_PREFLIGHT_ARCHIVE_FORMAT="$archive_format"
}

hook_extract_archive() {
    local archive="$1"
    local destination="$2"
    local archive_format

    HOOK_PREFLIGHT_ARCHIVE_FORMAT=""
    hook_preflight_archive "$archive" || return 1
    archive_format="$HOOK_PREFLIGHT_ARCHIVE_FORMAT"
    mkdir -p "$destination" || return 1
    case "$archive_format" in
        tar) tar -xzf "$archive" -C "$destination" ;;
        zip) unzip -o "$archive" -d "$destination" >/dev/null ;;
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
