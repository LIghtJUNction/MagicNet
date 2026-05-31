#!/bin/bash
# 4000.XTASK.sh — optional xtask pre-build hook (template-provided)
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

# Optional: enable debug tracing if requested
if [ "${KAM_DEBUG:-0}" = "1" ]; then
    set -x
fi

if [ ! -f "$KAM_PROJECT_ROOT/Cargo.toml" ]; then
    log_info "Cargo.toml not found; skipping xtask"
    exit 0
fi

if ! grep -q 'name[[:space:]]*=[[:space:]]*"xtask"' "$KAM_PROJECT_ROOT/Cargo.toml" 2>/dev/null; then
    log_info "xtask package not configured; skipping xtask"
    exit 0
fi

cargo run -p xtask -- build --release
