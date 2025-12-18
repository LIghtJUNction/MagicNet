#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 系统等待模块 - 公开API
# =============================================================================

# 加载内部模块
_kam_utils_dir="${_KAM_UTILS_DIR:-${MODPATH}/lib/kam_utils}"
# shellcheck source=_wait.sh
if [ -f "${_kam_utils_dir}/_wait.sh" ]; then
    . "${_kam_utils_dir}/_wait.sh"
else
    echo "错误: 无法找到 _wait.sh: ${_kam_utils_dir}/_wait.sh" >&2
    return 1
fi

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
