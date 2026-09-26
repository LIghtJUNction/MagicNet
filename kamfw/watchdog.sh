# shellcheck shell=ash
#
# kamfw watchdog helper
#
# Explicit API only. Importing this file must not start background work.

set_i18n "WATCHDOG_NAME_REQUIRED" \
	"zh" "watchdog: 名称不能为空" \
	"en" "watchdog: name is required" \
	"ja" "watchdog: 名前が必要です" \
	"ko" "watchdog: 이름이 필요합니다"

set_i18n "WATCHDOG_COMMAND_REQUIRED" \
	"zh" "watchdog: 命令不能为空" \
	"en" "watchdog: command is required" \
	"ja" "watchdog: コマンドが必要です" \
	"ko" "watchdog: 명령이 필요합니다"

set_i18n "WATCHDOG_INTERVAL_INVALID" \
	"zh" "watchdog: 间隔必须是正整数秒" \
	"en" "watchdog: interval must be a positive number of seconds" \
	"ja" "watchdog: 間隔は正の秒数である必要があります" \
	"ko" "watchdog: 간격은 양의 초 단위여야 합니다"

set_i18n "WATCHDOG_STARTED" \
	"zh" "watchdog 已启动: \$_1 (pid=\$_2)" \
	"en" "watchdog started: \$_1 (pid=\$_2)" \
	"ja" "watchdog を開始しました: \$_1 (pid=\$_2)" \
	"ko" "watchdog 시작됨: \$_1 (pid=\$_2)"

set_i18n "WATCHDOG_STOPPED" \
	"zh" "watchdog 已停止: \$_1" \
	"en" "watchdog stopped: \$_1" \
	"ja" "watchdog を停止しました: \$_1" \
	"ko" "watchdog 중지됨: \$_1"

set_i18n "WATCHDOG_NOT_RUNNING" \
	"zh" "watchdog 未运行: \$_1" \
	"en" "watchdog is not running: \$_1" \
	"ja" "watchdog は実行されていません: \$_1" \
	"ko" "watchdog 실행 중 아님: \$_1"

set_i18n "WATCHDOG_COMMAND_FAILED" \
	"zh" "watchdog \$_1: 命令失败" \
	"en" "watchdog \$_1: command failed" \
	"ja" "watchdog \$_1: コマンドが失敗しました" \
	"ko" "watchdog \$_1: 명령 실패"

watchdog_state_dir() {
	: "${KAM_HOME:=${MODDIR:-${0%/*}}}"
	_wd_dir="${KAM_WATCHDOG_STATE_DIR:-$KAM_HOME/.state/watchdog}"
	mkdir -p "$_wd_dir" 2>/dev/null || return 1
	print "$_wd_dir"
	unset _wd_dir
}

watchdog_pid_file() {
	_wd_name="$1"
	[ -z "$_wd_name" ] && return 1
	_wd_dir="$(watchdog_state_dir)" || return 1
	print "$_wd_dir/$_wd_name.pid"
	unset _wd_name _wd_dir
}

watchdog_shell_quote() {
	printf "'"
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
	printf "'"
}

watchdog_valid_interval() {
	case "$1" in
	"" | *[!0-9]* | 0) return 1 ;;
	*) return 0 ;;
	esac
}

watchdog_is_pid_alive() {
	_wd_pid="$1"
	[ -n "$_wd_pid" ] || return 1
	if kill -0 "$_wd_pid" 2>/dev/null; then return 0; fi
	[ -d "/proc/$_wd_pid" ] && return 2
	return 1
}

watchdog_proc_cmdline_lines() (
	_wd_pid="$1"
	if type magicnet_proc_cmdline_lines >/dev/null 2>&1; then
		magicnet_proc_cmdline_lines "$_wd_pid" /proc
		return $?
	fi
	_wd_reader="${MODDIR:-${KAM_HOME:-}}/cli"
	[ -x "$_wd_reader" ] || return 2
	"$_wd_reader" __proc-cmdline /proc "$_wd_pid"
)

