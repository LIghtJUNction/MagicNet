# shellcheck shell=ash
#
# logging.sh
#
# Logging and console output helpers for kamfw
#
# - Moves logging-related functions out of base.sh into a dedicated helper.
# - Adds configurable LOGLEVEL via env KAM_LOGLEVEL (DEBUG/INFO/WARN/ERROR).
# - Backwards compatible with KAM_DEBUG=1 (treats it as DEBUG).
# - Console output + wrapper functions (info/warn/error/debug/success) obey LOGLEVEL.
# - The lower-level `log` function (writes to file) preserves its previous
#   behaviour and may still be invoked directly (unfiltered) for compatibility.
#
# New i18n keys:
#   LOGLEVEL_SET
#
# Test / verification:
# 1) Default (no KAM_LOGLEVEL): INFO level.
#    - Run `info "hello"` -> prints to console and writes to log file.
#    - Run `debug "x"` -> not printed by default.
# 2) Enable debug: `export KAM_LOGLEVEL=DEBUG` or `export KAM_DEBUG=1`
#    - Run `debug "x"` -> printed and logged.
# 3) Restrict to ERROR: `export KAM_LOGLEVEL=ERROR`
#    - Run `info "hi"` -> nothing printed.
#    - Run `error "oops"` -> printed and logged.
#
# Note:
# - This helper expects color constants (COL_*) and `print` to be already defined
#   by earlier-loaded helpers (base.sh / .kamfwrc). Import ordering should ensure
#   base -> i18n -> logging -> others.
#
set_i18n "LOGLEVEL_SET" \
	"zh" "日志级别已设置为 %s" \
	"en" "Log level set to %s" \
	"ja" "ログレベルを %s に設定しました" \
	"ko" "로그 레벨이 %s(으)로 설정되었습니다"

# Normalize a user-provided level to canonical name
__kam_log_level_normalize() {
	case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
	0 | ERROR | ERR) printf '%s' "ERROR" ;;
	1 | WARN | WARNING) printf '%s' "WARN" ;;
	3 | DEBUG | DBG) printf '%s' "DEBUG" ;;
	2 | INFO) printf '%s' "INFO" ;;
	*) printf '%s' "INFO" ;; # default
	esac
}

# Map canonical name to numeric level: ERROR=0, WARN=1, INFO=2, DEBUG=3
__kam_log_level_value() {
	case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
	ERROR) printf '%s' 0 ;;
	WARN) printf '%s' 1 ;;
	INFO) printf '%s' 2 ;;
	DEBUG) printf '%s' 3 ;;
	*) printf '%s' 2 ;; # default INFO
	esac
}

# Current numeric loglevel value (DEBUG via KAM_DEBUG takes precedence)
__kam_current_loglevel() {
	if [ "${KAM_DEBUG:-0}" = "1" ]; then
		printf '%s' 3
		return 0
	fi
	if [ -n "${KAM_LOGLEVEL:-}" ]; then
		__kam_log_level_value "${KAM_LOGLEVEL}"
		return 0
	fi
	if [ -n "${LOGLEVEL:-}" ]; then
		__kam_log_level_value "${LOGLEVEL}"
		return 0
	fi
	# default
	printf '%s' 2
}

# Check whether messages at 'LEVEL' should be emitted to console
# Usage: __kam_should_emit "DEBUG" && echo "do it"
__kam_should_emit() {
	req=$(__kam_log_level_value "$1")
	cur=$(__kam_current_loglevel)
	[ "$cur" -ge "$req" ]
}

