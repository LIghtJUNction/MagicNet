# shellcheck shell=ash
#
# MagicNet module runtime entrypoint. Feature modules live under lib/magicnet/.

export PATH="${MODDIR}/bin:${PATH}"

# Root managers run boot hooks in BusyBox ash standalone mode, where the ip
# applet wins over PATH and cannot handle all Android iproute2 operations.
# Shell functions take precedence over applets. Bind only ip, without disabling
# standalone mode for the other tools or changing host-side PATH/test doubles.
if [ -x /system/bin/ip ]; then
    ip() { /system/bin/ip "$@"; }
fi

_magicnet_lib_dir="${MODDIR}/lib/magicnet"
. "${_magicnet_lib_dir}/primitives.sh"
for _magicnet_lib in \
    i18n \
    common \
    api \
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
    singbox_lifecycle \
    core \
    lifecycle \
    action_menu \
    phases; do
    # transparent_dns.sh = IPv6/MTU/UDP policy; DNS capture remains in network.sh.
    . "${_magicnet_lib_dir}/${_magicnet_lib}.sh"
done
unset _magicnet_lib _magicnet_lib_dir
