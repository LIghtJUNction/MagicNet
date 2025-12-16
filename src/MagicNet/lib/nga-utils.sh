#====================================================================================================
# Copyright (C) 2016-present ShIroRRen <http://shiror.ren>.                                         =
#                                                                                                   =
# Part of the NGA project.                                                                          =
# Licensed under the F2DLPR License.                                                                =
#                                                                                                   =
# YOU MAY NOT USE THIS FILE EXCEPT IN COMPLIANCE WITH THE LICENSE.                                  =
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,                                   =
# unless required by applicable law or agreed to in writing.                                        =
#                                                                                                   =
# For the NGA project, visit: <http://app.niggergo.work>.                                           =
# For the F2DLPR License terms and conditions, visit: <http://license.fileto.download>.             =
#====================================================================================================

# shellcheck shell=ash

alias del=rm # for rm check

run2null() { "$@" >/dev/null 2>&1; }

run22null() { "$@" 2>/dev/null; }

until_key() {
	local eventCode
	while :; do
		eventCode=$(getevent -qlc 1 | awk '{if ($2=="EV_KEY" && $4=="DOWN") {print $3; exit}}')
		case "$eventCode" in
			KEY_VOLUMEUP)
				echo -n up
				return
				;;
			KEY_VOLUMEDOWN)
				echo -n down
				return
				;;
			KEY_POWER)
				echo -n power
				return
				;;
			KEY_MUTE)
				echo -n mute
				return
				;;
			KEY_F[1-9] | KEY_F1[0-9] | KEY_F2[0-4])
				echo -n "$eventCode" | sed 's/KEY_F/f/g'
				return
				;;
		esac
	done
}

until_key_any() { run2null until_key; }

until_key_up_down() {
	local key
	while :; do
		key=$(until_key)
		case "$key" in
			up | down)
				echo -n "$key"
				return
				;;
		esac
	done
}

until_key_up_down_power() {
	local key
	while :; do
		key=$(until_key)
		case "$key" in
			up | down | power)
				echo -n "$key"
				return
				;;
		esac
	done
}

until_key_up() { while :; do [ "$(until_key)" = up ] && return; done; }

until_key_down() { while :; do [ "$(until_key)" = down ] && return; done; }

until_key_power() { while :; do [ "$(until_key)" = power ] && return; done; }

goto_url() {
	[ -n "$1" ] || return
	run2null am start -a android.intent.action.VIEW -d "$1"
}

goto_app() {
	[ -n "$1" ] || return
	run2null am start "$1"
}

str_eq() {
	local str="$1"
	shift
	for target in "$@"; do [ "$target" = "$str" ] && return; done
	return 1
}

pure_print() {
	{ run2null type ui_print && ui_print "$1"; } || {
		# shellcheck disable=SC3036
		[ -z "$OUTFD" ] && echo -e "$1" || echo -e "ui_print $1\nui_print" >>"/proc/self/fd/$OUTFD"
	}
}

nga_abort() {
	{ run2null type abort && abort "⚠️ $1"; } || {
		pure_print "⚠️ $1"
		[ -n "$TMPDIR" ] && del -rf "$TMPDIR"
		exit 1
	}
}

nga_print() { pure_print "> $1"; }

# shellcheck disable=SC2120
newline() { for _ in $(seq 1 "${1:-1}"); do pure_print ''; done; }

print_lines() { for line in "$@"; do echo "$line"; done; }

get_work_dir() { dirname "$(readlink -f "$1")"; }

set_dir_perm() { find "$@" -type d -exec chmod 0755 {} +; }

set_system_file() { chcon -R u:object_r:system_file:s0 "$@"; }

pre_bin() {
	local bin="$1"
	[ -f "$bin" ] || return
	chmod a+x "$bin"
}

pre_bins() { for bin in "$@"; do pre_bin "$bin"; done; }

run_bin() {
	local bin="$1"
	[ -f "$bin" ] || return
	pre_bin "$bin"
	shift
	"$bin" "$@"
}

nohup_bin() {
	local bin="$1"
	[ -f "$bin" ] || return
	pre_bin "$bin"
	shift
	run2null nohup "$bin" "$@" &
}

get_arch() {
	case "$(getprop ro.product.cpu.abi)" in
		arm64-v8a) echo -n arm64 ;;
		armeabi-v7a) echo -n arm ;;
		armeabi) echo -n arm ;;
		x86_64) echo -n x86_64 ;;
		x86) echo -n x86 ;;
		riscv64) echo -n riscv64 ;;
		mips64) echo -n mips64 ;;
		mips) echo -n mips ;;
		*) return 1 ;;
	esac
}

