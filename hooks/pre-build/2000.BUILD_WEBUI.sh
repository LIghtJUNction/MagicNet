#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

PROJECT_ROOT="${KAM_PROJECT_ROOT:-$(cd "$KAM_HOOKS_ROOT/.." && pwd)}"
WEBUI_ROOT="${PROJECT_ROOT}/webui"
WEBUI_DIST="${WEBUI_ROOT}/dist"
TARGET_DIR="${KAM_MODULE_ROOT}/webroot"
CACHE_STAMP="${WEBUI_DIST}/.magicnet-build-key"

if [ ! -f "${WEBUI_ROOT}/package.json" ]; then
    log_error "WebUI package.json not found: ${WEBUI_ROOT}/package.json"
    exit 1
fi

if command -v bun >/dev/null 2>&1; then
    PACKAGE_MANAGER=bun
elif command -v npm >/dev/null 2>&1; then
    PACKAGE_MANAGER=npm
else
    log_error "bun or npm is required to build MagicNet WebUI"
    exit 1
fi

hash_input_file() {
    _input="$1"
    printf '%s\0' "$_input"
    if [ -L "${PROJECT_ROOT}/${_input}" ]; then
        printf 'link:%s\0' "$(readlink "${PROJECT_ROOT}/${_input}")"
    elif [ -f "${PROJECT_ROOT}/${_input}" ]; then
        sha256sum "${PROJECT_ROOT}/${_input}"
    else
        printf 'missing\n'
    fi
    unset _input
}

webui_build_key() {
    (
        printf 'magicnet-webui-build-v2\nmanager=%s\n' "$PACKAGE_MANAGER"
        if [ "$PACKAGE_MANAGER" = bun ]; then
            bun --version
        else
            node --version 2>/dev/null || true
            npm --version
        fi

        if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            while IFS= read -r -d '' _file; do
                case "$_file" in
                webui/dist/* | webui/node_modules/*) continue ;;
                esac
                hash_input_file "$_file"
            done < <(git -C "$PROJECT_ROOT" ls-files -z -- webui)
        else
            while IFS= read -r -d '' _file; do
                _relative="${_file#${PROJECT_ROOT}/}"
                hash_input_file "$_relative"
            done < <(find "$WEBUI_ROOT" -type f \
                ! -path "$WEBUI_DIST/*" ! -path "$WEBUI_ROOT/node_modules/*" \
                -print0 | LC_ALL=C sort -z)
        fi

        printf 'hook='
        sha256sum "$KAM_HOOKS_ROOT/pre-build/2000.BUILD_WEBUI.sh"
        printf 'vite-env='
        env | LC_ALL=C sort | grep '^VITE_' | sha256sum
    ) | sha256sum | cut -d' ' -f1
}

webui_dist_digest() {
    [ -f "${WEBUI_DIST}/index.html" ] || return 1
    find "$WEBUI_DIST" -type f ! -name '.magicnet-build-key' -print0 |
        LC_ALL=C sort -z |
        xargs -0 -r sha256sum |
        sha256sum | cut -d' ' -f1
}

BUILD_KEY="$(webui_build_key)"
USE_CACHED_BUILD=0
if [ -f "$CACHE_STAMP" ] && [ -f "${WEBUI_DIST}/index.html" ]; then
    read -r CACHED_KEY CACHED_DIGEST <"$CACHE_STAMP" || true
    CURRENT_DIGEST="$(webui_dist_digest 2>/dev/null || true)"
    if [ "$CACHED_KEY" = "$BUILD_KEY" ] && [ -n "$CURRENT_DIGEST" ] && \
        [ "$CACHED_DIGEST" = "$CURRENT_DIGEST" ]; then
        USE_CACHED_BUILD=1
    fi
fi

if [ "$USE_CACHED_BUILD" -eq 1 ]; then
    log_info "Reusing verified MagicNet WebUI build cache"
elif [ "$PACKAGE_MANAGER" = bun ]; then
    log_info "Testing and building MagicNet WebUI with bun"
    (cd "$WEBUI_ROOT" && bun install --frozen-lockfile && bun run check) || exit 1
else
    log_info "Testing and building MagicNet WebUI with npm"
    (cd "$WEBUI_ROOT" && npm ci && npm run check) || exit 1
fi

if [ ! -f "${WEBUI_DIST}/index.html" ]; then
    log_error "WebUI build did not produce ${WEBUI_DIST}/index.html"
    exit 1
fi

if [ "$USE_CACHED_BUILD" -ne 1 ]; then
    DIST_DIGEST="$(webui_dist_digest)" || {
        log_error "Failed to fingerprint WebUI build output"
        exit 1
    }
    printf '%s %s\n' "$BUILD_KEY" "$DIST_DIGEST" >"${CACHE_STAMP}.new"
    mv -f "${CACHE_STAMP}.new" "$CACHE_STAMP"
fi

rm -rf "${TARGET_DIR}/assets" "${TARGET_DIR}/index.html"
mkdir -p "$TARGET_DIR"
cp -a "${WEBUI_DIST}/." "$TARGET_DIR/"
# The stamp is a build-cache implementation detail, not module content.
rm -f "${TARGET_DIR}/.magicnet-build-key"

if [ ! -f "${TARGET_DIR}/index.html" ]; then
    log_error "WebUI copy did not produce ${TARGET_DIR}/index.html"
    exit 1
fi

log_success "MagicNet WebUI installed to ${TARGET_DIR}"
