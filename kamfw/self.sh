# shellcheck shell=ash

config() {
	_cmd="$1"
	[ -z "$_cmd" ] || shift

	# 1. KernelSU Delegate
	if is_ksu; then
		# 非关键路径：ksud 可在不同位置；此处回退为固定路径，不允许用 `|| echo` 输出旁路。
		_ksud=$(command -v ksud 2>/dev/null)
		[ -n "${_ksud:-}" ] || _ksud="/data/adb/ksud"
		if [ -x "$_ksud" ]; then
			[ -n "${KSU_MODULE:-}" ] || [ ! -f "${MODDIR:-}/module.prop" ] || export KSU_MODULE=$(sed -n 's/^id=//p' "$MODDIR/module.prop")
			"$_ksud" module config "$_cmd" "$@"
			return $?
		fi
	fi

	# 2. Help
	if [ "$_cmd" = "help" ] || [ -z "$_cmd" ]; then
		printf "Usage: config [get|set|list|delete|clear] [--temp] [--stdin] <key> [value]\n"
		return 0
	fi

	# 3. Path & Module ID Setup
	_mod_id="${KSU_MODULE:-${MODDIR##*/}}"
	[ -n "$_mod_id" ] || {
		error "Module ID unknown"
		return 1
	}

	_home="${KAM_HOME:-${MODDIR:-${MODPATH:-/tmp}}}"
	_base="${KAM_CONFIG_DIR:-$_home/.state/kamfw-config/$_mod_id}"
	_p_dir="$_base/persist"
	_t_dir="$_base/tmp"
	mkdir -p "$_p_dir" "$_t_dir" || return 1
	chmod 0700 "$_base" "$_p_dir" "$_t_dir" 2>/dev/null || true

	# 4. Command Logic
	case "$_cmd" in
	get)
		_key="$1"
		[ -f "$_t_dir/$_key" ] && cat "$_t_dir/$_key" && return 0
		[ -f "$_p_dir/$_key" ] && cat "$_p_dir/$_key" && return 0
		return 1
		;;
	set)
		_dir="$_p_dir"
		while [ $# -gt 0 ]; do
			case "$1" in
			--temp)
				_dir="$_t_dir"
				shift
				;;
			--stdin)
				_stdin=1
				shift
				;;
			*) break ;;
			esac
		done
		_key="$1"
		shift
		[ -n "$_key" ] || return 1
		if [ "${_stdin:-0}" = "1" ]; then cat >"$_dir/$_key"; else printf '%s' "$*" >"$_dir/$_key"; fi
		;;
	list)
		{
			ls -1 "$_p_dir"
			ls -1 "$_t_dir"
		} 2>/dev/null | sort -u
		;;
	delete)
		_dir="$_p_dir"
		[ "$1" = "--temp" ] && {
			_dir="$_t_dir"
			shift
		}
		rm -f "$_dir/$1"
		;;
	clear)
		_dir="$_p_dir"
		[ "$1" = "--temp" ] && {
			_dir="$_t_dir"
			shift
		}
		rm -rf "$_dir" && mkdir -m 0700 -p "$_dir"
		;;
	*) return 1 ;;
	esac
}

# 禁用模块
disable() {
	[ -z "$MODDIR" ] && return 1
	if touch "$MODDIR/disable"; then
		print "* 模块已禁用 (重启后生效)"
	else
		print "! 禁用操作失败：权限不足或目录不存在"
		return 1
	fi
}

# 启用模块
enable() {
	[ -z "$MODDIR" ] && return 1
	if rm -f "$MODDIR/disable"; then
		print "* 模块已启用 (重启后生效)"
	else
		print "! 启用操作失败"
		return 1
	fi
}
