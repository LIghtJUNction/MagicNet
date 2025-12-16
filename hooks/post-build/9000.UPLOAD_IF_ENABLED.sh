#!/bin/bash

. "$KAM_HOOKS_ROOT/lib/utils.sh"

# If release disabled, skip
if [ "${KAM_RELEASE_ENABLED:-0}" != "1" ]; then
    log_warn "KAM_RELEASE_ENABLED != 1, skipping upload"
    exit 0
fi

# Ensure `gh` (GitHub CLI) is present
require_command gh

# Choose tag to use for release
TAG=${KAM_RELEASE_TAG:-$KAM_MODULE_VERSION}

# Determine dist dir
DIST="${KAM_DIST_DIR:-${KAM_PROJECT_ROOT:-$PWD}/dist}"

# Build a simple release notes file (temporary)
TMP_CHANGELOG=$(mktemp)
cleanup_tmp() {
    if [ -n "$TMP_CHANGELOG" ] && [ -f "$TMP_CHANGELOG" ]; then
        rm -f "$TMP_CHANGELOG"
        TMP_CHANGELOG=""
    fi
}
trap cleanup_tmp EXIT

# Try to pick a short changelog for this version
CHANGELOG_SECTION=""
if [ -f "$KAM_PROJECT_ROOT/CHANGELOG.md" ]; then
    CHANGELOG_SECTION=$(awk -v ver="${KAM_MODULE_VERSION}" 'BEGIN{found=0} $0 ~ ver {found=1; next} found && /^#+[ ]/ {exit} found{print}' "$KAM_PROJECT_ROOT/CHANGELOG.md" || true)
fi
if [ -z "$CHANGELOG_SECTION" ] && command -v git >/dev/null 2>&1; then
    PREV_TAG=$(git tag --sort=-creatordate | grep -v "^${KAM_MODULE_VERSION}$" | sed -n '1p' 2>/dev/null || true)
    if [ -n "$PREV_TAG" ]; then
        CHANGELOG_SECTION=$(git log --pretty=format:'- %s' "${PREV_TAG}"..HEAD 2>/dev/null || true)
    else
        CHANGELOG_SECTION=$(git log --pretty=format:'- %s' -n 20 2>/dev/null || true)
    fi
fi
if [ -z "$CHANGELOG_SECTION" ]; then
    CHANGELOG_SECTION="- See CHANGELOG.md"
fi

RELEASE_NOTES=$(cat <<EOF
${KAM_MODULE_NAME:-$KAM_MODULE_ID} v${KAM_MODULE_VERSION:-unknown}

Module: ${KAM_MODULE_ID}
Version: ${KAM_MODULE_VERSION}
Author: ${KAM_MODULE_AUTHOR:-unknown}

Changelog:
${CHANGELOG_SECTION}

Built with [Kam](https://github.com/MemDeco-WG/Kam)
EOF
)
printf "%s\n" "$RELEASE_NOTES" > "$TMP_CHANGELOG"

# Check if release already exists
if gh release view "$TAG" >/dev/null 2>&1; then
    log_error "Release $TAG already exists and is immutable, cannot proceed"
    exit 1
fi

# Create release and upload all assets in one step
PRE_FLAG=""
if [ "${KAM_PRE_RELEASE:-0}" = "1" ]; then
    PRE_FLAG="--prerelease"
fi
if [ -d "$DIST" ] && [ "$(ls -A "$DIST")" ]; then
    log_info "Creating GitHub release $TAG and uploading assets from $DIST"
    gh release create "$TAG" --title "${KAM_MODULE_ID}-${KAM_MODULE_VERSION_CODE}-${KAM_MODULE_VERSION}" --notes-file "$TMP_CHANGELOG" $PRE_FLAG "$DIST"/* || { log_error "Failed to create release $TAG and upload assets"; exit 1; }
else
    log_warn "Dist directory not found or empty: $DIST"
fi

log_success "Upload step finished"
exit 0