watchdog_pid_matches_script() (
	_wd_pid="$1"
	_wd_script="$2"
	if watchdog_is_pid_alive "$_wd_pid"; then _wd_rc=0; else _wd_rc=$?; fi
	[ "$_wd_rc" -eq 0 ] || return "$_wd_rc"
	if _wd_argv=$(watchdog_proc_cmdline_lines "$_wd_pid"); then _wd_rc=0; else _wd_rc=$?; fi
	[ "$_wd_rc" -eq 0 ] || return "$_wd_rc"
	awk -v expected="$_wd_script" '
		function shell(value) { return value ~ /(^|\/)(sh|ash|dash|bash|ksh|mksh)$/ }
		{ argv[++count]=$0 }
		END { exit (count == 2 && shell(argv[1]) && argv[2] == expected) ? 0 : 1 }
	' <<EOF
$_wd_argv
EOF
)

watchdog_script_pids() (
	_wd_script="$1"
	if _wd_ps=$(ps -A -o pid=,args= 2>/dev/null); then _wd_rc=0; else _wd_rc=$?; fi
	[ "$_wd_rc" -eq 0 ] || return 2
	_wd_candidates=$(printf '%s\n' "$_wd_ps" | awk -v expected="$_wd_script" 'index($0, expected) { print $1 }')
	_wd_pids=''
	_wd_count=0
	for _wd_pid in $_wd_candidates; do
		_wd_count=$((_wd_count + 1))
		[ "$_wd_count" -le 256 ] || return 2
		if watchdog_pid_matches_script "$_wd_pid" "$_wd_script"; then
			_wd_pids="${_wd_pids}${_wd_pids:+
}${_wd_pid}"
		else
			_wd_rc=$?
			[ "$_wd_rc" -ne 2 ] || return 2
		fi
	done
	[ -n "$_wd_pids" ] || return 1
	printf '%s\n' "$_wd_pids"
)

watchdog_status() {
	_wd_name="$1"
	[ -z "$_wd_name" ] && {
		error "$(i18n WATCHDOG_NAME_REQUIRED)"
		return 2
	}

	_wd_pid_file="$(watchdog_pid_file "$_wd_name")" || return 1
	_wd_script_file="${_wd_pid_file%.pid}.loop.sh"
	if [ -f "$_wd_pid_file" ]; then
		_wd_pid="$(sed -n '1p' "$_wd_pid_file" 2>/dev/null)"
		if watchdog_pid_matches_script "$_wd_pid" "$_wd_script_file"; then
			print "$_wd_pid"
			return 0
		else
			_wd_rc=$?
		fi
		[ "$_wd_rc" -ne 2 ] || return 2
	fi

	unset _wd_name _wd_pid_file _wd_pid
	return 1
}

watchdog_stop() {
	_wd_name="$1"
	[ -z "$_wd_name" ] && {
		error "$(i18n WATCHDOG_NAME_REQUIRED)"
		return 2
	}

	_wd_pid_file="$(watchdog_pid_file "$_wd_name")" || return 1
	_wd_script_file="${_wd_pid_file%.pid}.loop.sh"
	if _wd_pids=$(watchdog_script_pids "$_wd_script_file"); then _wd_rc=0; else _wd_rc=$?; fi
	[ "$_wd_rc" -ne 2 ] || return 2
	if [ "$_wd_rc" -eq 0 ]; then
		for _wd_pid in $_wd_pids; do
			watchdog_pid_matches_script "$_wd_pid" "$_wd_script_file" || return $?
			kill "$_wd_pid" 2>/dev/null || true
		done
		sleep 1
		if watchdog_script_pids "$_wd_script_file" >/dev/null 2>&1; then
			return 1
		else
			_wd_rc=$?
		fi
		[ "$_wd_rc" -ne 2 ] || return 2
		rm -f "$_wd_pid_file" || return 1
		success "$(i18n WATCHDOG_STOPPED | t "$_wd_name")"
		return 0
	fi
	[ ! -f "$_wd_pid_file" ] || rm -f "$_wd_pid_file" || return 1

	warn "$(i18n WATCHDOG_NOT_RUNNING | t "$_wd_name")"
	unset _wd_name _wd_pid_file _wd_pid
	return 1
}

