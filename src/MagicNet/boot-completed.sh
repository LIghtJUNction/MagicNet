#!/bin/sh
# shellcheck shell=ash
# Minimal boot-completed handler — keep logic minimal and trust the library

MODDIR=${0%/*}
. "$MODDIR/lib/kam-utils.sh"

# Load required modules and perform minimal flow
kam_load wait mihomo

# Wait for device unlock (non-blocking trust on library)
wait_unlock 10

# Truncate log file
: > "$MODDIR/MagicNet.log" 2>/dev/null || true

# Run subscription configuration in background to avoid blocking boot
"$MODDIR/subscribe.sh" >/dev/null 2>&1 &

# Start network and service
create_tun
mihomo_run

exit 0
