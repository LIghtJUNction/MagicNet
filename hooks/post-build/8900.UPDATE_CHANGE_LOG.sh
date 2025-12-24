#!/bin/bash

# shellcheck source=../lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

# optionally update changelog using commitizen.
require_command cz "commitizen not found; cannot update changelog." || exit 0

cz ch || log_error "cannot update changelog."
