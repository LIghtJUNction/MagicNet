#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# 系统等待模块 - 内部函数（非公开API）
# =============================================================================

# 等待启动完成（内部实现）
_wait_boot_impl() {
    null resetprop -w sys.boot_completed 0
    [ -n "$1" ] && sleep "$1"
}

# 等待解锁（设备解锁）（内部实现）
_wait_unlock_impl() {
    _wait_boot_impl
    until [ -d /sdcard/Android ]; do sleep 1; done
    [ -n "$1" ] && sleep "$1"
}

# 等待网络连接（内部实现）
_wait_net_impl() {
    local timeout="${1:-30}" count=0
    while [ $count -lt $timeout ]; do
        ping -c 1 8.8.8.8 >/dev/null 2>&1 && return 0
        sleep 1; count=$((count+1))
    done
    return 1
}