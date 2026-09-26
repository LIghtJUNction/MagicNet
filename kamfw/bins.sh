# shellcheck shell=ash
#
# bins.sh
#
# Small bin-related helpers for kamfw
#
# Exports:
#   prune_zygisk_for_arch <arch> [<zygisk_dir>] [--dry-run|-n]
#
# Purpose:
#   Remove zygisk .so files that are incompatible with the given target arch.
#   Typical usage in install-time cleanup:
#       prune_zygisk_for_arch "$ARCH" "$MODPATH/zygisk"
#
# Notes:
# - All user-visible messages use i18n keys.
# - The function is conservative and matches files by explicit name patterns.
# - Non-interactive friendly (no prompts). A dry-run option lists candidates.
#
# Quick manual test:
# 1) tmp=$(mktemp -d); mkdir -p "$tmp/zygisk"; touch "$tmp/zygisk/x86_lib.so" "$tmp/zygisk/arm64_lib.so"
# 2) . "$MODDIR/lib/kamfw/.kamfwrc" && import bins
# 3) prune_zygisk_for_arch arm64 "$tmp/zygisk" --dry-run
# 4) prune_zygisk_for_arch arm64 "$tmp/zygisk"
#

set_i18n "PRUNE_ZYGISK_START" \
	"zh" '开始清理 zygisk，架构: $_1 目录: $_2' \
	"en" 'Pruning zygisk for arch $_1 in $_2'

set_i18n "PRUNE_ZYGISK_NO_DIR" \
	"zh" "目录不存在或不可访问，跳过：$_1" \
	"en" "Zygisk directory not found or not accessible, skipping: $_1"

set_i18n "PRUNE_ZYGISK_NO_FILES" \
	"zh" '未发现需要删除的 zygisk 文件（架构：$_1）' \
	"en" 'No zygisk files matched removal patterns for arch $_1'

set_i18n "PRUNE_ZYGISK_WOULD_REMOVE" \
	"zh" '（干跑）将删除：$_1' \
	"en" 'Would remove: $_1'

set_i18n "PRUNE_ZYGISK_REMOVED" \
	"zh" '已删除：$_1' \
	"en" 'Removed: $_1'

set_i18n "PRUNE_ZYGISK_REMOVE_FAILED" \
	"zh" '删除失败：$_1' \
	"en" 'Failed to remove: $_1'

set_i18n "PRUNE_ZYGISK_DRY_DONE" \
	"zh" '干跑完成：$_1 个匹配项' \
	"en" 'Dry run: $_1 files match removal patterns'

set_i18n "PRUNE_ZYGISK_DONE" \
	"zh" '清理完成：已删除 $_1 个文件' \
	"en" 'Prune complete: removed $_1 files'

set_i18n "PRUNE_ZYGISK_UNKNOWN_ARCH" \
	"zh" '未知架构：$_1，跳过清理' \
	"en" 'Unknown arch: $_1; skipping prune'

set_i18n "PRUNE_ZYGISK_FIND_MISSING" \
	"zh" "缺少必需工具：find，无法执行清理" \
	"en" "Required command 'find' not found; cannot prune zygisk libs"

