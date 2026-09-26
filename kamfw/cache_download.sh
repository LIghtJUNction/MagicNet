# shellcheck shell=ash
#
# cache_download.sh
#
# Cached download helper for kamfw.
# Importing this module does not perform network or file work.

set_i18n "CACHE_DOWNLOAD_MISSING_URL" \
	"zh" "cache_download: URL 不能为空" \
	"en" "cache_download: url is required"

set_i18n "CACHE_DOWNLOAD_MISSING_DEST" \
	"zh" "cache_download: 目标文件不能为空" \
	"en" "cache_download: destination file is required"

set_i18n "CACHE_DOWNLOAD_MISSING_TOOL" \
	"zh" "cache_download: 缺少必需工具: \$_1" \
	"en" "cache_download: required command not found: \$_1"

set_i18n "CACHE_DOWNLOAD_DOWNLOAD_FAILED" \
	"zh" "cache_download: 下载失败: \$_1" \
	"en" "cache_download: download failed: \$_1"

set_i18n "CACHE_DOWNLOAD_HASH_FAILED" \
	"zh" "cache_download: 无法计算 sha256: \$_1" \
	"en" "cache_download: cannot compute sha256: \$_1"

set_i18n "CACHE_DOWNLOAD_HASH_MISMATCH" \
	"zh" "cache_download: sha256 不匹配: local=\$_1 expected=\$_2" \
	"en" "cache_download: sha256 mismatch: local=\$_1 expected=\$_2"

set_i18n "CACHE_DOWNLOAD_UP_TO_DATE" \
	"zh" "cache_download: 已是最新: \$_1" \
	"en" "cache_download: up to date: \$_1"

set_i18n "CACHE_DOWNLOAD_UPDATED" \
	"zh" "cache_download: 已更新: \$_1" \
	"en" "cache_download: updated: \$_1"

cache_download_msg() {
	_cd_key="$1"
	_cd_fallback="$2"
	shift 2
	_cd_msg="$(i18n "$_cd_key" 2>/dev/null)"
	if [ -n "$_cd_msg" ]; then
		printf '%s' "$_cd_msg" | t "$@" 2>/dev/null
	else
		printf '%s' "$_cd_fallback"
	fi
	unset _cd_key _cd_fallback _cd_msg
}

cache_download_require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		error "$(cache_download_msg CACHE_DOWNLOAD_MISSING_TOOL "cache_download: required command not found: $1" "$1")"
		return 1
	fi
}

cache_download_sha256() {
	_cd_file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$_cd_file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$_cd_file" | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$_cd_file" | awk '{print $2}'
	else
		return 1
	fi
	unset _cd_file
}

cache_download_text_sha256() {
	_cd_tmp="${TMPDIR:-/tmp}/kamfw.cache-download.text.$$"
	printf '%s' "$1" >"$_cd_tmp" || return 1
	_cd_hash="$(cache_download_sha256 "$_cd_tmp" 2>/dev/null || true)"
	rm -f "$_cd_tmp" 2>/dev/null || true
	[ -n "$_cd_hash" ] || return 1
	printf '%s\n' "$_cd_hash"
	unset _cd_tmp _cd_hash
}

cache_download_state_dir() {
	_cd_home="${KAM_HOME:-${MODDIR:-${MODPATH:-/tmp}}}"
	_cd_dir="${KAM_CACHE_DOWNLOAD_STATE_DIR:-$_cd_home/.cache/downloads}"
	mkdir -p "$_cd_dir" 2>/dev/null || return 1
	printf '%s\n' "$_cd_dir"
	unset _cd_home _cd_dir
}

cache_download_hash_file() {
	_cd_url="$1"
	_cd_dest="$2"
	_cd_dir="$(cache_download_state_dir)" || return 1
	_cd_key="$(cache_download_text_sha256 "$_cd_url|$_cd_dest" 2>/dev/null || true)"
	[ -n "$_cd_key" ] || return 1
	printf '%s/%s.sha256\n' "$_cd_dir" "$_cd_key"
	unset _cd_url _cd_dest _cd_dir _cd_key
}

cache_download_parse_hash() {
	sed -n 's/.*\([0-9a-fA-F]\{64\}\).*/\1/p' | head -n1 | tr '[:upper:]' '[:lower:]'
}

cache_download_remote_hash() {
	_cd_hash_url="$1"
	cache_download_require curl || return 1
	curl -fsSL "$_cd_hash_url" | cache_download_parse_hash
	unset _cd_hash_url
}

