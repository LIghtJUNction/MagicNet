#!/bin/bash

. "$KAM_HOOKS_ROOT/lib/utils.sh"

# Sign artifacts in $KAM_DIST_DIR if KAM_SIGN_ENABLED=1
if [ "$KAM_SIGN_ENABLED" != "1" ]; then
	log_info "KAM_SIGN_ENABLED != 1, skipping signing"
	exit 0
fi


log_info "Signing artifacts in $KAM_DIST_DIR (kam sign -s)..."

# Attempt to sign, but allow failure as requested ("失败也没关系")
if kam sign --dist "$KAM_DIST_DIR"; then
    log_success "Signing completed successfully."

else
    log_warn "Signing failed. Continuing build process as failure is allowed."
    # We exit 0 to ensure the build pipeline doesn't stop
    exit 0
fi
