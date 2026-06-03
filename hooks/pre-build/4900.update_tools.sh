#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"

TARGET_DIR="${KAM_MODULE_ROOT}/.local/bin"
STATE_DIR="${KAM_MODULE_ROOT}/.local/state/tools"

install_release_binary() {
    local name="$1"
    local repo="$2"
    local asset="$3"
    local version_file="$STATE_DIR/${name}.version"
    local target="$TARGET_DIR/$name"
    local current_version
    local latest_tag
    local download_url
    local download_path

    current_version=$(hook_current_version "$version_file")
    latest_tag=$(github_latest_tag "$repo")
    [ -n "$latest_tag" ] || {
        log_error "$name: cannot resolve latest release tag from $repo"
        return 1
    }

    if [ "$current_version" = "$latest_tag" ] && [ -x "$target" ]; then
        log_info "$name: up to date ($latest_tag)"
        return 0
    fi

    log_info "$name: downloading $asset from $repo $latest_tag"
    download_url="https://github.com/${repo}/releases/download/${latest_tag}/${asset}"
    download_path=$(github_download_asset "$repo" "$latest_tag" "$asset" "$KAM_MODULE_ROOT" "$download_url") || {
        log_error "$name: download failed"
        return 1
    }

    github_verify_asset_digest "$repo" "$latest_tag" "$asset" "$download_path" || return 1
    mv -f "$download_path" "$target"
    chmod 0755 "$target"
    printf '%s\n' "$latest_tag" >"$version_file"
    log_success "$name: installed $latest_tag -> $target"
}

require_command gh "github-cli not found!"
require_command curl "curl not found!"

mkdir -p "$TARGET_DIR" "$STATE_DIR"

install_release_binary yq mikefarah/yq yq_linux_arm64
install_release_binary jq jqlang/jq jq-linux-arm64
