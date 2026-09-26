# shellcheck shell=ash
# prop.sh
#
# Property helpers (ash-compatible; DO NOT use 'local' to remain ash-safe)
#
# Usage:
#   import prop
#   register_uninstall_cmd '<cmd>' [<modpath>]
#   delprop_if_exist <PROP_NAME>
#   persistprop <PROP_NAME> <NEW_VALUE> [<modpath>]
#   resetprop_if_diff <PROP_NAME> <EXPECTED_VALUE>
#   resetprop_if_match <PROP_NAME> <CONTAINS> <NEW_VALUE>
#   resetprop_hexpatch [-f|--force] <PROP_NAME> <NEW_VALUE>    # advanced, dangerous
#
# Notes:
# - All user-visible messages use i18n (set_i18n).
# - Helpers try to be conservative and non-destructive.
# - `persistprop` writes rollback commands into <modpath>/uninstall.sh (creates it if needed).
# - `resetprop_hexpatch` is a best-effort fallback for old environments; use with caution.
#
# Quick manual test:
#   export MODPATH=/tmp/modtest
#   mkdir -p "$MODPATH"
#   import prop
#   persistprop test.prop 1 "$MODPATH"
#   delprop_if_exist test.prop
#   resetprop_if_diff test.prop 2
#   resetprop_if_match test.prop old 3
#
# i18n keys added:
#   UNINSTALL_CMD_ADDED, UNINSTALL_SCRIPT_CREATED,
#   DELPROP_REMOVED, PERSISTPROP_ADDED, PERSISTPROP_SET, PERSISTPROP_NO_MODPATH,
#   RESETPROP_HEXPATCH_TOOLS_MISSING, RESETPROP_HEXPATCH_FAILED, RESETPROP_HEXPATCH_OK
#

set_i18n "UNINSTALL_CMD_ADDED" \
	"zh" "已加入卸载命令：\\$_1" \
	"en" "Added uninstall command: \\$_1"

set_i18n "UNINSTALL_SCRIPT_CREATED" \
	"zh" "已创建卸载脚本：\\$_1" \
	"en" "Created uninstall script: \\$_1"

set_i18n "DELPROP_REMOVED" \
	"zh" "已删除属性：\\$_1" \
	"en" "Deleted property: \\$_1"

set_i18n "PERSISTPROP_ADDED" \
	"zh" "已记录属性回滚到卸载脚本：\\$_1" \
	"en" "Recorded property rollback in uninstall script: \\$_1"

set_i18n "PERSISTPROP_SET" \
	"zh" "已设置属性：\\$_1" \
	"en" "Set property: \\$_1"

set_i18n "PERSISTPROP_NO_MODPATH" \
	"zh" "未提供 MODPATH，无法记录卸载回滚" \
	"en" "MODPATH not provided; cannot record uninstall rollback"

set_i18n "RESETPROP_HEXPATCH_TOOLS_MISSING" \
	"zh" "缺少实现 hexpatch 所需工具（strings/od/dd），无法执行" \
	"en" "Required tools for hexpatch missing (strings/od/dd); cannot execute"

set_i18n "RESETPROP_HEXPATCH_FAILED" \
	"zh" "hexpatch 失败：\\$_1" \
	"en" "Hexpatch failed: \\$_1"

set_i18n "RESETPROP_HEXPATCH_OK" \
	"zh" "hexpatch 成功应用于属性：\\$_1" \
	"en" "Hexpatch successfully applied for property: \\$_1"

# -----------------------------------------------------------------------------
# Return the uninstall script path for a module directory.
# -----------------------------------------------------------------------------
kamfw_uninstall_script_path() {
	_kamfw_uninstall_mp="${1:-${MODPATH:-}}"
	[ -n "$_kamfw_uninstall_mp" ] || return 1
	printf '%s\n' "$_kamfw_uninstall_mp/uninstall.sh"
	unset _kamfw_uninstall_mp
}