get_app_lib() {
	local packageName="$1"
	local libName="$2"
	local apkDir
	apkDir="$(run22null pm path "$packageName" | head -n 1 | sed 's/^package://;s/base.apk$//')"
	[ -n "$apkDir" ] || return
	local libDir="${apkDir}lib"
	[ -d "$libDir" ] || return
	local arch
	arch="$(get_arch)"
	{ [ -n "$arch" ] && [ -d "$libDir/$arch" ] && {
		[ -f "$libDir/$arch/lib$libName.so" ] && echo -n "$libDir/$arch/lib$libName.so"
		return
	}; } || {
		arch="$(basename "$(find "$libDir" -mindepth 1 -maxdepth 1 -type d | head -n 1)")"
		[ -n "$arch" ] && [ -d "$libDir/$arch" ] && {
			[ -f "$libDir/$arch/lib$libName.so" ] && echo -n "$libDir/$arch/lib$libName.so"
			return
		}
	}
	return 1
}

# shellcheck disable=SC2120
until_boot() {
	run2null resetprop -w sys.boot_completed 0
	[ -z "$1" ] || sleep "$1"
}

until_unlock() {
	until_boot
	until [ -d /sdcard/Android ]; do sleep 1; done
	[ -z "$1" ] || sleep "$1"
}

is_ssu() { [ "$SSU" = true ]; }
is_shirosu() { [ "$SSU" = true ]; }

is_ksu() { [ "$KSU" = true ]; }
is_kernelsu() { [ "$KSU" = true ]; }

is_ap() { [ "$APATCH" = true ]; }
is_apatch() { [ "$APATCH" = true ]; }

not_magisk() { is_ssu || is_ksu || is_ap; }

is_magisk() { ! not_magisk; }

nga_install_module() {
	local zipPath="$1"

	run2null which magisk && {
		magisk --install-module "$zipPath"
		return
	}
	for us in apd ksud; do
		{ run2null which $us && {
			$us module install "$zipPath"
			return
		}; } || { [ -f /data/adb/$us ] && {
			/data/adb/$us module install "$zipPath"
			return
		}; }
	done
}

nga_install_modules() { for zipPath in "$@"; do nga_install_module "$zipPath"; done; }

magisk_run_completed() {
	is_magisk && { [ -f "$1/boot-completed.sh" ] && {
		until_boot
		# shellcheck disable=SC1091
		. "$1/boot-completed.sh"
		exit
	}; }
}

get_target_bin() {
	[ -z "$MODPATH" ] && nga_abort 'Value "MODPATH" does not exist!'
	[ -z "$ARCH" ] && nga_abort 'Value "ARCH" does not exist!'

	local binName="$1"
	{ [ -z "$2" ] && local targetArch="$ARCH"; } || local targetArch="$2"
	mv -f "$MODPATH/bin/$binName/$targetArch.elf" "$MODPATH/$binName" || nga_abort "Arch \"$targetArch\" is not supported!"
	pre_bin "$MODPATH/$binName"
}

get_target_bins() { for binName in "$@"; do get_target_bin "$binName"; done; }

# 此函数较为特殊，用于批量安装模块功能，请完整阅读并理解此函数的代码后再使用此函数
# shellcheck disable=SC2154
run_install_list() {
	local func_head="$1"
	local func_num="$2"

	newline
	nga_print '通过按压音量加键切换安装内容，通过按压音量减键确定安装内容'
	newline

	for num in $(seq 1 "$func_num"); do
		eval "$(eval "$func_head$num" | {
			local type=1
			while IFS= read -r line; do
				[ -z "$line" ] && continue
				case "$type" in
					1) echo "local target_func_head=\"$line\"" ;;
					2) echo "local opt_name=\"$line\"" ;;
					3) echo "local opt_num=\"$line\"" ;;
					4) echo "local cancel=\"$line\"" ;;
					*) echo "local opt_name_$((type - 4))=\"$line\"" ;;
				esac
				type=$((type + 1))
			done
		})"
		newline
		nga_print "抉择$num: $opt_name"
		newline
		[ "$cancel" = true ] && nga_print '内容0: 取消此抉择'
		for index_num in $(seq 1 "$opt_num"); do
			nga_print "内容$index_num: $(eval "echo -n \"\$opt_name_$index_num\"")"
		done
		newline
		local target_opt
		{ [ "$cancel" = true ] && {
			target_opt=0
			nga_print '当前选择内容: 取消此抉择'
		}; } || {
			target_opt=1
			nga_print '当前选择内容: 内容1'
		}
		while :; do
			{ [ "$(until_key_up_down)" = down ] && {
				newline
				[ "$target_opt" -eq 0 ] && {
					nga_print '已确定选择内容: 取消此抉择'
					:
				} || {
					nga_print "已确定选择内容: 内容$target_opt"
					eval "$target_func_head$target_opt"
				}
				newline
				break
			}; } || {
				target_opt=$((target_opt + 1))
				[ $target_opt -gt "$opt_num" ] && {
					[ "$cancel" = true ] && {
						target_opt=0
						nga_print '当前选择内容: 取消此抉择'
						continue
					} || target_opt=1
				}
				nga_print "当前选择内容: 内容$target_opt"
			}
		done
	done
}

