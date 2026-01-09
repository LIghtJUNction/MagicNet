#!/bin/bash

. "$KAM_HOOKS_ROOT/lib/utils.sh"

export HOME=$KAM_MODULE_ROOT

is_ci && exit 0

is_termux && exit 0

MAGIC_MIHOMO=${MAGIC_MIHOMO:-1}
MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}

if [ "$MAGIC_MIHOMO" -ne 0 ] && [ -f "$HOME/.config/mihomo/config.yaml" ]; then
    require_command mihomo "arch: paru -S mihomo"
    log_info "Checking mihomo config..."
    mihomo -t -f "$HOME/.config/mihomo/config.yaml" -d "$HOME/.config/mihomo" || exit 1
fi

if [ "$MAGIC_SINGBOX" -ne 0 ] && [ -f "$HOME/.config/sing-box/config.json" ]; then
    require_command sing-box "arch: paru -S sing-box"
    log_info "Checking sing-box config..."
    sing-box check -c "$HOME/.config/sing-box/config.json" -D "$HOME/.config/sing-box" || exit 1
fi
