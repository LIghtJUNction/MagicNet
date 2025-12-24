#!/bin/bash

# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

log_warn " comment out to enable !" && exit 0

rm -r "$KAM_DIST_DIR" || log_error "failed to clean up."

log_success "Cleaned up $KAM_DIST_DIR"
