#!/bin/sh
# shellcheck shell=ash
# Minimal boot-completed handler — keep logic minimal and trust the library

# Determine module root robustly (prefer MODPATH set by installers).
MODDIR=${MODPATH:-${MODDIR:-${0%/*}}}
if [ ! -f "${MODDIR}/lib/kam-utils.sh" ]; then
    cur="$PWD"
    while [ -n "$cur" ] && [ "$cur" != "/" ]; do
        if [ -f "$cur/lib/kam-utils.sh" ]; then
            MODDIR="$cur"
            break
        fi
        cur=$(dirname -- "$cur")
    done
fi
[ -z "${MODDIR:-}" ] && MODDIR="$PWD"
[ -f "${MODDIR}/lib/kam-utils.sh" ] && . "$MODDIR/lib/kam-utils.sh" || { printf '%s\n' '! File "kam-utils.sh" does not exist!' >&2; exit 1; }

# Load required modules and perform minimal flow
kam_load wait mihomo

# Wait for device unlock (non-blocking trust on library)
wait_unlock 10

# Truncate log file
: > "$MODDIR/MagicNet.log" 2>/dev/null || true

"$MODDIR/subscribe.sh" > "$MODDIR/MagicNet.log" 2>&1

# Start network and service
create_tun
mihomo_run

exit 0
