#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 导航跳转模块 - 公开API
# =============================================================================

MODDIR=${MODDIR:-${0%/*}}
# shellcheck source=_navigation.sh
kam_source_impl navigation || { printf '%s\n' "错误: 无法加载内部实现: _navigation.sh" >&2; return 1; }

open_url() {
    _open_url_impl "$@"
}

launch_app() {
    _launch_app_impl "$@"
}
