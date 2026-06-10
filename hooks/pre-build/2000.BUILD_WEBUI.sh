#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

PROJECT_ROOT="${KAM_PROJECT_ROOT:-$(cd "$KAM_HOOKS_ROOT/.." && pwd)}"
WEBUI_ROOT="${PROJECT_ROOT}/webui"
WEBUI_DIST="${WEBUI_ROOT}/dist"
TARGET_DIR="${KAM_MODULE_ROOT}/webroot"

if [ ! -f "${WEBUI_ROOT}/package.json" ]; then
    log_error "WebUI package.json not found: ${WEBUI_ROOT}/package.json"
    exit 1
fi

if command -v bun >/dev/null 2>&1; then
    log_info "Building MagicNet WebUI with bun"
    (cd "$WEBUI_ROOT" && bun install --frozen-lockfile && bun run build)
elif command -v npm >/dev/null 2>&1; then
    log_info "Building MagicNet WebUI with npm"
    (cd "$WEBUI_ROOT" && npm install && npm run build)
else
    log_error "bun or npm is required to build MagicNet WebUI"
    exit 1
fi

if [ ! -f "${WEBUI_DIST}/index.html" ]; then
    log_error "WebUI build did not produce ${WEBUI_DIST}/index.html"
    exit 1
fi

rm -rf "${TARGET_DIR}/assets" "${TARGET_DIR}/index.html"
mkdir -p "$TARGET_DIR"
cp -a "${WEBUI_DIST}/." "$TARGET_DIR/"

if [ ! -f "${TARGET_DIR}/index.html" ]; then
    log_error "WebUI copy did not produce ${TARGET_DIR}/index.html"
    exit 1
fi

log_success "MagicNet WebUI installed to ${TARGET_DIR}"
