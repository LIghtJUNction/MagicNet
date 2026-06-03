#!/bin/bash

# shellcheck source=../lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

# Sign artifacts in $KAM_DIST_DIR if signing is enabled.
# KAM owns the KAM_* namespace during hook execution, so CI passes MAGICNET_*.
sign_enabled="${MAGICNET_SIGN_ENABLED:-${KAM_SIGN_ENABLED:-0}}"
sign_required="${MAGICNET_SIGN_REQUIRED:-${KAM_SIGN_REQUIRED:-0}}"

if [ "$sign_enabled" != "1" ]; then
    log_info "Signing disabled, skipping signing"
    exit 0
fi

log_info "Signing artifacts in $KAM_DIST_DIR (kam sign --dist)..."

sign_status=0
kam sign --dist "$KAM_DIST_DIR" || sign_status=$?

missing_sig=0
for artifact in "$KAM_DIST_DIR"/*.zip; do
    [ -e "$artifact" ] || continue
    if [ ! -f "${artifact}.sig" ]; then
        log_warn "Missing signature asset: ${artifact}.sig"
        missing_sig=1
    fi
done

if [ "$sign_status" != "0" ] || [ "$missing_sig" = "1" ]; then
    if [ "$sign_required" = "1" ]; then
        log_error "Signing failed, and signing is required."
        exit 1
    fi

    log_warn "Signing failed. Continuing build process because signing is not required."
    exit 0
fi

log_success "Signing completed successfully."
