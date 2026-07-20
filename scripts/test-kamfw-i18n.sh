#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
I18N_SH="$ROOT/src/MagicNet/lib/kamfw/i18n.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/magicnet-i18n-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

REAL_TR=$(command -v tr)
TR_CALLS="$TMP/tr.calls"
export TR_CALLS

tr() {
    printf '%s\n' call >>"$TR_CALLS"
    "$REAL_TR" "$@"
}

# i18n.sh imports the translation table after defining its public functions.
# Keep this focused test on set_i18n itself.
import() { :; }
print() { printf '%s\n' "$1"; }

# shellcheck disable=SC1090
. "$I18N_SH"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

tr_call_count() {
    if [ -f "$TR_CALLS" ]; then
        awk 'END { print NR + 0 }' "$TR_CALLS"
    else
        printf '0\n'
    fi
}

: >"$TR_CALLS"
set_i18n FAST_PATH \
    zh 'plain zh' \
    en 'plain en' \
    ja 'plain ja' \
    ko 'line one
line two'

[ "${_I18N_FAST_PATH_zh:-}" = 'plain zh' ] || fail 'zh text was not preserved'
[ "${_I18N_FAST_PATH_en:-}" = 'plain en' ] || fail 'en text was not preserved'
[ "${_I18N_FAST_PATH_ja:-}" = 'plain ja' ] || fail 'ja text was not preserved'
[ "${_I18N_FAST_PATH_ko:-}" = 'line one
line two' ] || fail 'multiline text was not preserved'
env | grep -Fqx '_I18N_FAST_PATH_en=plain en' || fail 'registered text was not exported'

calls=$(tr_call_count)
[ "$calls" -eq 0 ] || fail "basic language registration invoked tr $calls times"

: >"$TR_CALLS"
set_i18n BASIC_ONE zh one en two
set_i18n BASIC_TWO ja three ko four
set_i18n BASIC_THREE en five
calls=$(tr_call_count)
[ "$calls" -eq 0 ] || fail "multiple basic registrations invoked tr $calls times"

: >"$TR_CALLS"
set_i18n REGION zh-CN 'regional text'
[ "${_I18N_REGION_zh_CN:-}" = 'regional text' ] || fail 'hyphenated language was not normalized'
calls=$(tr_call_count)
[ "$calls" -eq 1 ] || fail "hyphenated language invoked tr $calls times"

_I18N_KEY_CANARY='key canary'
export _I18N_KEY_CANARY
if set_i18n 'KEY_CANARY=overwritten' en attacker; then
    invalid_key_rc=0
else
    invalid_key_rc=$?
fi
[ "$_I18N_KEY_CANARY" = 'key canary' ] || fail 'key containing equals overwrote a valid variable'
[ "$invalid_key_rc" -ne 0 ] || fail 'key containing equals was accepted'

_I18N_LANG_CANARY_en='language canary'
export _I18N_LANG_CANARY_en
if set_i18n LANG_CANARY 'en=overwritten' attacker; then
    invalid_lang_rc=0
else
    invalid_lang_rc=$?
fi
[ "$_I18N_LANG_CANARY_en" = 'language canary' ] || fail 'language containing equals overwrote a valid variable'
[ "$invalid_lang_rc" -ne 0 ] || fail 'language containing equals was accepted'

unset _I18N_ATOMIC_en
if set_i18n ATOMIC en committed 'bad=lang' rejected; then
    atomic_rc=0
else
    atomic_rc=$?
fi
[ "${_I18N_ATOMIC_en+x}" != x ] || fail 'invalid later language partially committed earlier text'
[ "$atomic_rc" -ne 0 ] || fail 'mixed valid and invalid languages were accepted'

I18N_EVAL_CANARY="$TMP/i18n-eval-canary"
export I18N_EVAL_CANARY
# The key must contain literal shell syntax for the canary.
# shellcheck disable=SC2016
if i18n 'SAFE; : >"$I18N_EVAL_CANARY"; #' >/dev/null 2>&1; then
    invalid_lookup_rc=0
else
    invalid_lookup_rc=$?
fi
[ ! -e "$I18N_EVAL_CANARY" ] || fail 'illegal i18n key executed shell text'
[ "$invalid_lookup_rc" -ne 0 ] || fail 'illegal i18n key was accepted'

if set_i18n '1INVALID' en value; then
    fail 'key beginning with a digit was accepted'
fi
if set_i18n VALID_KEY '_en' value; then
    fail 'language not beginning with a letter was accepted'
fi
set_i18n _VALID_KEY en 'fallback text' zh 'localized text'
lookup=$(KAM_UI_LANGUAGE=zh-CN i18n _VALID_KEY)
[ "$lookup" = 'localized text' ] || fail 'normal language mapping did not select localized text'
lookup=$(KAM_UI_LANGUAGE=ja-JP i18n _VALID_KEY)
[ "$lookup" = 'fallback text' ] || fail 'missing localized text did not fall back to English'

SENTINEL="$TMP/injected"
if I18N_SH="$I18N_SH" SENTINEL="$SENTINEL" sh -c '
    import() { :; }
    . "$I18N_SH"
    set_i18n SAFE "$1" value
' test 'en$(touch "$SENTINEL")' >/dev/null 2>&1; then
    fail 'illegal language unexpectedly produced an exported variable'
fi
[ ! -e "$SENTINEL" ] || fail 'illegal language executed injected shell text'

VALID_TABLE="$TMP/valid-i18n.table"
printf '%s\n' \
    'KEY|zh-CN|en' \
    'FILE_VALUE|regional text|fallback text' >"$VALID_TABLE"
load_i18n "$VALID_TABLE" || fail 'valid translation table was rejected'
[ "${_I18N_FILE_VALUE_zh_CN:-}" = 'regional text' ] || fail 'valid regional table value was not loaded'
[ "${_I18N_FILE_VALUE_en:-}" = 'fallback text' ] || fail 'valid fallback table value was not loaded'

EMPTY_TABLE="$TMP/empty-i18n.table"
: >"$EMPTY_TABLE"
_I18N_EMPTY_CANARY_en='empty canary'
export _I18N_EMPTY_CANARY_en
load_i18n "$EMPTY_TABLE" || fail 'empty translation table was rejected'
[ "$_I18N_EMPTY_CANARY_en" = 'empty canary' ] || fail 'empty table changed existing translations'

NO_HEADER_TABLE="$TMP/no-header-i18n.table"
printf '%s\n' 'DEFAULT_LANGS|zh text|en text|ja text|ko text' >"$NO_HEADER_TABLE"
load_i18n "$NO_HEADER_TABLE" || fail 'table using default languages was rejected'
[ "${_I18N_DEFAULT_LANGS_zh:-}" = 'zh text' ] || fail 'default zh field extraction changed'
[ "${_I18N_DEFAULT_LANGS_en:-}" = 'en text' ] || fail 'default en field extraction changed'
[ "${_I18N_DEFAULT_LANGS_ja:-}" = 'ja text' ] || fail 'default ja field extraction changed'
[ "${_I18N_DEFAULT_LANGS_ko:-}" = 'ko text' ] || fail 'default ko field extraction changed'

ESCAPED_TABLE="$TMP/escaped-i18n.table"
printf '%s\n' 'KEY|en' 'ESCAPED_TEXT|line one\nline two' >"$ESCAPED_TABLE"
load_i18n "$ESCAPED_TABLE" || fail 'escaped multiline translation was rejected'
lookup=$(KAM_UI_LANGUAGE=en i18n ESCAPED_TEXT)
[ "$lookup" = 'line one
line two' ] || fail 'escaped multiline translation semantics changed'

INVALID_KEY_TABLE="$TMP/invalid-key-i18n.table"
printf '%s\n' \
    'KEY|en' \
    'LOAD_CANARY=overwritten|attacker' >"$INVALID_KEY_TABLE"
_I18N_LOAD_CANARY='load key canary'
export _I18N_LOAD_CANARY
if load_i18n "$INVALID_KEY_TABLE" >/dev/null 2>&1; then
    invalid_load_key_rc=0
else
    invalid_load_key_rc=$?
fi
[ "$_I18N_LOAD_CANARY" = 'load key canary' ] || fail 'invalid table key overwrote a valid variable'
[ "$invalid_load_key_rc" -ne 0 ] || fail 'load_i18n silently accepted an invalid key'

INVALID_LATE_TABLE="$TMP/invalid-late-i18n.table"
printf '%s\n' \
    'KEY|en' \
    'GOOD_ROW|committed' \
    'BAD=ROW|attacker' >"$INVALID_LATE_TABLE"
_I18N_GOOD_ROW_en='original value'
export _I18N_GOOD_ROW_en
if load_i18n "$INVALID_LATE_TABLE" >/dev/null 2>&1; then
    invalid_late_rc=0
else
    invalid_late_rc=$?
fi
[ "$invalid_late_rc" -ne 0 ] || fail 'load_i18n accepted an invalid later row'
[ "$_I18N_GOOD_ROW_en" = 'original value' ] || fail 'invalid later row overwrote an earlier value'

INVALID_FIELDS_TABLE="$TMP/invalid-fields-i18n.table"
printf '%s\n' \
    'KEY|en|zh' \
    'FIELD_CANARY|must not commit|也不能提交' \
    'MISSING_FIELD|only one value' >"$INVALID_FIELDS_TABLE"
unset _I18N_FIELD_CANARY_en _I18N_FIELD_CANARY_zh
if load_i18n "$INVALID_FIELDS_TABLE" >/dev/null 2>&1; then
    invalid_fields_rc=0
else
    invalid_fields_rc=$?
fi
[ "$invalid_fields_rc" -ne 0 ] || fail 'load_i18n accepted a malformed field group'
[ "${_I18N_FIELD_CANARY_en+x}" != x ] || fail 'malformed field group left an earlier row committed'
[ "${_I18N_FIELD_CANARY_zh+x}" != x ] || fail 'malformed field group partially committed translations'

INVALID_EMPTY_HEADER_TABLE="$TMP/invalid-empty-header-i18n.table"
printf '%s\n' 'KEY|en||zh' 'EMPTY_HEADER|one|two|three' >"$INVALID_EMPTY_HEADER_TABLE"
unset _I18N_EMPTY_HEADER_en _I18N_EMPTY_HEADER_zh
if load_i18n "$INVALID_EMPTY_HEADER_TABLE" >/dev/null 2>&1; then
    invalid_empty_header_rc=0
else
    invalid_empty_header_rc=$?
fi
[ "$invalid_empty_header_rc" -ne 0 ] || fail 'load_i18n accepted an empty header language'
[ "${_I18N_EMPTY_HEADER_en+x}" != x ] || fail 'bad header exported a translation'

INVALID_LANG_TABLE="$TMP/invalid-lang-i18n.table"
printf '%s\n' \
    'KEY|en=overwritten' \
    'LOAD_LANG|attacker' >"$INVALID_LANG_TABLE"
if load_i18n "$INVALID_LANG_TABLE" >/dev/null 2>&1; then
    invalid_load_lang_rc=0
else
    invalid_load_lang_rc=$?
fi
[ "${_I18N_LOAD_LANG+x}" != x ] || fail 'invalid table language exported a variable'
[ "$invalid_load_lang_rc" -ne 0 ] || fail 'load_i18n silently accepted an invalid language'

printf 'ok - kamfw set_i18n fast path and compatibility semantics\n'
