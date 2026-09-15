# shellcheck shell=ash
# Compatibility shim. The implementation lives with the subscription pipeline.
# primitives.sh must be loaded first so host tests and the installed module use
# the same library-root resolution instead of assuming MODDIR is the source tree.
# shellcheck disable=SC1090
. "$(magicnet_lib_dir)/singbox_subscribe/bootstrap.sh"
