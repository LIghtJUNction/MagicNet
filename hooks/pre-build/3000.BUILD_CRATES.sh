#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
# shellcheck source=hooks/lib/build_utils.sh
. "$KAM_HOOKS_ROOT/lib/build_utils.sh"

if [ ! -f "$KAM_PROJECT_ROOT/Cargo.toml" ]; then
    log_info "Cargo.toml not found; skipping Rust crate build"
    exit 0
fi

require_command cargo "cargo not found ."

BUILD_TOOL=$(detect_build_tool)
build_multi_arch "$BUILD_TOOL"