# prune_zygisk_for_arch <arch> [<zygisk_dir>] [--dry-run|-n]
prune_zygisk_for_arch() {
	arch="${1:-${ARCH:-}}"
	zdir="${2:-${MODPATH:-}/zygisk}"
	shift 2

	dryrun=false
	while [ $# -gt 0 ]; do
		case "$1" in
		--dry-run | -n) dryrun=true ;;
		*) ;; # ignore unknown args
		esac
		shift
	done

	[ -n "$arch" ] || abort "$(i18n 'PRUNE_ZYGISK_UNKNOWN_ARCH' 2>/dev/null | t '' 2>/dev/null || printf 'prune_zygisk_for_arch: arch missing')"

	if [ ! -d "$zdir" ]; then
		info "$(i18n 'PRUNE_ZYGISK_NO_DIR' 2>/dev/null | t "$zdir" 2>/dev/null || printf 'Zygisk dir not found: %s' "$zdir")"
		return 0
	fi

	if ! command -v find >/dev/null 2>&1; then
		_msg="$(i18n 'PRUNE_ZYGISK_FIND_MISSING' 2>/dev/null)"; [ -n "$_msg" ] || _msg="find not found"; abort "$_msg"
	fi

	info "$(i18n 'PRUNE_ZYGISK_START' 2>/dev/null | t "$arch" "$zdir" 2>/dev/null || printf 'Pruning zygisk for arch %s in %s' "$arch" "$zdir")"

	# Choose candidate patterns by arch (lowercase match)
	case "$(printf '%s' "$arch" | tr '[:upper:]' '[:lower:]')" in
	arm64 | aarch64 | arm64-v8a)
		pats="mips*.so mips64*.so riscv*.so x86*.so x64*.so x86_64*.so"
		;;
	arm | armeabi | armeabi-v7a)
		pats="mips*.so mips64*.so riscv*.so x86*.so x64*.so x86_64*.so *64*.so"
		;;
	x64 | x86_64)
		pats="mips*.so riscv*.so"
		;;
	x86)
		pats="mips*.so riscv*.so *64*.so"
		;;
	riscv64 | riscv)
		pats="mips*.so mips64*.so arm*.so x86*.so x64*.so x86_64*.so"
		;;
	mips64)
		pats="riscv*.so arm*.so x86*.so x64*.so"
		;;
	mips)
		pats="riscv*.so arm*.so x86*.so x64*.so *64*.so"
		;;
	*)
		warn "$(i18n 'PRUNE_ZYGISK_UNKNOWN_ARCH' 2>/dev/null | t "$arch" 2>/dev/null || printf 'Unknown arch: %s; skipping' "$arch")"
		return 1
		;;
	esac

	TMPDIR="${TMPDIR:-/tmp}"
	__prune_tmp="$(mktemp "${TMPDIR}/kamfw.prune.XXXXXX" 2>/dev/null || mktemp 2>/dev/null || printf '')"
	[ -z "$__prune_tmp" ] && __prune_tmp="${TMPDIR}/kamfw.prune.$$"
	: >"$__prune_tmp" || true

	# Collect candidates (use -print0 to be safer with weird filenames)
	OLDIFS=$IFS
	IFS='
'
	for pat in $pats; do
		find "$zdir" -type f -name "$pat" -print0 2>/dev/null | tr '\0' '\n' >>"$__prune_tmp" || true
	done
	IFS=$OLDIFS

	# Nothing to do?
	[ ! -s "$__prune_tmp" ] && {
		info "$(i18n 'PRUNE_ZYGISK_NO_FILES' 2>/dev/null | t "$arch" 2>/dev/null || printf 'No zygisk files to remove for arch %s' "$arch")"
		rm -f "$__prune_tmp" 2>/dev/null || true
		return 0
	}

	# Dedupe if possible
	has_command "sort" && sort -u "$__prune_tmp" -o "$__prune_tmp" 2>/dev/null || true

	removed=0
	count=0
	while IFS= read -r f || [ -n "$f" ]; do
		[ -z "$f" ] && continue
		count=$((count + 1))
		[ "$dryrun" = true ] && {
			info "$(i18n 'PRUNE_ZYGISK_WOULD_REMOVE' 2>/dev/null | t "$f" 2>/dev/null || printf 'Would remove: %s' "$f")"
			continue
		}

		# Safety: ensure target is inside zdir
		case "$f" in
		"$zdir"/*) ;; # ok
		*)
			warn "$(i18n 'PRUNE_ZYGISK_REMOVE_FAILED' 2>/dev/null | t "$f" 2>/dev/null || printf 'Refusing to remove (outside dir): %s' "$f")"
			continue
			;;
		esac

		if rm -f -- "$f" 2>/dev/null; then
			removed=$((removed + 1))
			success "$(i18n 'PRUNE_ZYGISK_REMOVED' 2>/dev/null | t "$f" 2>/dev/null || printf 'Removed: %s' "$f")"
		else
			warn "$(i18n 'PRUNE_ZYGISK_REMOVE_FAILED' 2>/dev/null | t "$f" 2>/dev/null || printf 'Failed to remove: %s' "$f")"
		fi
	done <"$__prune_tmp"

	rm -f "$__prune_tmp" 2>/dev/null || true

	if [ "$dryrun" = true ]; then
		info "$(i18n 'PRUNE_ZYGISK_DRY_DONE' 2>/dev/null | t "$count" 2>/dev/null || printf 'Dry run: %d files match' "$count")"
	else
		success "$(i18n 'PRUNE_ZYGISK_DONE' 2>/dev/null | t "$removed" 2>/dev/null || printf 'Removed %d files' "$removed")"
	fi

	return 0
}
