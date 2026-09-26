# shellcheck shell=ash
#
# kamfw Android notification helper
#
# Explicit API only. Importing this file must not post notifications.

set_i18n "NOTIFY_TAG_REQUIRED" \
	"zh" "notify: tag 不能为空" \
	"en" "notify: tag is required" \
	"ja" "notify: tag が必要です" \
	"ko" "notify: tag 가 필요합니다"

set_i18n "NOTIFY_TITLE_REQUIRED" \
	"zh" "notify: 标题不能为空" \
	"en" "notify: title is required" \
	"ja" "notify: タイトルが必要です" \
	"ko" "notify: 제목이 필요합니다"

set_i18n "NOTIFY_TEXT_REQUIRED" \
	"zh" "notify: 内容不能为空" \
	"en" "notify: text is required" \
	"ja" "notify: 内容が必要です" \
	"ko" "notify: 내용이 필요합니다"

set_i18n "NOTIFY_TOOL_MISSING" \
	"zh" "notify: 缺少必需工具: \$_1" \
	"en" "notify: required command not found: \$_1" \
	"ja" "notify: 必要なコマンドがありません: \$_1" \
	"ko" "notify: 필수 명령이 없습니다: \$_1"

set_i18n "NOTIFY_POSTED" \
	"zh" "通知已发送: \$_1" \
	"en" "notification posted: \$_1" \
	"ja" "通知を送信しました: \$_1" \
	"ko" "알림 게시됨: \$_1"

set_i18n "NOTIFY_POST_FAILED" \
	"zh" "通知发送失败: \$_1" \
	"en" "notification failed: \$_1" \
	"ja" "通知の送信に失敗しました: \$_1" \
	"ko" "알림 실패: \$_1"

set_i18n "NOTIFY_EXPANDED" \
	"zh" "通知栏已展开" \
	"en" "notification shade expanded" \
	"ja" "通知シェードを展開しました" \
	"ko" "알림 창 펼쳐짐"

set_i18n "NOTIFY_EXPAND_FAILED" \
	"zh" "通知栏展开失败" \
	"en" "failed to expand notification shade" \
	"ja" "通知シェードの展開に失敗しました" \
	"ko" "알림 창 펼치기 실패"

notify_require_cmd() {
	if ! command -v cmd >/dev/null 2>&1; then
		error "$(i18n NOTIFY_TOOL_MISSING | t "cmd")"
		return 1
	fi
}

notify_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

notify_run_as_shell() {
	_nrs_cmd="$1"

	if [ "${KAM_NOTIFY_AS_SHELL:-1}" != "1" ]; then
		unset _nrs_cmd
		return 1
	fi
	if ! command -v su >/dev/null 2>&1; then
		unset _nrs_cmd
		return 1
	fi

	su shell -c "$_nrs_cmd" 2>/dev/null
	_nrs_rc=$?
	unset _nrs_cmd
	return "$_nrs_rc"
}

