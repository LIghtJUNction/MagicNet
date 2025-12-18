#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 系统等待模块 - 公开API
# =============================================================================

# 加载内部模块（严格模式：缺少内部实现即 fail-fast）
MODDIR=${0%/*}
# shellcheck source=_wait.sh
kam_source_impl wait || { printf '%s\n' "错误: 无法加载内部实现: _wait.sh" >&2; return 1; }

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
