# shellcheck shell=ash
# Compatibility shim. The implementation lives with the subscription pipeline.
_magicnet_lib_root="$(if type magicnet_lib_dir >/dev/null 2>&1; then magicnet_lib_dir; else printf '%s\n' "${MODDIR}/lib/magicnet"; fi)"
# shellcheck disable=SC1090
. "${_magicnet_lib_root}/singbox_subscribe/bootstrap.sh"
unset _magicnet_lib_root
