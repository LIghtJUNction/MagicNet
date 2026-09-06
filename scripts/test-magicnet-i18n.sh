#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KAMFW_I18N_SH=${KAMFW_I18N_SH:-$ROOT/src/MagicNet/lib/kamfw/i18n.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-languages.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
import() { :; }
print() { printf '%s\n' "$1"; }
getprop() { printf '%s\n' "${TEST_SYSTEM_LOCALE:-en-US}"; }

# Exercise real kamfw registration with MagicNet's lookup compatibility layer.
# shellcheck disable=SC1090
. "$KAMFW_I18N_SH"
. "$ROOT/src/MagicNet/lib/magicnet/i18n.sh"
. "$ROOT/src/MagicNet/lib/magicnet/action_menu.sh"
. "$ROOT/src/MagicNet/lib/magicnet/core.sh"
. "$ROOT/src/MagicNet/lib/magicnet/supervisors.sh"
. "$ROOT/src/MagicNet/lib/magicnet/phases.sh"
unset KAM_UI_LANGUAGE KAM_LANG

set_i18n LOCALE_TEST zh '中文' en 'English' ru 'Русский' ja '日本語' ko '한국어'
for locale in ru ru-RU ru_RU.UTF-8 RU-RU; do
    [ "$(KAM_UI_LANGUAGE="$locale" i18n LOCALE_TEST)" = 'Русский' ] || fail "locale $locale did not select Russian"
done
[ "$(KAM_LANG=ru i18n LOCALE_TEST)" = 'Русский' ] || fail 'legacy language override lost Russian'
[ "$(TEST_SYSTEM_LOCALE=ru-RU i18n LOCALE_TEST)" = 'Русский' ] || fail 'Russian system locale was ignored'
[ "$(KAM_LANG=auto TEST_SYSTEM_LOCALE=ru-RU i18n LOCALE_TEST)" = 'Русский' ] || fail 'automatic language did not follow the system'
[ "$(KAM_UI_LANGUAGE=en KAM_LANG=ru i18n LOCALE_TEST)" = English ] || fail 'explicit language precedence changed'
KAM_LANG_FILE="$TMP/language-choice"
export KAM_LANG_FILE
printf '%s\n' 'export KAM_LANG="ru"' >"$KAM_LANG_FILE"
[ "$(i18n LOCALE_TEST)" = 'Русский' ] || fail 'saved Russian preference was ignored'
[ "$(KAM_UI_LANGUAGE=en i18n LOCALE_TEST)" = English ] || fail 'saved preference overrode explicit language'
[ "$(KAM_LANG=auto i18n LOCALE_TEST)" = English ] || fail 'automatic language used a saved override'
printf '%s\n' 'export KAM_LANG="ru"' 'export KAM_LANG="en"' >"$KAM_LANG_FILE"
[ "$(i18n LOCALE_TEST)" = English ] || fail 'duplicate persisted language assignments were accepted'
# shellcheck disable=SC2016 # Persist literal shell syntax to verify it is not evaluated.
printf '%s\n' 'export KAM_LANG="$(exit 42)"' >"$KAM_LANG_FILE"
[ "$(i18n LOCALE_TEST)" = English ] || fail 'persisted language was evaluated as shell code'
rm -f "$KAM_LANG_FILE"
[ "$(KAM_UI_LANGUAGE=zh-CN i18n LOCALE_TEST)" = '中文' ] || fail 'Chinese lookup changed'
[ "$(KAM_UI_LANGUAGE=ja-JP i18n LOCALE_TEST)" = '日本語' ] || fail 'Japanese lookup changed'
[ "$(KAM_UI_LANGUAGE=ko-KR i18n LOCALE_TEST)" = '한국어' ] || fail 'Korean lookup changed'
[ "$(KAM_UI_LANGUAGE=de-DE i18n LOCALE_TEST)" = English ] || fail 'unknown language did not fall back to English'
set_i18n FALLBACK_TEST en 'English fallback'
[ "$(KAM_UI_LANGUAGE=ru i18n FALLBACK_TEST)" = 'English fallback' ] || fail 'missing Russian translation did not fall back'
[ "$(KAM_UI_LANGUAGE=ru i18n MISSING_KEY)" = MISSING_KEY ] || fail 'missing translation did not preserve its key'