watchdog_once() {
	_wd_cmd="$*"
	[ -z "$_wd_cmd" ] && {
		error "$(i18n WATCHDOG_COMMAND_REQUIRED)"
		return 2
	}
	sh -c "$_wd_cmd"
	_wd_rc=$?
	unset _wd_cmd
	return "$_wd_rc"
}

watchdog_start() {
	_wd_notify="${KAM_WATCHDOG_NOTIFY:-0}"
	while [ $# -gt 0 ]; do
		case "$1" in
		--notify | --alert)
			_wd_notify=1
			shift
			;;
		--no-notify | --quiet)
			_wd_notify=0
			shift
			;;
		*) break ;;
		esac
	done

	_wd_name="$1"
	_wd_interval="$2"
	shift 2 2>/dev/null || true
	_wd_cmd="$*"

	[ -z "$_wd_name" ] && {
		error "$(i18n WATCHDOG_NAME_REQUIRED)"
		return 2
	}
	[ -z "$_wd_cmd" ] && {
		error "$(i18n WATCHDOG_COMMAND_REQUIRED)"
		unset _wd_name _wd_interval _wd_cmd
		return 2
	}
	if ! watchdog_valid_interval "$_wd_interval"; then
		error "$(i18n WATCHDOG_INTERVAL_INVALID)"
		unset _wd_name _wd_interval _wd_cmd
		return 2
	fi

	_wd_start_name="$_wd_name"
	_wd_start_interval="$_wd_interval"
	_wd_start_cmd="$_wd_cmd"
	_wd_start_notify="$_wd_notify"

	if _wd_existing_pid="$(watchdog_status "$_wd_start_name" 2>/dev/null)"; then
		if watchdog_stop "$_wd_start_name" >/dev/null 2>&1; then _wd_existing_rc=0; else _wd_existing_rc=$?; fi
		[ "$_wd_existing_rc" -eq 0 ] || return "$_wd_existing_rc"
	else
		_wd_existing_rc=$?
		[ "$_wd_existing_rc" -ne 2 ] || return 2
	fi

	_wd_pid_file="$(watchdog_pid_file "$_wd_start_name")" || return 1
	_wd_log_file="${KAM_WATCHDOG_LOG_FILE:-${KAM_HOME:-$MODDIR}/.log/watchdog.log}"
	_wd_script_file="${_wd_pid_file%.pid}.loop.sh"
	if _wd_orphans=$(watchdog_script_pids "$_wd_script_file"); then
		# A script-bound orphan without an owner file must not be killed or duplicated.
		return 2
	else
		_wd_orphan_rc=$?
	fi
	[ "$_wd_orphan_rc" -ne 2 ] || return 2
	mkdir -p "${_wd_log_file%/*}" 2>/dev/null || true
	{
		printf '%s\n' '#!/system/bin/sh'
		printf '%s\n' "MODDIR=$(watchdog_shell_quote "${MODDIR:-}")"
		printf '%s\n' "MODPATH=$(watchdog_shell_quote "${MODDIR:-}")"
		printf '%s\n' "KAM_HOME=$(watchdog_shell_quote "${KAM_HOME:-${MODDIR:-}}")"
		printf '%s\n' "KAMFW_DIR=$(watchdog_shell_quote "${KAMFW_DIR:-}")"
		printf '%s\n' "KAM_MODULES=''"
		printf '%s\n' "KAM_WATCHDOG_NOTIFY_TITLE=$(watchdog_shell_quote "${KAM_WATCHDOG_NOTIFY_TITLE:-kamfw watchdog}")"
		printf '%s\n' "export MODDIR MODPATH KAM_HOME KAMFW_DIR KAM_MODULES KAM_WATCHDOG_NOTIFY_TITLE"
		printf '%s\n' 'cd "$KAM_HOME" || exit 1'
		printf '%s\n' 'if [ -n "$KAMFW_DIR" ] && [ -f "$KAMFW_DIR/.kamfwrc" ]; then . "$KAMFW_DIR/.kamfwrc"; fi'
		printf '%s\n' 'trap "" HUP'
		printf '%s\n' '[ ! -f "$KAM_HOME/disable" ] && [ ! -f "$KAM_HOME/remove" ] || exit 0'
		printf '%s\n' "sleep $(watchdog_shell_quote "$_wd_start_interval")"
		printf '%s\n' 'while :; do'
		printf '%s\n' '  [ ! -f "$KAM_HOME/disable" ] && [ ! -f "$KAM_HOME/remove" ] || exit 0'
		printf '%s\n' "  if ! sh -c $(watchdog_shell_quote "$_wd_start_cmd"); then"
		printf '%s\n' "    _wd_fail_msg=$(watchdog_shell_quote "watchdog $_wd_start_name: command failed")"
		printf '%s\n' '    if command -v warn >/dev/null 2>&1; then warn "$_wd_fail_msg"; else printf "%s\n" "$_wd_fail_msg" >&2; fi'
		if [ "$_wd_start_notify" = "1" ]; then
			printf '%s\n' '    if ! command -v notify >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then import notify >/dev/null 2>&1 || true; fi'
			printf '%s\n' '    if command -v notify >/dev/null 2>&1; then notify alert "kamfw_watchdog_'"$_wd_start_name"'" "$KAM_WATCHDOG_NOTIFY_TITLE" "$_wd_fail_msg" >/dev/null 2>&1 || true; fi'
		fi
		printf '%s\n' '  fi'
		printf '%s\n' "  sleep $(watchdog_shell_quote "$_wd_start_interval")"
		printf '%s\n' 'done'
	} >"$_wd_script_file" || return 1
	chmod 700 "$_wd_script_file" 2>/dev/null || true
	: >"$_wd_log_file" 2>/dev/null || true
	nohup sh "$_wd_script_file" </dev/null >>"$_wd_log_file" 2>&1 &
	_wd_pid=$!
	print "$_wd_pid" >"$_wd_pid_file" || return 1
	_wd_ready_attempt=0
	_wd_ready_rc=1
	while [ "$_wd_ready_attempt" -lt 10 ]; do
		if watchdog_pid_matches_script "$_wd_pid" "$_wd_script_file"; then _wd_ready_rc=0; break; else _wd_ready_rc=$?; fi
		_wd_ready_attempt=$((_wd_ready_attempt + 1))
		sleep 0.05
	done
	if [ "$_wd_ready_rc" -eq 2 ]; then return 2; fi
	if [ "$_wd_ready_rc" -ne 0 ]; then
		kill "$_wd_pid" 2>/dev/null || true
		rm -f "$_wd_pid_file" 2>/dev/null || true
		return 1
	fi
	success "$(i18n WATCHDOG_STARTED | t "$_wd_start_name" "$_wd_pid")"

	unset _wd_notify _wd_name _wd_interval _wd_cmd _wd_start_name _wd_start_interval _wd_start_cmd _wd_start_notify _wd_pid_file _wd_log_file _wd_script_file _wd_pid _wd_existing_pid
}

watchdog() {
	_wd_action="$1"
	shift || true
	case "$_wd_action" in
	start) watchdog_start "$@" ;;
	stop) watchdog_stop "$@" ;;
	status) watchdog_status "$@" ;;
	once) watchdog_once "$@" ;;
	*)
		print "Usage: watchdog start [--notify|--alert] <name> <interval_sec> <command...>"
		print "       watchdog stop <name>"
		print "       watchdog status <name>"
		print "       watchdog once <command...>"
		return 2
		;;
	esac
	_wd_rc=$?
	unset _wd_action
	return "$_wd_rc"
}
