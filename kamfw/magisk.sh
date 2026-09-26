# shellcheck shell=ash
#
kam_magisk_prepare_installer() {
	# Only build/package phases should call this. Runtime imports must not mutate
	# an installed module under /data/adb/modules.
	if [ -f "${MODDIR}/boot-completed.sh" ]; then
		mv "${MODDIR}/boot-completed.sh" "${MODDIR}/service.sh"
	fi

	if [ ! -f "${MODDIR}/META-INF/com/google/android/updater-script" ]; then
		mkdir -p "${MODDIR}/META-INF/com/google/android"
		printf '%s\n' "#MAGISK" >"${MODDIR}/META-INF/com/google/android/updater-script"
	fi

	if [ ! -f "${MODDIR}/META-INF/com/google/android/update-binary" ]; then
		mkdir -p "${MODDIR}/META-INF/com/google/android"
	cat <<EOF >"${MODDIR}/META-INF/com/google/android/update-binary"
#!/sbin/sh

#################
# Initialization
#################

umask 022

# NOTE: do not define ui_print here; util_functions.sh will provide it.
require_new_magisk() {
# Fallback: before util_functions.sh is sourced, we may not have ui_print.
# Must not use echo; use stderr.
printf '%s\n' "*******************************" >&2
printf '%s\n' " Please install Magisk v20.4+! " >&2
printf '%s\n' "*******************************" >&2
exit 1
}

#########################
# Load util_functions.sh
#########################

OUTFD=$2
ZIPFILE=$3

mount /data 2>/dev/null

[ -f /data/adb/magisk/util_functions.sh ] || require_new_magisk
. /data/adb/magisk/util_functions.sh
[ $MAGISK_VER_CODE -lt 20400 ] && require_new_magisk

install_module
exit 0
EOF
	fi
}

# Magisk 管理器：安装模块的实现
install_module() {
	_im_zip="$1"
	[ -f "$_im_zip" ] || return 1

	magisk --install-module "$_im_zip"

	unset _im_zip
}
