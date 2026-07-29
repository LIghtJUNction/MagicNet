#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

MAGIC_PROXYLINK=${MAGIC_PROXYLINK:-1}
REPO_URL="https://github.com/Fanju6/Proxylink.git"
PINNED_REV="44929c0984944870297c260dc43a4aa9262f9e1c"
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

CURRENT_REV=none
[ -f "$VERSION_FILE" ] && CURRENT_REV=$(cat "$VERSION_FILE")
if [ "$CURRENT_REV" = "$PINNED_REV" ] && [ -x "$TARGET_BIN" ]; then
    log_info "Proxylink: pinned revision already installed (${PINNED_REV:0:12})"
    exit 0
fi

# Do not retain an executable whose provenance is not the reviewed revision.
rm -f "$TARGET_BIN" "$VERSION_FILE"
mkdir -p "$TARGET_DIR" "$STATE_DIR"

TMP_DIR=$(mktemp -d "${KAM_MODULE_ROOT}/.tmp.proxylink.XXXXXX" 2>/dev/null || mktemp -d)
cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

log_info "Proxylink: building pinned revision ${PINNED_REV:0:12}"
git init -q "$TMP_DIR/src" &&
    git -C "$TMP_DIR/src" remote add origin "$REPO_URL" &&
    git -C "$TMP_DIR/src" fetch -q --depth 1 origin "$PINNED_REV" &&
    git -C "$TMP_DIR/src" checkout -q --detach "$PINNED_REV" &&
    [ "$(git -C "$TMP_DIR/src" rev-parse HEAD)" = "$PINNED_REV" ] || {
    log_warn "Proxylink: pinned revision is unavailable; optional build skipped"
    exit 0
}

(
    cd "$TMP_DIR/src/Proxylink" || exit 1
    GOOS=linux GOARCH=arm64 go build -mod=readonly -trimpath -ldflags="-s -w" -o "$TMP_DIR/proxylink" .
) || {
    log_warn "Proxylink: go build failed; optional build skipped"
    exit 0
}

mv -f "$TMP_DIR/proxylink" "$TARGET_BIN"
chmod 0755 "$TARGET_BIN"
printf '%s\n' "$PINNED_REV" >"$VERSION_FILE"
log_success "Proxylink: installed ${PINNED_REV:0:12} -> $TARGET_BIN"