cache_download() {
	_cd_expected=""
	_cd_hash_url=""
	_cd_hash_file=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--hash)
			_cd_expected="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
			shift 2
			;;
		--hash-url)
			_cd_hash_url="$2"
			shift 2
			;;
		--hash-file)
			_cd_hash_file="$2"
			shift 2
			;;
		--help | -h)
			print "Usage: cache_download [--hash SHA256 | --hash-url URL] [--hash-file FILE] <url> <dest>"
			return 0
			;;
		*) break ;;
		esac
	done

	_cd_url="${1:-}"
	_cd_dest="${2:-}"
	if [ -z "$_cd_url" ]; then
		error "$(cache_download_msg CACHE_DOWNLOAD_MISSING_URL "cache_download: url is required")"
		return 1
	fi
	if [ -z "$_cd_dest" ]; then
		error "$(cache_download_msg CACHE_DOWNLOAD_MISSING_DEST "cache_download: destination file is required")"
		return 1
	fi

	cache_download_require curl || return 1
	mkdir -p "$(dirname "$_cd_dest")" 2>/dev/null || return 1

	if [ -z "$_cd_hash_file" ]; then
		_cd_hash_file="$(cache_download_hash_file "$_cd_url" "$_cd_dest")" || return 1
	fi
	mkdir -p "$(dirname "$_cd_hash_file")" 2>/dev/null || return 1

	if [ -n "$_cd_hash_url" ]; then
		_cd_remote_hash="$(cache_download_remote_hash "$_cd_hash_url" 2>/dev/null || true)"
		[ -n "$_cd_remote_hash" ] && _cd_expected="$_cd_remote_hash"
	fi

	if [ -n "$_cd_expected" ] && [ -f "$_cd_hash_file" ] && [ -f "$_cd_dest" ]; then
		_cd_cached="$(cat "$_cd_hash_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
		_cd_current="$(cache_download_sha256 "$_cd_dest" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
		if [ "$_cd_cached" = "$_cd_expected" ] && [ "$_cd_current" = "$_cd_expected" ]; then
			export KAM_CACHE_DOWNLOAD_CHANGED=0
			info "$(cache_download_msg CACHE_DOWNLOAD_UP_TO_DATE "cache_download: up to date: $_cd_dest" "$_cd_dest")"
			return 0
		fi
	fi

	_cd_tmp="$(dirname "$_cd_dest")/.$(basename "$_cd_dest").kamfw-download.$$"
	rm -f "$_cd_tmp" 2>/dev/null || true
	if ! curl -fsSL -o "$_cd_tmp" "$_cd_url"; then
		rm -f "$_cd_tmp" 2>/dev/null || true
		error "$(cache_download_msg CACHE_DOWNLOAD_DOWNLOAD_FAILED "cache_download: download failed: $_cd_url" "$_cd_url")"
		return 1
	fi

	_cd_new_hash="$(cache_download_sha256 "$_cd_tmp" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
	if [ -z "$_cd_new_hash" ]; then
		rm -f "$_cd_tmp" 2>/dev/null || true
		error "$(cache_download_msg CACHE_DOWNLOAD_HASH_FAILED "cache_download: cannot compute sha256: $_cd_tmp" "$_cd_tmp")"
		return 1
	fi

	if [ -n "$_cd_expected" ] && [ "$_cd_new_hash" != "$_cd_expected" ]; then
		rm -f "$_cd_tmp" 2>/dev/null || true
		error "$(cache_download_msg CACHE_DOWNLOAD_HASH_MISMATCH "cache_download: sha256 mismatch" "$_cd_new_hash" "$_cd_expected")"
		return 1
	fi

	if [ -f "$_cd_hash_file" ] && [ -f "$_cd_dest" ]; then
		_cd_cached="$(cat "$_cd_hash_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
		if [ "$_cd_cached" = "$_cd_new_hash" ]; then
			rm -f "$_cd_tmp" 2>/dev/null || true
			export KAM_CACHE_DOWNLOAD_CHANGED=0
			info "$(cache_download_msg CACHE_DOWNLOAD_UP_TO_DATE "cache_download: up to date: $_cd_dest" "$_cd_dest")"
			return 0
		fi
	fi

	mv -f "$_cd_tmp" "$_cd_dest" || {
		rm -f "$_cd_tmp" 2>/dev/null || true
		return 1
	}
	printf '%s\n' "$_cd_new_hash" >"$_cd_hash_file" 2>/dev/null || true
	export KAM_CACHE_DOWNLOAD_CHANGED=1
	success "$(cache_download_msg CACHE_DOWNLOAD_UPDATED "cache_download: updated: $_cd_dest" "$_cd_dest")"
}

download_if_changed() {
	cache_download "$@"
}

cache_download_if_changed() {
	cache_download "$@"
}
