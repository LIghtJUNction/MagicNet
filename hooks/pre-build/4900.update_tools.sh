#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
# shellcheck source=hooks/lib/release_locks.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_locks.sh"

TARGET_DIR="${KAM_MODULE_ROOT}/bin"
STATE_DIR="${KAM_MODULE_ROOT}/.local/state/tools"

install_locked_binary() {
    local name="$1"
    local version_file="$STATE_DIR/${name}.version"
    local cache_file="$STATE_DIR/${name}.asset"
    local target="$TARGET_DIR/$name"
    local tmp_dir
    local staged_file

    if ! release_lock_lookup "$name" || ! release_lock_is_valid; then
        log_error "$name: invalid repository release lock"
        return 1
    fi

    if hook_locked_cache_is_valid "$cache_file" "$version_file" "$RELEASE_LOCK_TAG" "$RELEASE_LOCK_SHA256"; then
        log_info "$name: using verified locked cache ($RELEASE_LOCK_TAG)"
    else
        tmp_dir=$(hook_make_temp_dir)
        staged_file="$tmp_dir/$RELEASE_LOCK_ASSET"
        if ! hook_download_locked_asset "$RELEASE_LOCK_REPO" "$RELEASE_LOCK_TAG" "$RELEASE_LOCK_ASSET" "$tmp_dir" >/dev/null \
            || ! hook_verify_sha256 "$staged_file" "$RELEASE_LOCK_SHA256"; then
            rm -rf "$tmp_dir"
            log_error "$name: locked download or verification failed; existing target was not changed"
            return 1
        fi
        mv -f "$staged_file" "$cache_file"
        rm -rf "$tmp_dir"
    fi

    mkdir -p "$TARGET_DIR" "$STATE_DIR"
    cp "$cache_file" "$target.new"
    chmod 0755 "$target.new"
    mv -f "$target.new" "$target"
    printf '%s\n' "$RELEASE_LOCK_TAG" >"$version_file.new"
    mv -f "$version_file.new" "$version_file"
    log_success "$name: installed locked $RELEASE_LOCK_TAG -> $target"
}

require_command curl "curl not found!"
mkdir -p "$TARGET_DIR" "$STATE_DIR"

install_locked_binary yq
install_locked_binary jq
