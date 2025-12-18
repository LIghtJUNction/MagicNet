#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 网络工具模块 - 公开API（薄包装）
# =============================================================================
#
# NOTE: This file is intentionally a thin wrapper. All implementations live
# in the internal file `_network.sh`. If the internal implementation is absent,
# this wrapper will fail fast (return non-zero).
#

_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
# shellcheck source=_network.sh
kam_source_impl network || { printf '%s\n' "错误: 无法加载内部实现: ${_kam_utils_dir}/_network.sh" >&2; return 1; }

# Public wrappers (thin)
check_network()   { _check_network_impl "$@"; }
get_local_ip()    { _get_local_ip_impl "$@"; }
download_file()   { _download_file_impl "$@"; }
