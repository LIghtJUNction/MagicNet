#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

. "$KAM_HOOKS_ROOT/lib/utils.sh"

require_command python3 "python3 not found!"

PROJECT_ROOT="${KAM_PROJECT_ROOT:-$(cd "$KAM_HOOKS_ROOT/.." && pwd)}"
CONFIG_FILE="$KAM_MODULE_ROOT/.config/sing-box/config.json"
OPTIMIZER="$PROJECT_ROOT/scripts/optimize-sing-box-routing.py"

[ -f "$CONFIG_FILE" ] || {
    log_warn "sing-box config not found; routing optimization skipped"
    exit 0
}
[ -f "$OPTIMIZER" ] || {
    log_error "routing optimizer not found: $OPTIMIZER"
    exit 1
}

python3 "$OPTIMIZER" "$CONFIG_FILE"
log_success "sing-box routing rules optimized"
