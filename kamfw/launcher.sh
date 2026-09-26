# shellcheck shell=ash

# 基础跳转逻辑
_launch_url() {
	_l_target="$1"
	[ -z "$_l_target" ] && return 1
	am start -a android.intent.action.VIEW -d "$_l_target" >/dev/null 2>&1
	unset _l_target
}

_launch_app() {
	_l_pkg="$1"
	[ -z "$_l_pkg" ] && return 1
	if echo "$_l_pkg" | grep -q "/"; then
		am start -n "$_l_pkg" >/dev/null 2>&1
	else
		monkey -p "$_l_pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
	fi
	unset _l_pkg
}

# 统一入口函数
# 用法: launch url "https://github.com"
# 用法: launch app "com.android.settings"
# launch "xxx" --> launch url "xxx"
launch() {
	_launch_type="$1"
	_launch_val="$2"

	case "$_launch_type" in
	url | link)
		_launch_url "$_launch_val"
		;;
	app | pkg)
		_launch_app "$_launch_val"
		;;
	*)
		_launch_url "$_launch_type"
		;;
	esac

	unset _launch_type _launch_val
}
