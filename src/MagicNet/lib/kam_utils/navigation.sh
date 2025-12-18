#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 导航跳转模块 - 公开API
# =============================================================================

_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
# shellcheck source=_navigation.sh
if [ -f "${_kam_utils_dir}/_navigation.sh" ]; then
    . "${_kam_utils_dir}/_navigation.sh"
else
    echo "错误: 无法找到 _navigation.sh: ${_kam_utils_dir}/_navigation.sh" >&2
    return 1
fi

open_url() {
    _open_url_impl "$@"
}

launch_app() {
    _launch_app_impl "$@"
}
