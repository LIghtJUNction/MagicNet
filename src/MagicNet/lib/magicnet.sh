# shellcheck shell=ash
#
# MagicNet module runtime entrypoint. Feature modules live under lib/magicnet/.

export PATH="${MODDIR}/bin:${PATH}"

_magicnet_lib_dir="${MODDIR}/lib/magicnet"
. "${_magicnet_lib_dir}/primitives.sh"
for _magicnet_lib in \
    common \
    ipset_lkm \
    network \
    apps \
    dns \
    transparent_dns \
    transparent \
    webui_panel \
    singbox_route_rules \
    blocklist \
    routes \
    warp \
    chain \
    runtime_config \
    supervisors \
    core \
    action_menu \
    phases; do
    # transparent_dns.sh = IPv6/MTU/UDP policy; DNS capture remains in network.sh.
    . "${_magicnet_lib_dir}/${_magicnet_lib}.sh"
done
unset _magicnet_lib _magicnet_lib_dir