set_i18n MULTILINE_TEST ru 'Первая строка\nВторая строка'
[ "$(KAM_UI_LANGUAGE=ru i18n MULTILINE_TEST)" = 'Первая строка
Вторая строка' ] || fail 'multiline translation changed'
template=$(KAM_UI_LANGUAGE=ru i18n MAGICNET_FSWATCH_START_FAILED | t 42 /tmp/fswatch.log)
case "$template" in *'rc=42'*'/tmp/fswatch.log') ;; *) fail 'Russian placeholders did not interpolate' ;; esac
INVALID_I18N_SENTINEL="$TMP/invalid-key"
export INVALID_I18N_SENTINEL
# shellcheck disable=SC2016 # Pass an injection payload without expanding it in the test.
if i18n 'KEY; : >"$INVALID_I18N_SENTINEL"; #' >/dev/null 2>&1; then
    fail 'unsafe translation key was accepted'
fi
[ ! -e "$INVALID_I18N_SENTINEL" ] || fail 'unsafe translation key executed shell code'
[ "$(KAM_UI_LANGUAGE='ru; invalid' i18n LOCALE_TEST)" = 'Русский' ] || fail 'locale must normalize before interpolation'

# Rendered status changes language; status consumed by programs remains stable.
running() { return 0; }
[ "$(KAM_UI_LANGUAGE=ru magicnet_status_text running)" = Running ] || fail 'status protocol was translated'
[ "$(KAM_UI_LANGUAGE=ru magicnet_display_status Running)" = 'Работает' ] || fail 'displayed status was not translated'
[ "$(KAM_UI_LANGUAGE=ru magicnet_display_status 1234)" = 1234 ] || fail 'PID display was translated'

# Inspect the real selector arguments without running interactive device commands.
ask() { printf '%s\n' "$@"; }
menu=$(KAM_UI_LANGUAGE=ru-RU magicnet_select_lang)
printf '%s\n' "$menu" | grep -Fxq 'Русский (ru)' || fail 'Russian missing from language picker'
[ "$(printf '%s\n' "$menu" | tail -n 1)" = 2 ] || fail 'Russian picker default is incorrect'
for option in '中文 (zh)' 'English (en)' '日本語 (ja)' '한국어 (ko)'; do
    printf '%s\n' "$menu" | grep -Fxq "$option" || fail "existing language missing from picker: $option"
done

# Load only installer labels, without running installation or migration commands.
sed -n '/^# Usage & installation messages$/,/^magicnet_set_default_core()/{
    /^magicnet_set_default_core()/d
    p
}' "$ROOT/src/MagicNet/customize.sh" >"$TMP/install-labels.sh"
. "$TMP/install-labels.sh"
for key in INSTALL_TITLE INSTALL_PROFILE INSTALL_ROW_PROFILE INSTALL_DEFAULTS INSTALL_ROW_DEFAULTS \
    INSTALL_CONFIG_TITLE INSTALL_CONFIG_PATHS INSTALL_NEXT_STEPS INSTALL_FLAGS TERM_INSTALL_MSG \
    GUI_INSTALL_MSG SET_MODULE_ENTRY_PERMS MAGICNET_ACTION_MENU MAGICNET_UPDATE_SINGBOX_SUBSCRIPTION \
    MAGICNET_TOGGLE_SINGBOX MAGICNET_REFRESH_STATUS MAGICNET_DIAGNOSE MAGICNET_EXIT \
    MAGICNET_FSWATCH_START_FAILED MAGICNET_FSWATCH_FLOCK_INCOMPATIBLE \
    MAGICNET_MCP_CLI_NOT_EXECUTABLE MAGICNET_MCP_START_FAILED; do
    eval "russian=\${_I18N_${key}_ru:-}"
    eval "english=\${_I18N_${key}_en:-}"
    [ -n "$russian" ] && [ -n "$english" ] || fail "English or Russian translation missing: $key"
    [ "$(KAM_UI_LANGUAGE=ru i18n "$key")" = "$russian" ] || fail "Russian lookup failed: $key"
done
next_steps=$(KAM_UI_LANGUAGE=ru i18n INSTALL_NEXT_STEPS)
case "$next_steps" in *'cli setup '*'cli api ui'*'REJECT / block'*'hostname=127.0.0.1&port=9090') ;; *) fail 'installer translated command or URL values' ;; esac
printf 'ok - MagicNet English/Russian locales, picker, fallback, installer and protocol safety\n'
