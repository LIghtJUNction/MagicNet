# shellcheck shell=ash
#
# kamfw async file change monitor
#
# Polling-based and dependency-light. Importing this file must not start
# background work. Use `fswatch start ...` explicitly from a runtime phase.

set_i18n "FSWATCH_NAME_REQUIRED" \
	"zh" "fswatch: 名称不能为空" \
	"en" "fswatch: name is required" \
	"ja" "fswatch: 名前が必要です" \
	"ko" "fswatch: 이름이 필요합니다"

set_i18n "FSWATCH_PATH_REQUIRED" \
	"zh" "fswatch: 监控路径不能为空" \
	"en" "fswatch: path is required" \
	"ja" "fswatch: パスが必要です" \
	"ko" "fswatch: 경로가 필요합니다"

set_i18n "FSWATCH_PATH_MISSING" \
	"zh" "fswatch: 路径不存在: \$_1" \
	"en" "fswatch: path does not exist: \$_1" \
	"ja" "fswatch: パスが存在しません: \$_1" \
	"ko" "fswatch: 경로가 없습니다: \$_1"

set_i18n "FSWATCH_COMMAND_REQUIRED" \
	"zh" "fswatch: 命令不能为空" \
	"en" "fswatch: command is required" \
	"ja" "fswatch: コマンドが必要です" \
	"ko" "fswatch: 명령이 필요합니다"

set_i18n "FSWATCH_INTERVAL_INVALID" \
	"zh" "fswatch: 间隔必须是正整数秒" \
	"en" "fswatch: interval must be a positive number of seconds" \
	"ja" "fswatch: 間隔は正の秒数である必要があります" \
	"ko" "fswatch: 간격은 양의 초 단위여야 합니다"

set_i18n "FSWATCH_TOOL_MISSING" \
	"zh" "fswatch: 缺少必需工具: \$_1" \
	"en" "fswatch: required command not found: \$_1" \
	"ja" "fswatch: 必要なコマンドがありません: \$_1" \
	"ko" "fswatch: 필수 명령이 없습니다: \$_1"

set_i18n "FSWATCH_STARTED" \
	"zh" "fswatch 已启动: \$_1 (pid=\$_2)" \
	"en" "fswatch started: \$_1 (pid=\$_2)" \
	"ja" "fswatch を開始しました: \$_1 (pid=\$_2)" \
	"ko" "fswatch 시작됨: \$_1 (pid=\$_2)"

set_i18n "FSWATCH_STOPPED" \
	"zh" "fswatch 已停止: \$_1" \
	"en" "fswatch stopped: \$_1" \
	"ja" "fswatch を停止しました: \$_1" \
	"ko" "fswatch 중지됨: \$_1"

set_i18n "FSWATCH_NOT_RUNNING" \
	"zh" "fswatch 未运行: \$_1" \
	"en" "fswatch is not running: \$_1" \
	"ja" "fswatch は実行されていません: \$_1" \
	"ko" "fswatch 실행 중 아님: \$_1"

set_i18n "FSWATCH_CHANGED" \
	"zh" "fswatch 检测到变化: \$_1" \
	"en" "fswatch change detected: \$_1" \
	"ja" "fswatch が変更を検出しました: \$_1" \
	"ko" "fswatch 변경 감지됨: \$_1"

fswatch_state_dir() {
	: "${KAM_HOME:=${MODDIR:-${0%/*}}}"
	_fw_dir="${KAM_FSWATCH_STATE_DIR:-$KAM_HOME/.state/fswatch}"
	mkdir -p "$_fw_dir" 2>/dev/null || return 1
	print "$_fw_dir"
	unset _fw_dir
}

fswatch_pid_file() {
	_fw_name="$1"
	fswatch_valid_name "$_fw_name" || return 1
	_fw_dir="$(fswatch_state_dir)" || return 1
	print "$_fw_dir/$_fw_name.pid"
	unset _fw_name _fw_dir
}

fswatch_snapshot_file() {
	_fw_name="$1"
	fswatch_valid_name "$_fw_name" || return 1
	_fw_dir="$(fswatch_state_dir)" || return 1
	print "$_fw_dir/$_fw_name.snapshot"
	unset _fw_name _fw_dir
}

