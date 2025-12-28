#!/bin/bash

. "$KAM_HOOKS_ROOT/lib/utils.sh"


export HOME=$KAM_MODULE_ROOT

if is_ci; then
  exit 0
fi

require_command mihomo "arch: paru -S mihomo"

mihomo
