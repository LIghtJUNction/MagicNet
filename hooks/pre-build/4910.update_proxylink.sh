#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

MAGIC_PROXYLINK=${MAGIC_PROXYLINK:-1}
REPO_URL="https://github.com/Fanju6/Proxylink.git"
STATE_DIR="${KAM_MODULE_ROOT}/.local/state/tools"
VERSION_FILE="${STATE_DIR}/proxylink.version"
TARGET_DIR="${KAM_MODULE_ROOT}/bin"
TARGET_BIN="${TARGET_DIR}/proxylink"

if [ "$MAGIC_PROXYLINK" -eq 0 ]; then
    rm -f "$TARGET_BIN" "$VERSION_FILE"
    exit 0
fi

if ! command -v go >/dev/null 2>&1; then
    log_warn "go not found; optional Proxylink build skipped"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    log_warn "git not found; optional Proxylink build skipped"
    exit 0
fi

mkdir -p "$TARGET_DIR" "$STATE_DIR"

LATEST_REV=$(git ls-remote "$REPO_URL" HEAD 2>/dev/null | awk '{print $1}' || true)
if [ -z "$LATEST_REV" ]; then
    log_warn "Proxylink: cannot resolve upstream HEAD; optional build skipped"
    exit 0
fi

CURRENT_REV=none
[ -f "$VERSION_FILE" ] && CURRENT_REV=$(cat "$VERSION_FILE")
if [ "$CURRENT_REV" = "$LATEST_REV" ] && [ -x "$TARGET_BIN" ]; then
    log_info "Proxylink: up to date (${LATEST_REV:0:12})"
    exit 0
fi

TMP_DIR=$(mktemp -d "${KAM_MODULE_ROOT}/.tmp.proxylink.XXXXXX" 2>/dev/null || mktemp -d)
cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

log_info "Proxylink: building ${LATEST_REV:0:12}"
git clone --depth 1 "$REPO_URL" "$TMP_DIR/src" >/dev/null 2>&1 || {
    log_warn "Proxylink: git clone failed; optional build skipped"
    exit 0
}

(
    cd "$TMP_DIR/src/Proxylink" || exit 1
    GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o "$TMP_DIR/proxylink" .
) || {
    log_warn "Proxylink: go build failed; optional build skipped"
    exit 0
}

mv -f "$TMP_DIR/proxylink" "$TARGET_BIN"
chmod 0755 "$TARGET_BIN"
printf '%s\n' "$LATEST_REV" >"$VERSION_FILE"
log_success "Proxylink: installed ${LATEST_REV:0:12} -> $TARGET_BIN"