kamfw_ensure_uninstall_script() {
	_kamfw_uninstall_mp="${1:-${MODPATH:-}}"
	[ -n "$_kamfw_uninstall_mp" ] || {
		warn "$(i18n 'PERSISTPROP_NO_MODPATH' 2>/dev/null || echo 'MODPATH not set')"
		return 1
	}

	_kamfw_uninstall_script="$(kamfw_uninstall_script_path "$_kamfw_uninstall_mp")" || return 1
	if [ ! -f "$_kamfw_uninstall_script" ]; then
		printf '%s\n' "#!/system/bin/sh" >"$_kamfw_uninstall_script" || return 1
		chmod 755 "$_kamfw_uninstall_script" 2>/dev/null || true
		info "$(i18n 'UNINSTALL_SCRIPT_CREATED' 2>/dev/null | t "$_kamfw_uninstall_script" 2>/dev/null || printf 'Created uninstall: %s' "$_kamfw_uninstall_script")"
	fi
	unset _kamfw_uninstall_mp _kamfw_uninstall_script
}

# Append a command to <modpath>/uninstall.sh if not already present.
# -----------------------------------------------------------------------------
register_uninstall_cmd() {
	_cmd="$1"
	_mp="${2:-${MODPATH:-}}"

	[ -n "$_cmd" ] || return 0
	kamfw_ensure_uninstall_script "$_mp" || return 1
	_un="$(kamfw_uninstall_script_path "$_mp")" || return 1

	# Deduplicate lines (literal match)
	if grep -F -- "$_cmd" "$_un" >/dev/null 2>&1; then
		unset _cmd _mp _un
		return 0
	fi

	printf '%s\n' "$_cmd" >>"$_un" || return 1
	info "$(i18n 'UNINSTALL_CMD_ADDED' 2>/dev/null | t "$_cmd" 2>/dev/null || printf 'Added uninstall command: %s' "$_cmd")"
	unset _cmd _mp _un
	return 0
}

# -----------------------------------------------------------------------------
# Remove property if exists (wrapper)
# -----------------------------------------------------------------------------
delprop_if_exist() {
	_name="$1"
	[ -n "$_name" ] || return 0

	_cur="$(resetprop "$_name" 2>/dev/null || true)"
	if [ -n "$_cur" ]; then
		resetprop --delete "$_name" 2>/dev/null || true
		info "$(i18n 'DELPROP_REMOVED' 2>/dev/null | t "$_name" 2>/dev/null || printf 'Deleted property: %s' "$_name")"
	fi
}

# -----------------------------------------------------------------------------
# Persist property change: record rollback in uninstall.sh and then set prop
# Usage: persistprop NAME NEWVALUE [MODPATH]
# -----------------------------------------------------------------------------
persistprop() {
	_name="$1"
	_new="$2"
	_mp="${3:-${MODPATH:-}}"

	[ -n "$_name" ] || return 1
	[ -n "$_mp" ] || {
		warn "$(i18n 'PERSISTPROP_NO_MODPATH' 2>/dev/null || echo 'MODPATH not set')"
		return 1
	}

	_cur="$(resetprop "$_name" 2>/dev/null || true)"

	kamfw_ensure_uninstall_script "$_mp" || return 1
	_un="$(kamfw_uninstall_script_path "$_mp")" || return 1

	# Avoid duplicating rollback entries
	if ! grep -F -- "$_name" "$_un" >/dev/null 2>&1; then
		if [ -n "$_cur" ]; then
			# Record how to restore the previous value
			_cmd="resetprop -n -p \"$_name\" \"$_cur\""
			register_uninstall_cmd "$_cmd" "$_mp" || true
		else
			_cmd="resetprop -p --delete \"$_name\""
			register_uninstall_cmd "$_cmd" "$_mp" || true
		fi
		info "$(i18n 'PERSISTPROP_ADDED' 2>/dev/null | t "$_name" 2>/dev/null || printf 'Recorded prop rollback: %s' "$_name")"
	fi

	# Now set the property
	resetprop -n -p "$_name" "$_new" 2>/dev/null || true
	info "$(i18n 'PERSISTPROP_SET' 2>/dev/null | t "$_name" 2>/dev/null || printf 'Set property: %s' "$_name")"
	unset _name _new _mp _cur _cmd _un
	return 0
}

# -----------------------------------------------------------------------------
# resetprop_if_diff <name> <expected>
# Set prop to expected only when current value differs (or is empty)
# -----------------------------------------------------------------------------
resetprop_if_diff() {
	_name="$1"
	_expected="$2"
	[ -n "$_name" ] || return 1

	_cur="$(resetprop "$_name" 2>/dev/null || true)"
	if [ -z "$_cur" ] || [ "$_cur" != "$_expected" ]; then
		resetprop -n "$_name" "$_expected" 2>/dev/null || return 1
	fi
	return 0
}

