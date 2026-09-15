#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
# shellcheck source=hooks/lib/release_locks.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_locks.sh"

MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}
VERSION_FILE="${KAM_MODULE_ROOT}/zashboard.version"
TARGET_DIR="${KAM_MODULE_ROOT}/.config/sing-box/zashboard"
CACHE_FILE="${KAM_MODULE_ROOT}/.local/state/zashboard.archive"

if [ "$MAGIC_SINGBOX" -eq 0 ]; then
    rm -rf "$VERSION_FILE" "$TARGET_DIR"
    exit 0
fi

require_command curl "curl not found!"
require_command unzip "unzip not found!"
require_command zipinfo "zipinfo not found!"
mkdir -p "$(dirname "$TARGET_DIR")"

TMP_DIR=$(hook_make_temp_dir) || exit 1
PROMOTE_DIR=""
BACKUP_DIR=""
cleanup() {
    rm -rf "$TMP_DIR" "$PROMOTE_DIR"
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] && [ ! -e "$TARGET_DIR" ]; then
        mv "$BACKUP_DIR" "$TARGET_DIR" || true
    fi
}
trap cleanup EXIT

hook_prepare_locked_asset zashboard "$CACHE_FILE" "$VERSION_FILE" || exit 1
hook_extract_archive "$CACHE_FILE" "$TMP_DIR/extract" || {
    log_error "zashboard: unsafe or invalid release archive; existing installation was not changed"
    exit 1
}

SOURCE_DIR="$TMP_DIR/extract"
if [ -f "$SOURCE_DIR/dist/index.html" ]; then
    SOURCE_DIR="$SOURCE_DIR/dist"
fi
if [ ! -f "$SOURCE_DIR/index.html" ]; then
    log_error "zashboard: release archive did not contain index.html; existing installation was not changed"
    exit 1
fi

PROMOTE_DIR=$(mktemp -d "${TARGET_DIR}.new.XXXXXX") || exit 1
cp -a "$SOURCE_DIR"/. "$PROMOTE_DIR"/
if [ ! -f "$PROMOTE_DIR/index.html" ]; then
    log_error "zashboard: staged installation did not contain index.html"
    exit 1
fi

if [ -e "$TARGET_DIR" ]; then
    BACKUP_DIR=$(mktemp -d "${TARGET_DIR}.previous.XXXXXX") || exit 1
    rmdir "$BACKUP_DIR" || exit 1
    mv "$TARGET_DIR" "$BACKUP_DIR" || exit 1
fi
if ! mv "$PROMOTE_DIR" "$TARGET_DIR"; then
    log_error "zashboard: failed to promote validated installation"
    exit 1
fi
PROMOTE_DIR=""
if [ -n "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
    BACKUP_DIR=""
fi

if ! hook_atomic_write "$VERSION_FILE" "$RELEASE_LOCK_TAG"; then
    log_error "zashboard: failed to update installed version state"
    exit 1
fi
log_success "zashboard installed: $RELEASE_LOCK_TAG -> $TARGET_DIR"
