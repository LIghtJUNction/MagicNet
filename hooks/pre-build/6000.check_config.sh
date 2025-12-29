#!/bin/bash

. "$KAM_HOOKS_ROOT/lib/utils.sh"

export HOME=$KAM_MODULE_ROOT

is_ci && exit 0

is_termux && exit 0

require_command mihomo "arch: paru -S mihomo"

mihomo -t $HOME/.config/mihomo/config.yaml
