#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
# shellcheck source=hooks/lib/release_locks.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_locks.sh"

MAGIC_ECAPTURE=${MAGIC_ECAPTURE:-1}
VERSION_FILE="${KAM_MODULE_ROOT}/ecapture.version"
TARGET_BIN="${KAM_MODULE_ROOT}/bin/ecapture"
CACHE_FILE="${KAM_MODULE_ROOT}/.local/state/ecapture.archive"

if [ "$MAGIC_ECAPTURE" -eq 0 ]; then
    rm -f "$VERSION_FILE" "$TARGET_BIN"
    exit 0
fi

require_commands curl tar

TMP_DIR=$(hook_make_temp_dir) || exit 1
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

hook_prepare_locked_asset ecapture "$CACHE_FILE" "$VERSION_FILE" || exit 1
hook_extract_binary "$CACHE_FILE" "$TMP_DIR/extract" "ecapture" "*ecapture*" || {
    log_error "ecapture: release archive did not contain a safe executable"
    exit 1
}

if ! hook_atomic_install_file "$HOOK_EXTRACTED_BINARY" "$TARGET_BIN" 0755; then
    log_error "ecapture: failed to promote extracted executable"
    exit 1
fi
if ! hook_atomic_write "$VERSION_FILE" "$RELEASE_LOCK_TAG"; then
    log_error "ecapture: failed to update installed version state"
    exit 1
fi

log_success "ecapture installed: $RELEASE_LOCK_TAG -> $TARGET_BIN"
