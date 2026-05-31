#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
# Optional: enable debug tracing if requested
if [ "${KAM_DEBUG:-0}" = "1" ]; then
    set -x
fi
log_info "Checking NDK version..."
if [ -z "$ANDROID_NDK_HOME" ]; then
    log_warn "ANDROID_NDK_HOME is not set"
    exit 0
fi

log_info "ANDROID_NDK_HOME is set to $ANDROID_NDK_HOME"

if [ ! -f "$ANDROID_NDK_HOME/source.properties" ]; then
    log_warn "NDK source.properties not found; skipping NDK version check"
    exit 0
fi

ndk_version=$(grep Pkg.Revision "$ANDROID_NDK_HOME/source.properties" | cut -d '=' -f 2)
log_info "NDK version: $ndk_version"