fswatch_loop_script_file() (
	_fw_name="$1"
	[ -z "$_fw_name" ] && return 1
	_fw_pid_file="$(fswatch_pid_file "$_fw_name")" || return 1
	print "${_fw_pid_file%.pid}.loop.sh"
	unset _fw_name _fw_pid_file
)

fswatch_shell_quote() {
	printf "'"
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
	printf "'"
}

fswatch_valid_interval() {
	case "$1" in
	"" | *[!0-9]* | 0) return 1 ;;
	*) return 0 ;;
	esac
}

fswatch_valid_name() {
	case "$1" in
	"" | "." | ".." | *[!A-Za-z0-9._-]*) return 1 ;;
	*) return 0 ;;
	esac
}

fswatch_is_pid_alive() {
	_fw_pid="$1"
	[ -n "$_fw_pid" ] || return 1
	if kill -0 "$_fw_pid" 2>/dev/null; then return 0; fi
	[ -d "/proc/$_fw_pid" ] && return 2
	return 1
}

fswatch_proc_cmdline_lines() (
	_fw_pid="$1"
	if type magicnet_proc_cmdline_lines >/dev/null 2>&1; then
		magicnet_proc_cmdline_lines "$_fw_pid" /proc
		return $?
	fi
	_fw_module_root="${MODDIR:-${KAM_HOME:-}}"
	_fw_reader="${_fw_module_root}/cli"
	[ -x "$_fw_reader" ] || return 2
	"$_fw_reader" __proc-cmdline /proc "$_fw_pid"
)

fswatch_proc_stat_identity() (
	_fw_pid="$1"
	if type magicnet_proc_stat_identity >/dev/null 2>&1; then
		magicnet_proc_stat_identity "$_fw_pid" /proc
		return $?
	fi
	_fw_module_root="${MODDIR:-${KAM_HOME:-}}"
	_fw_reader="${_fw_module_root}/cli"
	[ -x "$_fw_reader" ] || return 2
	"$_fw_reader" __proc-stat /proc "$_fw_pid"
)

fswatch_pid_matches_script() (
	_fw_pid="$1"
	_fw_script_file="$2"
	if fswatch_is_pid_alive "$_fw_pid"; then _fw_alive_rc=0; else _fw_alive_rc=$?; fi
	[ "$_fw_alive_rc" -eq 0 ] || return "$_fw_alive_rc"
	if _fw_cmdline=$(fswatch_proc_cmdline_lines "$_fw_pid"); then _fw_read_rc=0; else _fw_read_rc=$?; fi
	[ "$_fw_read_rc" -eq 0 ] || return "$_fw_read_rc"
	_fw_argv0=''
	_fw_argv1=''
	_fw_index=0
	while IFS= read -r _fw_argument || [ -n "$_fw_argument" ]; do
		_fw_index=$((_fw_index + 1))
		case "$_fw_index" in
		1) _fw_argv0="$_fw_argument" ;;
		2) _fw_argv1="$_fw_argument" ;;
		*) return 1 ;;
		esac
	done <<EOF
$_fw_cmdline
EOF
	[ "$_fw_index" -eq 2 ] || return 1
	case "${_fw_argv0##*/}" in
	sh | ash | dash | bash | ksh | mksh) ;;
	*) return 1 ;;
	esac
	[ "$_fw_argv1" = "$_fw_script_file" ]
)

fswatch_stop_pid_for_script() (
	_fw_pid="$1"
	_fw_script_file="$2"
	if fswatch_pid_matches_script "$_fw_pid" "$_fw_script_file"; then _fw_rc=0; else _fw_rc=$?; fi
	[ "$_fw_rc" -eq 0 ] || return "$_fw_rc"
	kill "$_fw_pid" 2>/dev/null || true
	sleep 1
	if fswatch_pid_matches_script "$_fw_pid" "$_fw_script_file"; then
		kill -9 "$_fw_pid" 2>/dev/null || true
		sleep 1
		fswatch_pid_matches_script "$_fw_pid" "$_fw_script_file" && return 1
		_fw_rc=$?
		[ "$_fw_rc" -ne 2 ] || return 2
	else
		_fw_rc=$?
		[ "$_fw_rc" -ne 2 ] || return 2
	fi
	return 0
)

