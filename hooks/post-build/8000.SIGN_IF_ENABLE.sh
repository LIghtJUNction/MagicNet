#!/bin/bash

# shellcheck source=../lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

# Sign artifacts in $KAM_DIST_DIR if KAM_SIGN_ENABLED=1
if [ "$KAM_SIGN_ENABLED" != "1" ]; then
    log_info "KAM_SIGN_ENABLED != 1, skipping signing"
    exit 0
fi

log_info "Signing artifacts in $KAM_DIST_DIR (kam sign --dist)..."

if kam sign --dist "$KAM_DIST_DIR"; then
    log_success "Signing completed successfully."

else
    if [ "${KAM_SIGN_REQUIRED:-0}" = "1" ]; then
        log_error "Signing failed, and KAM_SIGN_REQUIRED=1."
        exit 1
    fi

    log_warn "Signing failed. Continuing build process because KAM_SIGN_REQUIRED!=1."
    exit 0
fi

if [ "${KAM_SIGN_REQUIRED:-0}" = "1" ]; then
    missing_sig=0
    for artifact in "$KAM_DIST_DIR"/*.zip; do
        [ -e "$artifact" ] || continue
        if [ ! -f "${artifact}.sig" ]; then
            log_error "Missing signature asset: ${artifact}.sig"
            missing_sig=1
        fi
    done
    if [ "$missing_sig" = "1" ]; then
        exit 1
    fi
fi
