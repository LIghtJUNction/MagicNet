# shellcheck shell=ash
# 等待系统开机完成
# 用法: wait_boot [延迟秒数]
wait_boot() {
	_wb_timeout=120 # 2分钟超时
	_wb_count=0

	while [ $_wb_count -lt $_wb_timeout ] && [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
		sleep 1
		_wb_count=$((_wb_count + 1))
	done

	# 如果超时仍未完成，记录警告但继续执行
	if [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; then
		log "WARN: Boot completion timeout after ${_wb_timeout}s, proceeding anyway"
	fi

	# 可选的额外缓冲时间
	[ -n "$1" ] && sleep "$1"

	unset _wb_timeout _wb_count
}

wait_boot_if_magisk() {
	if is_magisk; then
		wait_boot "$@"
	fi
}

# 等待用户解锁 / SDCard 挂载
# 用法: wait_unlock [延迟秒数]
wait_unlock() {
	# 必须先确保开机完成
	wait_boot

	_wu_timeout=300 # 5分钟超时
	_wu_count=0

	# 检测 /sdcard 目录是否可用
	while [ $_wu_count -lt $_wu_timeout ]; do
		if [ -d "/sdcard" ]; then
			break
		fi

		sleep 1
		_wu_count=$((_wu_count + 1))
	done

	# 如果超时仍未解锁，记录警告但继续执行
	if [ $_wu_count -ge $_wu_timeout ]; then
		log "WARN: Device unlock timeout after ${_wu_timeout}s, proceeding anyway"
	fi

	[ -n "$1" ] && sleep "$1"

	unset _wu_timeout _wu_count
}

# 等待网络连接可用
# 用法: wait_net [超时秒数]
wait_net() {
	_wn_timeout="${1:-30}"
	_wn_count=0

	while [ $_wn_count -lt $_wn_timeout ]; do
		if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
			unset _wn_timeout _wn_count
			return 0
		fi

		_wn_count=$((_wn_count + 1))
		sleep 1
	done

	unset _wn_timeout _wn_count
	return 1 # 超时
}