fswatch_stop_script_processes() (
	_fw_script_file="$1"
	if _fw_ps=$(ps -A -o pid=,args= 2>/dev/null); then _fw_rc=0; else _fw_rc=$?; fi
	[ "$_fw_rc" -eq 0 ] || return 2
	_fw_candidates=$(printf '%s\n' "$_fw_ps" | awk -v expected="$_fw_script_file" 'index($0, expected) { print $1 }')
	_fw_pids=''
	_fw_count=0
	for _fw_pid in $_fw_candidates; do
		_fw_count=$((_fw_count + 1))
		[ "$_fw_count" -le 256 ] || return 2
		if fswatch_pid_matches_script "$_fw_pid" "$_fw_script_file"; then
			_fw_pids="${_fw_pids}${_fw_pids:+
}${_fw_pid}"
		else
			_fw_rc=$?
			[ "$_fw_rc" -ne 2 ] || return 2
		fi
	done
	[ -n "$_fw_pids" ] || return 1
	for _fw_pid in $_fw_pids; do
		fswatch_stop_pid_for_script "$_fw_pid" "$_fw_script_file" || return $?
	done
	return 0
)

fswatch_lifecycle_lock_file() (
	_fw_name="$1"
	[ -n "$_fw_name" ] || return 1
	_fw_pid_file="$(fswatch_pid_file "$_fw_name")" || return 1
	print "${_fw_pid_file%.pid}.lifecycle.lock"
	unset _fw_name _fw_pid_file
)

fswatch_process_start_time() (
	_fw_pid="$1"
	if _fw_identity=$(fswatch_proc_stat_identity "$_fw_pid"); then _fw_rc=0; else _fw_rc=$?; fi
	[ "$_fw_rc" -eq 0 ] || return "$_fw_rc"
	_fw_start=${_fw_identity#* }
	case "$_fw_start" in '' | *[!0-9]*) return 1 ;; esac
	print "$_fw_start"
)

fswatch_run_locked() (
	_fw_action="$1"
	_fw_name="$2"
	shift 2
	_fw_lock_file="$(fswatch_lifecycle_lock_file "$_fw_name")" || return 1
	_fw_runner_script='
KAM_MODULES=""
export KAM_MODULES
. "$KAMFW_DIR/.kamfwrc" || exit 1
import fswatch || exit 1
case "$1" in
  start) shift; fswatch_start_unlocked "$@" ;;
  stop) shift; fswatch_stop_unlocked "$@" ;;
  *) exit 2 ;;
esac
'

	_fw_busybox_bin="${KAM_FSWATCH_BUSYBOX_BIN:-}"
	if [ -z "$_fw_busybox_bin" ] && command -v busybox >/dev/null 2>&1; then
		_fw_busybox_bin="$(command -v busybox)"
	fi

	if [ -n "$_fw_busybox_bin" ] && [ -x "$_fw_busybox_bin" ] && "$_fw_busybox_bin" flock --help >/dev/null 2>&1; then
		if ! "$_fw_busybox_bin" start-stop-daemon --help >/dev/null 2>&1; then
			error "$(i18n FSWATCH_TOOL_MISSING | t start-stop-daemon)"
			return 1
		fi
		env \
			KAM_FSWATCH_LOCK_HELD=1 \
			KAM_FSWATCH_LOCK_FILE="$_fw_lock_file" \
			KAM_FSWATCH_RUNNER_KIND=busybox \
			KAM_FSWATCH_BUSYBOX_BIN="$_fw_busybox_bin" \
			KAM_HOME="${KAM_HOME:-${MODDIR:-}}" \
			MODDIR="${MODDIR:-}" \
			MODPATH="${MODPATH:-${MODDIR:-}}" \
			KAMFW_DIR="${KAMFW_DIR:-}" \
			KAM_FSWATCH_STATE_DIR="${KAM_FSWATCH_STATE_DIR:-}" \
			KAM_FSWATCH_LOG_FILE="${KAM_FSWATCH_LOG_FILE:-}" \
			KAM_FSWATCH_PRUNE_NAMES="${KAM_FSWATCH_PRUNE_NAMES:-}" \
			"$_fw_busybox_bin" flock "$_fw_lock_file" sh -c "$_fw_runner_script" fswatch-runner "$_fw_action" "$_fw_name" "$@"
		return $?
	fi

	if command -v flock >/dev/null 2>&1 && flock -n -o /dev/null true >/dev/null 2>&1; then
		env \
			KAM_FSWATCH_LOCK_HELD=1 \
			KAM_FSWATCH_LOCK_FILE="$_fw_lock_file" \
			KAM_FSWATCH_RUNNER_KIND=util-linux \
			KAM_HOME="${KAM_HOME:-${MODDIR:-}}" \
			MODDIR="${MODDIR:-}" \
			MODPATH="${MODPATH:-${MODDIR:-}}" \
			KAMFW_DIR="${KAMFW_DIR:-}" \
			KAM_FSWATCH_STATE_DIR="${KAM_FSWATCH_STATE_DIR:-}" \
			KAM_FSWATCH_LOG_FILE="${KAM_FSWATCH_LOG_FILE:-}" \
			KAM_FSWATCH_PRUNE_NAMES="${KAM_FSWATCH_PRUNE_NAMES:-}" \
			flock -o "$_fw_lock_file" sh -c "$_fw_runner_script" fswatch-runner "$_fw_action" "$_fw_name" "$@"
		return $?
	fi

	error "$(i18n FSWATCH_TOOL_MISSING | t flock)"
	return 1
)

