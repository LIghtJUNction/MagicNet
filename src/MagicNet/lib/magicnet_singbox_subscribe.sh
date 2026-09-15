# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

. "${MODDIR}/lib/magicnet/primitives.sh"
magicnet_source_primitives
. "$(magicnet_lib_dir)/subscribe_bootstrap.sh"

_magicnet_subscribe_lib_dir="${MODDIR}/lib/magicnet/singbox_subscribe"
# The subscription updater can be invoked in isolation during first boot and
# package validation; load shared helpers before config.sh uses them. The
# normal module entrypoint may already have loaded these files, which is
# harmless because they contain deterministic function definitions.
[ -f "${MODDIR}/lib/magicnet/chain.sh" ] && . "${MODDIR}/lib/magicnet/chain.sh"
[ -f "${MODDIR}/lib/magicnet/api.sh" ] && . "${MODDIR}/lib/magicnet/api.sh"
for _magicnet_subscribe_lib in common fetch parse config proxylink update hardening; do
    . "${_magicnet_subscribe_lib_dir}/${_magicnet_subscribe_lib}.sh"
done
unset _magicnet_subscribe_lib _magicnet_subscribe_lib_dir
