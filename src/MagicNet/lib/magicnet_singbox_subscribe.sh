# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

_magicnet_subscribe_lib_dir="${MODDIR}/lib/magicnet/singbox_subscribe"
for _magicnet_subscribe_lib in common fetch parse config chain proxylink update; do
    . "${_magicnet_subscribe_lib_dir}/${_magicnet_subscribe_lib}.sh"
done
unset _magicnet_subscribe_lib _magicnet_subscribe_lib_dir