fswatch_inherited_lock_fds() (
	_fw_lock_file="$1"
	[ -n "$_fw_lock_file" ] || return 0
	for _fw_fd_path in "/proc/$$/fd/"[0-9]*; do
		[ -e "$_fw_fd_path" ] || continue
		_fw_fd="${_fw_fd_path##*/}"
		case "$_fw_fd" in
		'' | *[!0-9]*) continue ;;
		esac
		_fw_target="$(readlink "$_fw_fd_path" 2>/dev/null)" || continue
		[ "$_fw_target" = "$_fw_lock_file" ] && print "$_fw_fd"
	done
)

fswatch_close_inherited_lock_fds() {
	_fw_lock_file="$1"
	_fw_lock_fds="$(fswatch_inherited_lock_fds "$_fw_lock_file")"
	for _fw_lock_fd in $_fw_lock_fds; do
		case "$_fw_lock_fd" in
		'' | *[!0-9]*) continue ;;
		esac
		eval "exec ${_fw_lock_fd}>&-"
	done
	unset _fw_lock_file _fw_lock_fds _fw_lock_fd
}

fswatch_pid_has_start_time() (
	_fw_pid="$1"
	_fw_expected_start="$2"
	if _fw_actual_start=$(fswatch_process_start_time "$_fw_pid"); then _fw_rc=0; else _fw_rc=$?; fi
	[ "$_fw_rc" -eq 0 ] || return "$_fw_rc"
	[ "$_fw_actual_start" = "$_fw_expected_start" ]
)

fswatch_stop_pid_identity() (
	_fw_pid="$1"
	_fw_start_time="$2"
	fswatch_pid_has_start_time "$_fw_pid" "$_fw_start_time" || return 1
	kill "$_fw_pid" 2>/dev/null || true
	sleep 1
	fswatch_pid_has_start_time "$_fw_pid" "$_fw_start_time" && kill -9 "$_fw_pid" 2>/dev/null || true
)

fswatch_require_tools() {
	for _fw_tool in find cksum sort readlink; do
		if ! command -v "$_fw_tool" >/dev/null 2>&1; then
			error "$(i18n FSWATCH_TOOL_MISSING | t "$_fw_tool")"
			unset _fw_tool
			return 1
		fi
	done
	unset _fw_tool
}

