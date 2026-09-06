# shellcheck shell=ash
# The pinned kamfw lookup recognizes zh/en/ja/ko only. Keep its registration
# and rendering helpers, and extend language selection locally for Russian.
import i18n

magicnet_ui_language() {
    _magicnet_locale="${KAM_UI_LANGUAGE:-${KAM_LANG:-}}"
    if [ -z "$_magicnet_locale" ]; then
        _magicnet_language_file="${KAM_LANG_FILE:-${KAMFW_DIR:-${MODDIR:-}/lib/kamfw}/.kamfw_lang}"
        if [ -r "$_magicnet_language_file" ]; then
            # kamfw persists this exact assignment. Read it as data, never source it.
            _magicnet_locale=$(sed -n 's/^export KAM_LANG="\([a-z][a-z]\)"$/\1/p' "$_magicnet_language_file")
            case "$_magicnet_locale" in
            zh | en | ru | ja | ko) ;;
            *) _magicnet_locale='' ;;
            esac
        fi
        unset _magicnet_language_file
    fi
    case "$_magicnet_locale" in
    '' | auto) _magicnet_locale=$(getprop persist.sys.locale 2>/dev/null || true) ;;
    esac
    case "$_magicnet_locale" in
    zh* | ZH* | cn* | CN*) printf '%s\n' zh ;;
    ru* | RU*) printf '%s\n' ru ;;
    ja* | JA* | JP*) printf '%s\n' ja ;;
    ko* | KO* | KR*) printf '%s\n' ko ;;
    *) printf '%s\n' en ;;
    esac
    unset _magicnet_locale
}

i18n() (
    _magicnet_key="${1:-}"
    case "$_magicnet_key" in
    '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) return 1 ;;
    esac
    _magicnet_language=$(magicnet_ui_language)
    if [ -z "${KAM_UI_LANGUAGE:-}" ] && [ -n "${KAM_LANG:-}" ] && [ "${KAM_DEBUG_I18N:-}" = 1 ]; then
        print 'Warning: KAM_LANG is deprecated; please use KAM_UI_LANGUAGE'
    fi
    # The key is validated and the language comes from the fixed allowlist.
    eval "_magicnet_text=\${_I18N_${_magicnet_key}_${_magicnet_language}:-\${_I18N_${_magicnet_key}_en:-}}"
    print "$(printf '%b' "${_magicnet_text:-$_magicnet_key}")"
)

magicnet_select_lang() {
    case "$(magicnet_ui_language)" in
    zh) _magicnet_language_index=0 ;;
    en) _magicnet_language_index=1 ;;
    ru) _magicnet_language_index=2 ;;
    ja) _magicnet_language_index=3 ;;
    ko) _magicnet_language_index=4 ;;
    esac
    ask SWITCH_LANGUAGE \
        '中文 (zh)' 'unset KAM_UI_LANGUAGE; set_lang zh' \
        'English (en)' 'unset KAM_UI_LANGUAGE; set_lang en' \
        'Русский (ru)' 'unset KAM_UI_LANGUAGE; set_lang ru' \
        '日本語 (ja)' 'unset KAM_UI_LANGUAGE; set_lang ja' \
        '한국어 (ko)' 'unset KAM_UI_LANGUAGE; set_lang ko' \
        LANG_AUTO 'unset KAM_UI_LANGUAGE; set_lang auto' \
        "$_magicnet_language_index"
    unset _magicnet_language_index
}

set_i18n LANG_RU zh '俄语' en 'Russian' ru 'Русский' ja 'ロシア語' ko '러시아어'
set_i18n lang_ru ru 'Русский' en 'Russian'
set_i18n SWITCH_LANGUAGE ru 'Выберите язык'
set_i18n LANG_AUTO ru 'Автоматически (системный язык)'
set_i18n LANG_SAVE ru 'Язык сохранён'
set_i18n LANG_SAVE_ERROR ru 'Не удалось сохранить язык'
set_i18n ASK_GUIDE_TITLE ru 'Управление меню'
set_i18n ASK_GUIDE_CONTENT ru 'Уменьшение громкости: следующий пункт. Увеличение громкости: подтвердить выбор.'
set_i18n CONFIRM ru 'Подтвердить'
set_i18n YES ru 'Да'
set_i18n NO ru 'Нет'

set_i18n MAGICNET_RUNNING zh '运行中' en 'Running' ru 'Работает'
set_i18n MAGICNET_STOPPED zh '已停止' en 'Stopped' ru 'Остановлен'
set_i18n MAGICNET_UNKNOWN zh '未知' en 'Unknown' ru 'Неизвестно'
set_i18n MAGICNET_NOT_INSTALLED zh '未安装' en 'Not installed' ru 'Не установлен'
set_i18n MAGICNET_SUBSCRIPTION zh 'sing-box 订阅' en 'sing-box subscription' ru 'Подписка sing-box'
set_i18n MAGICNET_LOCAL_FILE zh '本地文件' en 'local file' ru 'локальный файл'
set_i18n MAGICNET_UNAVAILABLE zh '不可用' en 'unavailable' ru 'недоступно'
set_i18n MAGICNET_DIAGNOSE_TITLE zh 'MagicNet 网络诊断' en 'MagicNet Diagnose' ru 'Диагностика MagicNet'
set_i18n MAGICNET_RECENT_ERRORS zh 'sing-box 最近错误' en 'sing-box recent errors' ru 'Последние ошибки sing-box'
set_i18n MAGICNET_SINGBOX_MISSING zh '未安装 sing-box' en 'sing-box is not installed' ru 'sing-box не установлен'
set_i18n MAGICNET_PROCESS_UNKNOWN zh '无法确定 sing-box 进程状态' en 'sing-box process discovery is indeterminate' ru 'Не удалось определить состояние процесса sing-box'

# Localize rendered status only. Keep the shared status helper's protocol values.
magicnet_display_status() {
    case "$1" in
    Running) i18n MAGICNET_RUNNING ;;
    Stopped) i18n MAGICNET_STOPPED ;;
    Unknown) i18n MAGICNET_UNKNOWN ;;
    'Not installed') i18n MAGICNET_NOT_INSTALLED ;;
    *) printf '%s\n' "$1" ;;
    esac
}
