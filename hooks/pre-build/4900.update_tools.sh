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

    hook_prepare_locked_asset "$name" "$cache_file" "$version_file" || return 1
    if ! hook_atomic_install_file "$cache_file" "$target" 0755; then
        log_error "$name: failed to promote verified binary"
        return 1
    fi
    if ! hook_atomic_write "$version_file" "$RELEASE_LOCK_TAG"; then
        log_error "$name: failed to update installed version state"
        return 1
    fi

    log_success "$name: installed locked $RELEASE_LOCK_TAG -> $target"
}

require_command curl "curl not found!"
mkdir -p "$TARGET_DIR" "$STATE_DIR"

install_locked_binary yq
install_locked_binary jq