fswatch_path_is_pruned() {
	_fw_prune_path="$1"
	for _fw_prune_name in ${KAM_FSWATCH_PRUNE_NAMES:-}; do
		case "$_fw_prune_path" in
		*/"$_fw_prune_name" | */"$_fw_prune_name"/*)
			unset _fw_prune_path _fw_prune_name
			return 0
			;;
		esac
	done
	unset _fw_prune_path _fw_prune_name
	return 1
}

fswatch_snapshot() {
	_fw_path="$1"
	[ -z "$_fw_path" ] && {
		error "$(i18n FSWATCH_PATH_REQUIRED)"
		return 2
	}
	[ -e "$_fw_path" ] || {
		error "$(i18n FSWATCH_PATH_MISSING | t "$_fw_path")"
		return 1
	}
	fswatch_require_tools || return 1

	if [ -d "$_fw_path" ]; then
		{
			find "$_fw_path" -type d -print 2>/dev/null | while IFS= read -r _fw_item || [ -n "$_fw_item" ]; do
				fswatch_path_is_pruned "$_fw_item" && continue
				printf 'D %s\n' "$_fw_item"
			done
			find "$_fw_path" -type f -print 2>/dev/null | while IFS= read -r _fw_item || [ -n "$_fw_item" ]; do
				fswatch_path_is_pruned "$_fw_item" && continue
				cksum "$_fw_item" 2>/dev/null | sed 's/^/F /'
			done
		} | LC_ALL=C sort
	else
		cksum "$_fw_path" 2>/dev/null | sed 's/^/F /'
	fi

	unset _fw_path _fw_item
}

fswatch_changed() {
	_fw_path="$1"
	_fw_snapshot="$2"
	[ -n "$_fw_snapshot" ] || return 2

	_fw_tmp_dir="${TMPDIR:-}"
	if [ -z "$_fw_tmp_dir" ] || [ ! -d "$_fw_tmp_dir" ] || [ ! -w "$_fw_tmp_dir" ]; then
		_fw_module_root="${KAM_HOME:-${MODDIR:-}}"
		[ -n "$_fw_module_root" ] || {
			unset _fw_path _fw_snapshot _fw_tmp_dir _fw_module_root
			return 1
		}
		_fw_tmp_dir="${_fw_module_root}/.tmp"
		mkdir -p "$_fw_tmp_dir" 2>/dev/null || {
			unset _fw_path _fw_snapshot _fw_tmp_dir _fw_module_root
			return 1
		}
	fi
	_fw_tmp="$_fw_tmp_dir/kamfw.fswatch.$$"
	fswatch_snapshot "$_fw_path" >"$_fw_tmp" || {
		rm -f "$_fw_tmp" 2>/dev/null || true
		unset _fw_path _fw_snapshot _fw_tmp_dir _fw_tmp _fw_module_root
		return 1
	}

	if [ ! -f "$_fw_snapshot" ] || ! cmp -s "$_fw_tmp" "$_fw_snapshot" 2>/dev/null; then
		cp "$_fw_tmp" "$_fw_snapshot" 2>/dev/null || {
			rm -f "$_fw_tmp" 2>/dev/null || true
			unset _fw_path _fw_snapshot _fw_tmp_dir _fw_tmp _fw_module_root
			return 1
		}
		rm -f "$_fw_tmp" 2>/dev/null || true
		unset _fw_path _fw_snapshot _fw_tmp_dir _fw_tmp _fw_module_root
		return 0
	fi

	rm -f "$_fw_tmp" 2>/dev/null || true
	unset _fw_path _fw_snapshot _fw_tmp_dir _fw_tmp _fw_module_root
	return 1
}

fswatch_status() {
	_fw_name="$1"
	[ -z "$_fw_name" ] && {
		error "$(i18n FSWATCH_NAME_REQUIRED)"
		return 2
	}

	_fw_pid_file="$(fswatch_pid_file "$_fw_name")" || return 1
	_fw_script_file="$(fswatch_loop_script_file "$_fw_name")" || return 1
	if [ -f "$_fw_pid_file" ]; then
		_fw_pid="$(sed -n '1p' "$_fw_pid_file" 2>/dev/null)"
		if fswatch_pid_matches_script "$_fw_pid" "$_fw_script_file"; then
			print "$_fw_pid"
			unset _fw_name _fw_pid_file _fw_script_file _fw_pid
			return 0
		else
			_fw_match_rc=$?
		fi
		[ "$_fw_match_rc" -ne 2 ] || return 2
		rm -f "$_fw_pid_file" 2>/dev/null || true
	fi

	unset _fw_name _fw_pid_file _fw_script_file _fw_pid
	return 1
}

fswatch_stop_unlocked() (
	_fw_name="$1"
	[ "${KAM_FSWATCH_LOCK_HELD:-0}" = "1" ] || return 1
	_fw_pid_file="$(fswatch_pid_file "$_fw_name")" || return 1
	_fw_script_file="$(fswatch_loop_script_file "$_fw_name")" || return 1
	if fswatch_stop_script_processes "$_fw_script_file"; then _fw_rc=0; else _fw_rc=$?; fi
	[ "$_fw_rc" -ne 2 ] || return 2
	rm -f "$_fw_pid_file" 2>/dev/null || return 1
	if [ "$_fw_rc" -eq 0 ]; then success "$(i18n FSWATCH_STOPPED | t "$_fw_name")"; else warn "$(i18n FSWATCH_NOT_RUNNING | t "$_fw_name")"; fi
	return "$_fw_rc"
)

fswatch_stop() {
	_fw_name="$1"
	[ -z "$_fw_name" ] && {
		error "$(i18n FSWATCH_NAME_REQUIRED)"
		return 2
	}
	fswatch_run_locked stop "$_fw_name"
	_fw_rc=$?
	unset _fw_name
	return "$_fw_rc"
}

fswatch_start_unlocked() {
	_fw_name="$1"
	_fw_path="$2"
	_fw_interval="$3"
	shift 3 2>/dev/null || true
	_fw_cmd="$*"
	[ "${KAM_FSWATCH_LOCK_HELD:-0}" = "1" ] || return 1

	[ -z "$_fw_name" ] && {
		error "$(i18n FSWATCH_NAME_REQUIRED)"
		return 2
	}
	[ -z "$_fw_path" ] && {
		error "$(i18n FSWATCH_PATH_REQUIRED)"
		unset _fw_name _fw_path _fw_interval _fw_cmd
		return 2
	}
	[ -z "$_fw_cmd" ] && {
		error "$(i18n FSWATCH_COMMAND_REQUIRED)"
		unset _fw_name _fw_path _fw_interval _fw_cmd
		return 2
	}
	if ! fswatch_valid_interval "$_fw_interval"; then
		error "$(i18n FSWATCH_INTERVAL_INVALID)"
		unset _fw_name _fw_path _fw_interval _fw_cmd
		return 2
	fi
	[ -e "$_fw_path" ] || {
		error "$(i18n FSWATCH_PATH_MISSING | t "$_fw_path")"
		unset _fw_name _fw_path _fw_interval _fw_cmd
		return 1
	}
	fswatch_require_tools || {
		unset _fw_name _fw_path _fw_interval _fw_cmd
		return 1
	}

	_fw_start_name="$_fw_name"
	_fw_start_path="$_fw_path"
	_fw_start_interval="$_fw_interval"
	_fw_start_cmd="$_fw_cmd"

	_fw_pid_file="$(fswatch_pid_file "$_fw_start_name")" || {
		return 1
	}
	_fw_snapshot_file="$(fswatch_snapshot_file "$_fw_start_name")" || {
		return 1
	}
	_fw_log_file="${KAM_FSWATCH_LOG_FILE:-${KAM_HOME:-$MODDIR}/.log/fswatch.log}"
	_fw_script_file="$(fswatch_loop_script_file "$_fw_start_name")" || {
		return 1
	}
	if fswatch_stop_script_processes "$_fw_script_file" >/dev/null 2>&1; then _fw_existing_rc=0; else _fw_existing_rc=$?; fi
	[ "$_fw_existing_rc" -ne 2 ] || return 2
	rm -f "$_fw_pid_file" 2>/dev/null || return 1
	mkdir -p "${_fw_log_file%/*}" 2>/dev/null || true
	_fw_loop_name="$_fw_start_name"
	_fw_loop_path="$_fw_start_path"
	_fw_loop_interval="$_fw_start_interval"
	_fw_loop_cmd="$_fw_start_cmd"
	_fw_loop_snapshot_file="$_fw_snapshot_file"
	fswatch_snapshot "$_fw_loop_path" >"$_fw_loop_snapshot_file" || {
		return 1
	}

	{
		printf '%s\n' '#!/system/bin/sh'
		printf '%s\n' 'unset LD_LIBRARY_PATH'
		printf '%s\n' "MODDIR=$(fswatch_shell_quote "${MODDIR:-}")"
		printf '%s\n' "MODPATH=$(fswatch_shell_quote "${MODDIR:-}")"
		printf '%s\n' "KAM_HOME=$(fswatch_shell_quote "${KAM_HOME:-${MODDIR:-}}")"
		printf '%s\n' "KAMFW_DIR=$(fswatch_shell_quote "${KAMFW_DIR:-}")"
		printf '%s\n' "KAM_MODULES=''"
		printf '%s\n' "KAM_FSWATCH_PRUNE_NAMES=$(fswatch_shell_quote "${KAM_FSWATCH_PRUNE_NAMES:-}")"
		printf '%s\n' "export MODDIR MODPATH KAM_HOME KAMFW_DIR KAM_MODULES KAM_FSWATCH_PRUNE_NAMES"
		printf '%s\n' 'cd "$KAM_HOME" || exit 1'
		printf '%s\n' 'if [ -n "$KAMFW_DIR" ] && [ -f "$KAMFW_DIR/.kamfwrc" ]; then . "$KAMFW_DIR/.kamfwrc"; import fswatch; fi'
		printf '%s\n' 'command -v fswatch_changed >/dev/null 2>&1 || { printf "%s\n" "fswatch_changed unavailable; exiting" >&2; exit 1; }'
		printf '%s\n' 'trap "" HUP'
		printf '%s\n' 'while :; do'
		printf '%s\n' '  [ ! -f "$KAM_HOME/disable" ] && [ ! -f "$KAM_HOME/remove" ] || exit 0'
		printf '%s\n' "  _fw_previous_snapshot=$(fswatch_shell_quote "${_fw_loop_snapshot_file}.previous")"
		printf '%s\n' "  cp $(fswatch_shell_quote "$_fw_loop_snapshot_file") \"\$_fw_previous_snapshot\" || exit 1"
		printf '%s\n' "  if fswatch_changed $(fswatch_shell_quote "$_fw_loop_path") $(fswatch_shell_quote "$_fw_loop_snapshot_file"); then"
		printf '%s\n' "    if command -v info >/dev/null 2>&1; then info $(fswatch_shell_quote "fswatch change detected: $_fw_loop_name"); fi"
		printf '%s\n' "    if KAM_FSWATCH_NAME=$(fswatch_shell_quote "$_fw_loop_name") KAM_FSWATCH_PATH=$(fswatch_shell_quote "$_fw_loop_path") KAM_FSWATCH_SNAPSHOT=$(fswatch_shell_quote "$_fw_loop_snapshot_file") sh -c $(fswatch_shell_quote "$_fw_loop_cmd"); then"
		printf '%s\n' '      rm -f "$_fw_previous_snapshot"'
		printf '%s\n' '    else'
		printf '%s\n' "      mv -f \"\$_fw_previous_snapshot\" $(fswatch_shell_quote "$_fw_loop_snapshot_file") || exit 1"
		printf '%s\n' '    fi'
		printf '%s\n' '  else'
		printf '%s\n' '    rm -f "$_fw_previous_snapshot"'
		printf '%s\n' '  fi'
		printf '%s\n' "  sleep $(fswatch_shell_quote "$_fw_loop_interval")"
		printf '%s\n' 'done'
	} >"$_fw_script_file" || {
		return 1
	}
	chmod 700 "$_fw_script_file" 2>/dev/null || true
	if [ "${LD_LIBRARY_PATH+x}" = "x" ]; then
		_fw_ld_library_path_was_set=1
		_fw_ld_library_path_saved="$LD_LIBRARY_PATH"
	else
		_fw_ld_library_path_was_set=0
		_fw_ld_library_path_saved=""
	fi
	_fw_launch_pid_file="${_fw_pid_file}.launch.$$"
	rm -f "$_fw_launch_pid_file" 2>/dev/null || true
	_fw_launch_rc=0
	unset LD_LIBRARY_PATH
	case "${KAM_FSWATCH_RUNNER_KIND:-}" in
	busybox)
		fswatch_close_inherited_lock_fds "${KAM_FSWATCH_LOCK_FILE:-}"
		"${KAM_FSWATCH_BUSYBOX_BIN:-}" start-stop-daemon \
			-S -b -m -p "$_fw_launch_pid_file" -x /system/bin/sh -- "$_fw_script_file" \
			</dev/null >>"$_fw_log_file" 2>&1 || _fw_launch_rc=$?
		_fw_launch_pid_attempt=0
		while [ "$_fw_launch_rc" -eq 0 ] && [ ! -s "$_fw_launch_pid_file" ]; do
			_fw_launch_pid_attempt=$((_fw_launch_pid_attempt + 1))
			[ "$_fw_launch_pid_attempt" -lt 3 ] || break
			sleep 1
		done
		if [ "$_fw_launch_rc" -eq 0 ]; then
			_fw_pid="$(sed -n '1p' "$_fw_launch_pid_file" 2>/dev/null)"
		else
			_fw_pid=""
		fi
		;;
	util-linux)
		(
			nohup sh "$_fw_script_file"
		) </dev/null >>"$_fw_log_file" 2>&1 &
		_fw_pid=$!
		;;
	*)
		_fw_launch_rc=1
		_fw_pid=""
		;;
	esac
	if [ "$_fw_ld_library_path_was_set" -eq 1 ]; then
		LD_LIBRARY_PATH="$_fw_ld_library_path_saved"
		export LD_LIBRARY_PATH
	else
		unset LD_LIBRARY_PATH
	fi
	rm -f "$_fw_launch_pid_file" 2>/dev/null || true
	_fw_pid_start_time=""
	case "$_fw_pid" in
	'' | *[!0-9]*) ;;
	*) _fw_pid_start_time="$(fswatch_process_start_time "$_fw_pid")" || _fw_pid_start_time="" ;;
	esac

	_fw_launch_attempt=0
	while [ -n "$_fw_pid_start_time" ] && fswatch_pid_has_start_time "$_fw_pid" "$_fw_pid_start_time" && ! fswatch_pid_matches_script "$_fw_pid" "$_fw_script_file"; do
		_fw_launch_attempt=$((_fw_launch_attempt + 1))
		[ "$_fw_launch_attempt" -lt "${KAM_FSWATCH_LAUNCH_ATTEMPTS:-10}" ] || break
		sleep 1
	done
	if [ -z "$_fw_pid_start_time" ] || ! fswatch_pid_has_start_time "$_fw_pid" "$_fw_pid_start_time" || ! fswatch_pid_matches_script "$_fw_pid" "$_fw_script_file"; then
		[ -n "$_fw_pid_start_time" ] && fswatch_stop_pid_identity "$_fw_pid" "$_fw_pid_start_time" >/dev/null 2>&1 || true
		rm -f "$_fw_pid_file" 2>/dev/null || true
		fswatch_stop_script_processes "$_fw_script_file" >/dev/null 2>&1 || true
		error "fswatch: watcher failed to enter loop: $_fw_start_name"
		return 1
	fi
	_fw_publish_pid_file="${_fw_pid_file}.publish.$$"
	_fw_publish_rc=0
	rm -f "$_fw_publish_pid_file" 2>/dev/null || true
	print "$_fw_pid" >"$_fw_publish_pid_file" || _fw_publish_rc=$?
	if [ "$_fw_publish_rc" -eq 0 ]; then
		mv -f "$_fw_publish_pid_file" "$_fw_pid_file" || _fw_publish_rc=$?
	fi
	if [ "$_fw_publish_rc" -ne 0 ]; then
		rm -f "$_fw_publish_pid_file" "$_fw_pid_file" 2>/dev/null || true
		fswatch_stop_pid_identity "$_fw_pid" "$_fw_pid_start_time" >/dev/null 2>&1 || true
		fswatch_stop_script_processes "$_fw_script_file" >/dev/null 2>&1 || true
		error "fswatch: failed to publish watcher pid: $_fw_start_name"
		return 1
	fi
	success "$(i18n FSWATCH_STARTED | t "$_fw_start_name" "$_fw_pid")"

	unset _fw_name _fw_path _fw_interval _fw_cmd _fw_start_name _fw_start_path _fw_start_interval _fw_start_cmd _fw_pid_file _fw_snapshot_file _fw_log_file _fw_script_file _fw_loop_name _fw_loop_path _fw_loop_interval _fw_loop_cmd _fw_loop_snapshot_file _fw_ld_library_path_was_set _fw_ld_library_path_saved _fw_launch_pid_file _fw_launch_pid_attempt _fw_launch_rc _fw_pid _fw_pid_start_time _fw_launch_attempt _fw_publish_pid_file _fw_publish_rc
}

fswatch_start() {
	fswatch_run_locked start "$@"
}

fswatch() {
	_fw_action="$1"
	shift || true
	case "$_fw_action" in
	snapshot) fswatch_snapshot "$@" ;;
	changed) fswatch_changed "$@" ;;
	start) fswatch_start "$@" ;;
	stop) fswatch_stop "$@" ;;
	status) fswatch_status "$@" ;;
	*)
		print "Usage: fswatch snapshot <path>"
		print "       fswatch changed <path> <snapshot-file>"
		print "       fswatch start <name> <path> <interval_sec> <command...>"
		print "       fswatch stop <name>"
		print "       fswatch status <name>"
		return 2
		;;
	esac
	_fw_rc=$?
	unset _fw_action
	return "$_fw_rc"
}
