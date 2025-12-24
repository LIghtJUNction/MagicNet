#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
# shellcheck source=hooks/lib/build_utils.sh
. "$KAM_HOOKS_ROOT/lib/build_utils.sh"

log_warn " comment out to enable build crates!" && exit 0

require_command cargo "cargo not found ."
