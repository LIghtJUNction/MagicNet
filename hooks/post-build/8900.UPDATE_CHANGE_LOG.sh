#!/bin/bash

# shellcheck source=../lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

is_termux && exit 0

if [ "${KAM_CHANGELOG_ENABLED:-0}" != "1" ]; then
    log_info "KAM_CHANGELOG_ENABLED != 1, skipping changelog update"
    exit 0
fi

# optionally update changelog using commitizen.
require_command cz "commitizen not found; cannot update changelog." || exit 0

cz ch || log_error "cannot update changelog."