nga_install_init() {
	[ -z "$MODPATH" ] && nga_abort 'Value "MODPATH" does not exist!'

	# For Latest File
	[ "$1" = official ] && {
		nga_print 'Official Website: https://latestfile.zip'
		shift
	}

	# Check files
	local hashListFile="$MODPATH/hashList.dat"
	[ -f "$hashListFile" ] || nga_abort 'File "hashList.dat" does not exist!'
	local hashList
	hashList="$(zcat "$hashListFile" | tr a-zA-Z A-Za-z | base64 -d)"
	find "$MODPATH/" -type f -not -path '*META-INF*' -not -name hashList.dat | while IFS= read -r file; do
		str_eq "${file#"$MODPATH/"}" "$@" && continue
		[ "$(echo -n "$hashList" | grep -E " ${file#"$MODPATH/"}$" | cut -d\  -f1)" = "$(md5sum "$file" | cut -d\  -f1)$(sha1sum "$file" | cut -d\  -f1)" ] || nga_abort "Failed to verify file \"${file#"$MODPATH/"}\"!"
	done
	del -f "$hashListFile"
}

nga_install_done() {
	[ -z "$MODPATH" ] && nga_abort 'Value "MODPATH" does not exist!'
	[ -z "$ARCH" ] && nga_abort 'Value "ARCH" does not exist!'

	# Clean bins
	[ -d "$MODPATH/bin" ] && del -rf "$MODPATH/bin"

	[ -d "$MODPATH/system" ] && {
		# For overlyfs
		set_dir_perm "$MODPATH/system"
		set_system_file "$MODPATH/system"

		[ -d "$MODPATH/system/vendor/odm" ] && mv -f "$MODPATH/system/vendor/odm" "$MODPATH/system/odm"
	}

	# Clean zygisk libs
	[ -d "$MODPATH/zygisk" ] && {
		case "$ARCH" in
			arm64) find "$MODPATH/zygisk" \( -name "mips*.so" -o -name "riscv*.so" -o -name "x*.so" \) -delete ;;
			arm) find "$MODPATH/zygisk" \( -name "mips*.so" -o -name "riscv*.so" -o -name "x*.so" -o -name "*64*.so" \) -delete ;;
			x64) find "$MODPATH/zygisk" \( -name "mips*.so" -o -name "riscv*.so" \) -delete ;;
			x86) find "$MODPATH/zygisk" \( -name "mips*.so" -o -name "riscv*.so" -o -name "*64*.so" \) -delete ;;
			riscv64) find "$MODPATH/zygisk" \( -name "mips*.so" -o -name "arm*.so" -o -name "x*.so" \) -delete ;;
			mips64) find "$MODPATH/zygisk" \( -name "riscv*.so" -o -name "arm*.so" -o -name "x*.so" \) -delete ;;
			mips) find "$MODPATH/zygisk" \( -name "riscv*.so" -o -name "arm*.so" -o -name "x*.so" -o -name "*64*.so" \) -delete ;;
		esac
	}

	# Clean useless files (just simply)
	# Keep license, changelog for ShiroSU
	for file in README NOTICE CONTRIBUTING SECURITY; do
		for suffix in '' '.txt' '.md' '.mkd'; do
			[ -f "$MODPATH/$file$suffix" ] && del -rf "$MODPATH/$file$suffix"
		done
	done
}

[ -z "$BOOTMODE" ] && { { run2null pgrep zygote && export BOOTMODE=true; } || export BOOTMODE=false; }

[ -z "$ARCH" ] && {
	ABI="$(getprop ro.product.cpu.abi)"
	case "$ABI" in
		arm64-v8a)
			export ARCH=arm64
			export ABI32=armeabi-v7a
			export IS64BIT=true
			;;
		armeabi-v7a)
			export ARCH=arm
			export ABI32=armeabi-v7a
			export IS64BIT=false
			;;
		armeabi)
			export ARCH=arm
			export ABI32=armeabi
			export IS64BIT=false
			;;
		x86_64)
			export ARCH=x64
			export ABI32=x86
			export IS64BIT=true
			;;
		x86)
			export ARCH=x86
			export ABI32=x86
			export IS64BIT=false
			;;
		riscv64)
			export ARCH=riscv64
			export ABI32=riscv32
			export IS64BIT=true
			;;
		mips64)
			export ARCH=mips64
			export ABI32=mips
			export IS64BIT=true
			;;
		mips)
			export ARCH=mips
			export ABI32=mips
			export IS64BIT=false
			;;
	esac
	export ABI
}

[ -n "$MAGISK_VER_CODE" ] \
	&& is_magisk && [ "$MAGISK_VER_CODE" -lt 27008 ] \
	&& pure_print '⚠️ WARNING!!! OLD VERSION OF MAGISK DETECTED!'

[ "$KSU_SUKISU" = true ] && pure_print '⚠️ WARNING!!! SUKISU DETECTED!'

: Okay!
