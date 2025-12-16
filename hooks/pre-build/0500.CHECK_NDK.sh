#!/bin/bash
. "$KAM_HOOKS_ROOT/lib/utils.sh"
# Optional: enable debug tracing if requested
if [ "${KAM_DEBUG:-0}" = "1" ]; then
  set -x
fi
log_info "Checking NDK version..."
if [ -z "$ANDROID_NDK_HOME" ]; then
    log_warn "ANDROID_NDK_HOME is not set"
else
    log_info "ANDROID_NDK_HOME is set to $ANDROID_NDK_HOME"
fi

ndk_version=$(cat "$ANDROID_NDK_HOME/source.properties" | grep Pkg.Revision | cut -d '=' -f 2)
log_info "NDK version: $ndk_version"
