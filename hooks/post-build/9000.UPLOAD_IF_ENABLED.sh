#!/bin/bash

# shellcheck source=../lib/utils.sh
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
log_info "打包以下文件：$(ls $DIST)"
# Decide which repository to use for the release.
# Priority:
# 1. GITHUB_REPOSITORY (set in GitHub Actions) - preferred when present
# 2. KAM_RELEASE_REPO (explicit override)
# 3. derive from git remote of the project (KAM_PROJECT_ROOT or $PWD)
REPO=""
REPO_SOURCE=""
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    REPO="$GITHUB_REPOSITORY"
    REPO_SOURCE="GITHUB_REPOSITORY"
elif [ -n "${KAM_RELEASE_REPO:-}" ]; then
    REPO="$KAM_RELEASE_REPO"
    REPO_SOURCE="KAM_RELEASE_REPO"
else
    if command -v git >/dev/null 2>&1; then
        CHECK_DIR="${KAM_PROJECT_ROOT:-$PWD}"
        REMOTE_URL=$(git -C "$CHECK_DIR" remote get-url origin 2>/dev/null || true)
        if [ -n "$REMOTE_URL" ]; then
            # Normalize: strip trailing .git and any trailing slash
            REMOTE_URL=${REMOTE_URL%.git}
            REMOTE_URL=${REMOTE_URL%/}
            # Try to capture the last two path components (owner/repo)
            if [[ "$REMOTE_URL" =~ ([^/]+/[^/]+)$ ]]; then
                REPO="${BASH_REMATCH[1]}"
            else
                # Fallback: strip protocol/host or ssh prefix then capture last two components
                PATH_PART=$(echo "$REMOTE_URL" | sed -E 's#^[^:]+:[/]*##; s#^[^/]+://[^/]+/##')
                if [[ "$PATH_PART" =~ ([^/]+/[^/]+)$ ]]; then
                    REPO="${BASH_REMATCH[1]}"
                fi
            fi
            REPO_SOURCE="git remote (origin)"
        fi
    fi
fi

# Fail safely if repository can't be determined (avoid uploading to the wrong repo)
if [ -z "$REPO" ]; then
    log_error "Could not determine target repository for release. Set GITHUB_REPOSITORY or KAM_RELEASE_REPO."
    exit 1
fi

log_info "Using repository '$REPO' for release (source: $REPO_SOURCE)"

# Check if release already exists in target repo
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log_error "Release $TAG already exists in $REPO and is immutable, cannot proceed"
    exit 1
fi

# Create release and upload all assets in one step
PRE_FLAG=""
if [ "${KAM_PRE_RELEASE:-0}" = "1" ]; then
    PRE_FLAG="--prerelease"
fi
if [ -d "$DIST" ] && [ "$(ls -A "$DIST")" ]; then
    log_info "Creating GitHub release $TAG and uploading assets from $DIST to $REPO"
    assets=("$DIST"/*)
    gh release create "$TAG" --repo "$REPO" --title "${KAM_MODULE_ID}-${KAM_MODULE_VERSION_CODE}-${KAM_MODULE_VERSION}" --notes-file "$TMP_CHANGELOG" $PRE_FLAG "${assets[@]}" || { log_error "Failed to create release $TAG and upload assets to $REPO"; exit 1; }
else
    log_warn "Dist directory not found or empty: $DIST"
fi

log_success "Upload step finished"
exit 0

# No automatic git commit/push in this hook.
# If updating the repository is required, perform that explicitly outside this upload step.
