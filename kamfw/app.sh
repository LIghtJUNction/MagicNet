# shellcheck shell=ash

_pm_path_safe() {
	# 如果 pm path 返回 package:/data/app/.../base.apk，截取路径部分
	pm path "$1" 2>/dev/null | head -n 1 | sed 's/^package://;s/base.apk$//'
}

is_app_installed() {
	_i_pkg="$1"
	[ -z "$_i_pkg" ] && return 1

	# 尝试通过 pm path 获取 APK 目录
	_i_apkDir=$(_pm_path_safe "$_i_pkg")
	if [ -n "$_i_apkDir" ] && [ -d "$_i_apkDir" ]; then
		return 0
	fi
	return 1
}

require_app() {
	_r_pkg="$1"
	_r_msg="$2"

	if is_app_installed "$_r_pkg"; then
		return 0
	fi

	error "!"
	error "! $_r_msg"
	error "!"

	return 1
}
