# shellcheck shell=ash
#
# MagicNet module runtime entrypoint. Feature modules live under lib/magicnet/.

import wait
import rich

export PATH="${MODDIR}/bin:${PATH}"

_magicnet_lib_dir="${MODDIR}/lib/magicnet"
for _magicnet_lib in \
    common \
    ipset_lkm \
    network \
    apps \
    tproxy \
    transparent \
    webui_panel \
    blocklist \
    capture_common \
    capture_mihomo \
    capture_singbox \
    routes \
    runtime_config \
    supervisors \
    core \
    action_menu \
    phases; do
    . "${_magicnet_lib_dir}/${_magicnet_lib}.sh"
done
unset _magicnet_lib _magicnet_lib_dir