notify_post_cmd() {
	_npc_tag="$1"
	_npc_title="$2"
	_npc_text="$3"
	_npc_icon="${KAM_NOTIFY_ICON:-@android:drawable/stat_notify_error}"
	_npc_style="${KAM_NOTIFY_STYLE:-bigtext}"
	_npc_verbose_arg=""
	[ "${KAM_NOTIFY_VERBOSE:-0}" = "1" ] && _npc_verbose_arg="-v "
	_npc_cmd="cmd notification post ${_npc_verbose_arg}-S $(notify_quote "$_npc_style") -i $(notify_quote "$_npc_icon") -t $(notify_quote "$_npc_title") $(notify_quote "$_npc_tag") $(notify_quote "$_npc_text")"
	_npc_fallback_cmd="cmd notification post ${_npc_verbose_arg}-S $(notify_quote "$_npc_style") -t $(notify_quote "$_npc_title") $(notify_quote "$_npc_tag") $(notify_quote "$_npc_text")"

	if [ "${KAM_NOTIFY_VERBOSE:-0}" = "1" ]; then
		notify_run_as_shell "$_npc_cmd"
		_npc_rc=$?
		[ "$_npc_rc" -eq 0 ] || notify_run_as_shell "$_npc_fallback_cmd"
		_npc_rc=$?
		[ "$_npc_rc" -eq 0 ] || cmd notification post -v -S "$_npc_style" -i "$_npc_icon" -t "$_npc_title" "$_npc_tag" "$_npc_text"
		_npc_rc=$?
		[ "$_npc_rc" -eq 0 ] || cmd notification post -v -S "$_npc_style" -t "$_npc_title" "$_npc_tag" "$_npc_text"
		_npc_rc=$?
	else
		notify_run_as_shell "$_npc_cmd" >/dev/null 2>&1
		_npc_rc=$?
		[ "$_npc_rc" -eq 0 ] || notify_run_as_shell "$_npc_fallback_cmd" >/dev/null 2>&1
		_npc_rc=$?
		[ "$_npc_rc" -eq 0 ] || cmd notification post -S "$_npc_style" -i "$_npc_icon" -t "$_npc_title" "$_npc_tag" "$_npc_text" >/dev/null 2>&1
		_npc_rc=$?
		[ "$_npc_rc" -eq 0 ] || cmd notification post -S "$_npc_style" -t "$_npc_title" "$_npc_tag" "$_npc_text" >/dev/null 2>&1
		_npc_rc=$?
	fi

	unset _npc_tag _npc_title _npc_text _npc_icon _npc_style _npc_verbose_arg _npc_cmd _npc_fallback_cmd
	return "$_npc_rc"
}

notify_post() {
	_nt_tag="$1"
	_nt_title="$2"
	shift 2 2>/dev/null || true
	_nt_text="$*"

	[ -z "$_nt_tag" ] && {
		error "$(i18n NOTIFY_TAG_REQUIRED)"
		return 2
	}
	[ -z "$_nt_title" ] && {
		error "$(i18n NOTIFY_TITLE_REQUIRED)"
		unset _nt_tag _nt_title _nt_text
		return 2
	}
	[ -z "$_nt_text" ] && {
		error "$(i18n NOTIFY_TEXT_REQUIRED)"
		unset _nt_tag _nt_title _nt_text
		return 2
	}
	notify_require_cmd || {
		unset _nt_tag _nt_title _nt_text
		return 1
	}

	if notify_post_cmd "$_nt_tag" "$_nt_title" "$_nt_text"; then
		success "$(i18n NOTIFY_POSTED | t "$_nt_tag")"
		unset _nt_tag _nt_title _nt_text
		return 0
	fi

	error "$(i18n NOTIFY_POST_FAILED | t "$_nt_tag")"
	unset _nt_tag _nt_title _nt_text
	return 1
}

notify_expand() {
	notify_require_cmd || return 1
	if cmd statusbar expand-notifications >/dev/null 2>&1; then
		success "$(i18n NOTIFY_EXPANDED)"
		return 0
	fi
	error "$(i18n NOTIFY_EXPAND_FAILED)"
	return 1
}

notify_alert() {
	notify_post "$@"
	_nt_rc=$?
	[ "$_nt_rc" -eq 0 ] && notify_expand >/dev/null 2>&1 || true
	return "$_nt_rc"
}

notify_test() {
	_nt_now="$(date +%H:%M:%S 2>/dev/null || printf '%s' "now")"
	notify_alert "kamfw_notify_test" "Kam Test" "kamfw notification test at $_nt_now"
	_nt_rc=$?
	unset _nt_now
	return "$_nt_rc"
}

notify() {
	_nt_action="$1"
	shift || true
	case "$_nt_action" in
	post) notify_post "$@" ;;
	alert) notify_alert "$@" ;;
	expand) notify_expand ;;
	test) notify_test ;;
	*)
		print "Usage: notify post <tag> <title> <text...>"
		print "       notify alert <tag> <title> <text...>"
		print "       notify expand"
		print "       notify test"
		return 2
		;;
	esac
	_nt_rc=$?
	unset _nt_action
	return "$_nt_rc"
}
