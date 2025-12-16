#!/bin/bash
# 4000.XTASK.sh — optional xtask pre-build hook (template-provided)
. "$KAM_HOOKS_ROOT/lib/utils.sh"

# Optional: enable debug tracing if requested
if [ "${KAM_DEBUG:-0}" = "1" ]; then
  set -x
fi

log_warn " comment out to enable xtask!" && exit 0

cargo run -p xtask -- build --release
