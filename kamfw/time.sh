# shellcheck shell=ash
##########################################################################################
# KAM Framework - Time & Format Utility Library
# Optimized for ash (No 'local' support)
##########################################################################################

# --- Internal Helper: Get Current Epoch ---
# Returns milliseconds if supported, otherwise seconds
_kam_get_now() {
	_kn_val=$(date +%s%N 2>/dev/null)
	case "$_kn_val" in
	*N*) date +%s ;;
	*) echo "$((_kn_val / 1000000))" ;;
	esac
}

# =============================================================================
# 1. Timer Functions (Key-Value Based)
# =============================================================================

# timer_start <key>
timer_start() {
	_t_key=$1
	[ -z "$_t_key" ] && return 1
	_t_start_val=$(_kam_get_now)
	eval "export KAM_T_${_t_key}=\"$_t_start_val\""
}

# timer_get_interval <key>
# Returns delta in ms (or seconds depending on system support)
timer_get_interval() {
	_t_key=$1
	eval "_t_s_time=\$KAM_T_${_t_key}"
	if [ -z "$_t_s_time" ]; then
		echo "0"
		return 1
	fi
	_t_e_time=$(_kam_get_now)
	echo "$((_t_e_time - _t_s_time))"
}

# timer_stop <key>
timer_stop() {
	_t_key=$1
	_t_diff=$(timer_get_interval "$_t_key")
	echo "$_t_diff"
	eval "unset KAM_T_${_t_key}"
}

# =============================================================================
# 2. String Format Functions (Preset Styles)
# =============================================================================

# ISO 8601: 2025-12-28T02:31:00
get_time_iso() {
	date +"%Y-%m-%dT%H:%M:%S"
}

# Log Style: [2025-12-28 02:31:00]
get_time_log() {
	date +"[%Y-%m-%d %H:%M:%S]"
}

# Filename Safe: 20251228_023100
get_time_fixed() {
	date +"%Y%m%d_%H%M%S"
}

# Short Human: Dec 28, 02:31
get_time_short() {
	date +"%b %d, %H:%M"
}

# HTTP Header Style: Sun, 28 Dec 2025 02:31:00 GMT
get_time_http() {
	date -u +"%a, %d %b %Y %H:%M:%S GMT"
}

# =============================================================================
# 3. Conversion & Calculation
# =============================================================================

# format_duration <seconds>
# Input: 3661 -> Output: 01:01:01
format_duration() {
	_d_sec=$1
	[ -z "$_d_sec" ] && _d_sec=0

	_d_h=$((_d_sec / 3600))
	_d_m=$(((_d_sec % 3600) / 60))
	_d_s=$((_d_sec % 60))

	# Manual padding for ash compatibility
	[ "${#_d_h}" -lt 2 ] && _d_h="0$_d_h"
	[ "${#_d_m}" -lt 2 ] && _d_m="0$_d_m"
	[ "${#_d_s}" -lt 2 ] && _d_s="0$_d_s"

	echo "${_d_h}:${_d_m}:${_d_s}"
}

# timestamp_to_readable <unix_timestamp> [format]
timestamp_to_readable() {
	_tr_ts=$1
	_tr_fmt=${2:-"%Y-%m-%d %H:%M:%S"}
	# Try Busybox/Linux date first, then fallback to BSD/Unix
	date -d "@$_tr_ts" +"$_tr_fmt" 2>/dev/null || date -r "$_tr_ts" +"$_tr_fmt"
}

# get_greeting
# Returns Morning/Afternoon/Evening based on system clock
get_greeting() {
	_g_hour=$(date +"%H")
	_g_hour=${_g_hour#0} # Strip leading zero to avoid octal error

	if [ "$_g_hour" -ge 5 ] && [ "$_g_hour" -lt 12 ]; then
		echo "Good Morning"
	elif [ "$_g_hour" -ge 12 ] && [ "$_g_hour" -lt 18 ]; then
		echo "Good Afternoon"
	else
		echo "Good Evening"
	fi
}