# Public setter for LOGLEVEL (canonicalizes names). Interactive feedback.
set_loglevel() {
	[ $# -eq 0 ] && return 0
	lvl="$1"
	norm="$(__kam_log_level_normalize "$lvl")"
	export KAM_LOGLEVEL="$norm"
	if [ -t 1 ]; then
		print "$(i18n 'LOGLEVEL_SET' 2>/dev/null | t "$norm" 2>/dev/null || printf 'Log level set to %s' "$norm")"
	fi
	return 0
}

# Console colorized helpers (use print, which is the canonical console printer)
green() { print "${COL_GRN}$1${COL_RST}"; }
red() { print "${COL_RED}$1${COL_RST}"; }
yellow() { print "${COL_YLW}$1${COL_RST}"; }
cyan() { print "${COL_CYN}$1${COL_RST}"; }

# Wrapper functions that respect loglevel for console output. They call `log`
# (file output) only if the message is emitted (i.e., loglevel allows it).
info() {
	if __kam_should_emit INFO; then
		green "[info] $1"
		log "INFO: $1"
	fi
}

warn() {
	if __kam_should_emit WARN; then
		yellow "[warn] $1"
		log "WARN: $1"
	fi
}

error() {
	# Always show errors to console, but still respect loglevel check for consistency
	red "[error] $1"
	log "ERROR: $1"
}

success() {
	if __kam_should_emit INFO; then
		green "[done] $1"
		log "SUCCESS: $1"
	fi
}

debug() {
	# Backwards compat: KAM_DEBUG=1 turns on debug
	if __kam_should_emit DEBUG; then
		cyan "[DEBUG] $1"
		log "[DEBUG] $1"
	fi
}

# ---------------------------------------------------------------------------
# log(): append lines to the log file, supports options:
#   -w/--overwrite, -f/--file <path>, -r/--rotate <size>, --rotate-keep <count>
# Behavior follows previous implementation: timestamp + cleaned (ANSI-stripped) line.
# ---------------------------------------------------------------------------
log() {
	: "${MODDIR:=${0%/*}}"
	: "${KAM_LOGFILE:=${MODDIR}/.log/kam.log}"
	_logfile="${KAM_LOGFILE}"
	_mode="append"
	_rotate_opt=""
	_rotate_keep="${KAM_LOG_ROTATE_KEEP:-1}"

	while [ $# -gt 0 ]; do
		case "$1" in
		-w | --overwrite)
			_mode="overwrite"
			shift
			;;
		-f | --file)
			_logfile="$2"
			shift 2
			;;
		-r | --rotate | --rotate-size)
			_rotate_opt="$2"
			shift 2
			;;
		-k | --rotate-keep)
			_rotate_keep="$2"
			shift 2
			;;
		*) break ;;
		esac
	done

	if [ -z "${_rotate_opt:-}" ] && [ -n "${KAM_LOG_ROTATE_SIZE:-}" ]; then
		_rotate_opt="${KAM_LOG_ROTATE_SIZE}"
	fi

	if [ "$_mode" = "overwrite" ]; then
		: >"$_logfile" 2>/dev/null || true
	fi

	_maybe_rotate() {
		if [ -z "${_rotate_opt:-}" ]; then
			return 0
		fi
		if ! command -v logrotate_file >/dev/null 2>&1; then
			import logrotate >/dev/null 2>&1 || true
		fi
		if command -v logrotate_file >/dev/null 2>&1; then
			logrotate_file --size "$_rotate_opt" --keep "$_rotate_keep" "$_logfile" >/dev/null 2>&1 || true
		fi
	}

	_write_line() {
		_line="$1"
		_clean=$(printf '%s' "$_line" | tr -d '\033' | sed 's/\[[0-9;]*m//g')
		_maybe_rotate
		printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_clean" >>"$_logfile"
	}

	if [ $# -gt 0 ]; then
		_msg="$*"
		_write_line "$_msg"
	else
		if [ -t 0 ]; then
			: # no piped stdin
		else
			while IFS= read -r _ln || [ -n "$_ln" ]; do
				_write_line "$_ln"
			done
		fi
	fi

	unset _maybe_rotate _write_line _line _clean _msg _ln _rotate_opt _rotate_keep
}
