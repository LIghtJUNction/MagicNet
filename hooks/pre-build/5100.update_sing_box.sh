#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
# shellcheck source=hooks/lib/release_locks.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_locks.sh"

MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}
VERSION_FILE="${KAM_MODULE_ROOT}/singbox.version"
TARGET_DIR="${KAM_MODULE_ROOT}/bin"
TARGET_BIN="${TARGET_DIR}/sing-box"
STATE_DIR="${KAM_MODULE_ROOT}/.local/state"
CACHE_FILE="${STATE_DIR}/sing-box.archive"

if [ "$MAGIC_SINGBOX" -eq 0 ]; then
    rm -f "$VERSION_FILE" "$TARGET_BIN"
    exit 0
fi

require_command curl "curl not found!"
require_command tar "tar not found!"
mkdir -p "$TARGET_DIR" "$STATE_DIR"

if ! release_lock_lookup sing-box || ! release_lock_is_valid; then
    log_error "sing-box: invalid repository release lock"
    exit 1
fi

TMP_DIR=$(hook_make_temp_dir)
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if hook_locked_cache_is_valid "$CACHE_FILE" "$VERSION_FILE" "$RELEASE_LOCK_TAG" "$RELEASE_LOCK_SHA256"; then
    log_info "sing-box: using verified locked cache ($RELEASE_LOCK_TAG)"
else
    DOWNLOAD_PATH="$TMP_DIR/$RELEASE_LOCK_ASSET"
    if ! hook_download_locked_asset "$RELEASE_LOCK_REPO" "$RELEASE_LOCK_TAG" "$RELEASE_LOCK_ASSET" "$TMP_DIR" >/dev/null \
        || ! hook_verify_sha256 "$DOWNLOAD_PATH" "$RELEASE_LOCK_SHA256"; then
        log_error "sing-box: locked download or verification failed; existing target was not changed"
        exit 1
    fi
    mv -f "$DOWNLOAD_PATH" "$CACHE_FILE"
fi

hook_extract_binary "$CACHE_FILE" "$TMP_DIR/extract" "sing-box" "*sing*box*" || {
    log_error "sing-box: release archive did not contain a safe executable"
    exit 1
}

cp "$HOOK_EXTRACTED_BINARY" "$TARGET_BIN.new"
chmod 0755 "$TARGET_BIN.new"
mv -f "$TARGET_BIN.new" "$TARGET_BIN"
printf '%s\n' "$RELEASE_LOCK_TAG" >"$VERSION_FILE.new"
mv -f "$VERSION_FILE.new" "$VERSION_FILE"

log_success "sing-box installed: $RELEASE_LOCK_TAG -> $TARGET_BIN"
