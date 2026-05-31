#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

WEBUI_SRC_DIR="$KAM_PROJECT_ROOT/WEBUI"
WEBUI_DIST_DIR="$WEBUI_SRC_DIR/dist"
WEBUI_TARGET_DIR="$KAM_MODULE_ROOT/webroot/ui"

if [ ! -d "$WEBUI_SRC_DIR" ]; then
    log_info "WEBUI source directory not found; using bundled webroot"
    exit 0
fi

if [ -f "$WEBUI_SRC_DIR/package.json" ]; then
    if command -v pnpm >/dev/null 2>&1; then
        (cd "$WEBUI_SRC_DIR" && pnpm install --frozen-lockfile && pnpm build)
    elif command -v npm >/dev/null 2>&1; then
        (cd "$WEBUI_SRC_DIR" && npm ci && npm run build)
    else
        log_error "WEBUI package.json found but neither pnpm nor npm is installed"
        exit 1
    fi
else
    log_warn "WEBUI directory exists but package.json is missing; skipping build"
    exit 0
fi

if [ ! -d "$WEBUI_DIST_DIR" ]; then
    log_error "WEBUI build did not produce dist directory: $WEBUI_DIST_DIR"
    exit 1
fi

rm -rf "$WEBUI_TARGET_DIR"
mkdir -p "$WEBUI_TARGET_DIR"
cp -a "$WEBUI_DIST_DIR"/. "$WEBUI_TARGET_DIR"/
log_success "WEBUI build completed."
