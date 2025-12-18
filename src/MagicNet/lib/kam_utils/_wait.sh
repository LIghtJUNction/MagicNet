# shellcheck shell=ash
# =============================================================================
# 系统等待模块 - 内部函数（非公开API）
# =============================================================================

# 等待启动完成（内部实现）
_wait_boot_impl() {
    # 可选第1个参数：完成启动后额外睡眠秒数
    # 可选第2个参数：等待超时时间（秒），0 表示无限等待（默认 300 秒）
    _wait_boot_impl_sleep="${1:-}"
    _wait_boot_impl_timeout="${2:-300}"
    _wait_boot_impl_count=0

    # 轮询 sys.boot_completed，直到变为 '1'（系统启动完成）或超时
    while [ "$(getprop sys.boot_completed 2>/dev/null || true)" != "1" ]; do
        sleep 1
        _wait_boot_impl_count=$((_wait_boot_impl_count + 1))
        if [ "$_wait_boot_impl_timeout" -gt 0 ] && [ "$_wait_boot_impl_count" -ge "$_wait_boot_impl_timeout" ]; then
            return 1
        fi
    done

    [ -n "$_wait_boot_impl_sleep" ] && sleep "$_wait_boot_impl_sleep"
    return 0
}

# 等待解锁（设备解锁）（内部实现）
_wait_unlock_impl() {
    _wait_unlock_impl_sleep="${1:-}"
    _wait_boot_impl "$_wait_unlock_impl_sleep"
    until [ -d /sdcard/Android ]; do sleep 1; done
    [ -n "$_wait_unlock_impl_sleep" ] && sleep "$_wait_unlock_impl_sleep"
}

# 等待网络连接（内部实现）
_wait_net_impl() {
	_wait_net_impl_timeout="${1:-30}"
	_wait_net_impl_count=0
	while [ "$_wait_net_impl_count" -lt "$_wait_net_impl_timeout" ]; do
		ping -c 1 8.8.8.8 >/dev/null 2>&1 && return 0
		sleep 1
		_wait_net_impl_count=$((_wait_net_impl_count+1))
	done
	return 1
}
