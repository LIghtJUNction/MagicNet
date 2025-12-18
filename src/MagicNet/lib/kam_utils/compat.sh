# shellcheck shell=ash
################################################################################
#
# compat.sh - compatibility helper wrappers
#
# Public wrapper: load internal _compat.sh (fail-fast) and expose public wrappers.
#
################################################################################
MODDIR=${MODDIR:-${0%/*}}
# shellcheck source=_compat.sh
kam_source_impl compat || { echo "错误: 无法加载内部实现: _compat.sh" >&2; return 1; }

# Public wrapper delegates to internal implementation
boot2serviceif() {
    _boot2serviceif_impl "$@"
}
