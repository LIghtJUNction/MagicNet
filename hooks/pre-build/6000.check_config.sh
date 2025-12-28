#!/bin/bash

. "$KAM_HOOKS_ROOT/lib/utils.sh"

export HOME=$KAM_MODULE_ROOT

if is_ci; then
    URL=$(curl -s api.github.com | grep "browser_download_url.*linux-amd64-v1.*gz" | cut -d '"' -f 4 | head -n 1)
    curl -L -o mihomo.gz "$URL"
    gunzip mihomo.gz
    chmod +x mihomo
    sudo mv mihomo /usr/local/bin/mihomo
fi

require_command mihomo "arch: paru -S mihomo"

mihomo -t $HOME/.config/mihomo/config.yaml
