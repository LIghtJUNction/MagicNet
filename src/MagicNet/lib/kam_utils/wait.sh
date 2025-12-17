#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 系统等待模块 - 公开API
# =============================================================================

# 加载内部模块
_kam_utils_dir="$(dirname "${0}")"
[ -f "${_kam_utils_dir}/_wait.sh" ] && . "${_kam_utils_dir}/_wait.sh"

# 等待启动完成
wait_boot() {
    _wait_boot_impl "$@"
}

# 等待解锁（设备解锁）
wait_unlock() {
    _wait_unlock_impl "$@"
}

# 等待网络连接
wait_net() {
    _wait_net_impl "$@"
}