#!/bin/bash
. "$KAM_HOOKS_ROOT/lib/utils.sh"

log_warn " comment out to enable build webui !" && exit 0

WEBUI_SRC_DIR="$KAM_PROJECT_ROOT/WEBUI"
WEBUI_DIST_DIR="$WEBUI_SRC_DIR/dist"

# KAM_WEB_ROOT

# BUILD


# MOVE WEBUI_DIST_DIR TO KAM_DIST_DIR
# ...
log_success "WEBUI build completed."