# -----------------------------------------------------------------------------
# resetprop_if_match <name> <contains> <newvalue>
# If current value contains <contains> substring, set it to <newvalue>
# -----------------------------------------------------------------------------
resetprop_if_match() {
	_name="$1"
	_contains="$2"
	_value="$3"
	[ -n "$_name" ] || return 1

	_cur="$(resetprop "$_name" 2>/dev/null || true)"
	case "$_cur" in
	*"$_contains"*) resetprop -n "$_name" "$_value" 2>/dev/null || return 1 ;;
	*) return 0 ;;
	esac
	return 0
}

# -----------------------------------------------------------------------------
# resetprop_hexpatch [-f|--force] <name> <newvalue>
# Low-level fallback that directly patches the properties blob. Dangerous.
# Returns 0 on success, non-zero otherwise.
# -----------------------------------------------------------------------------
resetprop_hexpatch() {
	_force=0
	case "$1" in
	-f | --force)
		_force=1
		shift
		;;
	esac

	_name="$1"
	_new="$2"
	[ -n "$_name" -a -n "$_new" ] || return 1

	# Check required tools
	if ! command -v strings >/dev/null 2>&1 || ! command -v od >/dev/null 2>&1 || ! command -v dd >/dev/null 2>&1; then
		abort "$(i18n 'RESETPROP_HEXPATCH_TOOLS_MISSING' 2>/dev/null || echo 'Required tools missing')"
		return 1
	fi

	# Identify prop file (device-specific)
	if [ -f /dev/__properties__ ]; then
		_propfile="/dev/__properties__"
	else
		_id="$(resetprop -Z "$_name" 2>/dev/null || true)"
		[ -n "$_id" ] || return 2
		_propfile="/dev/__properties__/${_id}"
	fi
	[ -f "$_propfile" ] || return 3

	# Find offset of property name
	_matches="$(strings -t d "$_propfile" 2>/dev/null | grep -F "$_name" || true)"
	if [ -z "$_matches" ]; then
		[ "$_force" -eq 1 ] || return 4
	fi

	# Extract decimal offset (use first match)
	_off="$(echo "$_matches" | head -n1 | awk '{print $1}' 2>/dev/null || true)"
	case "$_off" in
	'' | *[!0-9]*) return 5 ;;
	esac

	# Compose new hex payload (value length byte + value bytes + padding)
	_len=${#_new}
	if [ "$_len" -gt 92 ]; then
		# too long for safe inline patching
		return 6
	fi

	_hexval="$(printf '%s' "$_new" | od -A n -t x1 -v 2>/dev/null | tr -d ' \n')"
	# 2-byte counter (we don't change) + flags + length byte + value + padding to 92 bytes
	_len_hex=$(printf '%02x' "$_len")
	_padbytes=$((92 - _len))
	_padhex="$(printf '%0.s00' $(seq 1 "$_padbytes" 2>/dev/null || printf ''))"

	_payload="${_len_hex}${_hexval}${_padhex}"

	# Apply patch carefully: write at (offset - 96) position like original script
	_seek=$((_off - 96))
	if [ "$_seek" -lt 0 ]; then
		return 7
	fi

	# Perform writes (best-effort; may require root)
	# Write two zero bytes at offset-96 then payload at offset-93 per original logic
	printf '\x00\x00' | dd of="$_propfile" obs=1 count=2 seek="$((_seek))" conv=notrunc 2>/dev/null || return 8
	# Convert hex string to \x?? format and use printf -n to write
	_escaped="$(printf "%s" "$_payload" | sed -e 's/.\{2\}/\\\\x&/g' -e 's/^/\\\\x/; s/\\\\x$//')"
	# Use printf to generate binary and dd to write
	printf "$_escaped" | sed -n '1p' | dd of="$_propfile" obs=1 count=93 seek="$((_seek + 3))" conv=notrunc 2>/dev/null || {
		warn "$(i18n 'RESETPROP_HEXPATCH_FAILED' 2>/dev/null | t "$_name" 2>/dev/null || printf 'Hexpatch failed: %s' "$_name")"
		return 9
	}

	info "$(i18n 'RESETPROP_HEXPATCH_OK' 2>/dev/null | t "$_name" 2>/dev/null || printf 'Hexpatch applied: %s' "$_name")"
	return 0
}
