#!/bin/bash

# shellcheck source=../lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

require_command zip "zip not found; cannot sanitize module archive"
require_command unzip "unzip not found; cannot inspect module archive"

DIST="${KAM_DIST_DIR:-${KAM_PROJECT_ROOT:-$PWD}/dist}"
MODULE_ID="${KAM_MODULE_ID:-MagicNet}"
MODULE_ZIP="${DIST}/${MODULE_ID}.zip"

if [ ! -f "$MODULE_ZIP" ]; then
    log_warn "Module archive not found, skipping sanitize: $MODULE_ZIP"
    exit 0
fi

log_info "Sanitizing module archive: $MODULE_ZIP"

# Remove repository and CI metadata that can be present because config/runtime
# folders are checked out as submodules. Do not mutate the source tree.
zip -d "$MODULE_ZIP" \
    '.git' '.git/*' \
    '*/.git' '*/.git/*' \
    '.github/*' '*/.github/*' \
    '.gitignore' '*/.gitignore' \
    >/dev/null 2>&1 || true

if ! unzip -Z1 "$MODULE_ZIP" | grep -qx 'module.prop'; then
    log_error "Invalid module archive: module.prop must be at zip root"
    exit 1
fi

if ! unzip -Z1 "$MODULE_ZIP" | grep -qx 'customize.sh'; then
    log_error "Invalid module archive: customize.sh must be at zip root"
    exit 1
fi

if unzip -Z1 "$MODULE_ZIP" | grep -Eq '(^|/)\.git($|/)|(^|/)\.github($|/)|(^|/)\.gitignore$'; then
    log_error "Invalid module archive: VCS/CI metadata still present"
    exit 1
fi

log_success "Module archive sanitized"
