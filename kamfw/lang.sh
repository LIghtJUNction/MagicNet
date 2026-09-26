# shellcheck shell=ash
#
# Language selection module for KAM framework (KAMFW)
#
# Usage:
#   import lang
#   select_language        # interactive selection (uses `ask`)
#   set_kam_language en    # programmatically set language to `en`
#   unset_kam_language     # remove override (back to system / auto)
#
# Notes:
# - Persists choice to "${KAM_LANG_FILE}" as `export KAM_LANG="..."`.
# - Persists only the KAM UI language by default. Set KAM_LANG_SET_SYSTEM=1 to
#   also try updating Android's system locale.
# - Uses the existing `i18n` + `ask` helpers for localized menu and input.
#

# Ensure we have a sane default for KAMFW_DIR when sourced standalone.
: "${KAMFW_DIR:=${MODDIR:-${0%/*}}/lib/kamfw}"
: "${KAM_LANG_FILE:=${KAMFW_DIR}/.kamfw_lang}"

# helper: return normalized current language (zh|en|ja|ko|auto)
_lang_current() {
    # If a persisted override exists, source it to obtain the explicit override
    if [ -z "${KAM_LANG:-}" ] && [ -f "${KAM_LANG_FILE}" ]; then
        # shellcheck disable=SC1090
        . "${KAM_LANG_FILE}" 2>/dev/null || true
    fi

    # If user explicitly selected 'auto', return 'auto' so callers can treat it specially
    if [ "${KAM_LANG:-}" = "auto" ]; then
        printf 'auto'
        return 0
    fi

    _l="${KAM_LANG:-$(getprop persist.sys.locale 2>/dev/null | cut -d'-' -f1)}"
    _l="${_l:-en}"
    case "$_l" in
    zh* | cn* | CN*) printf 'zh' ;;
    ja* | JP*) printf 'ja' ;;
    ko* | KR*) printf 'ko' ;;
    *) printf 'en' ;;
    esac
}

# Persist the override to file (or remove it for 'auto')
_lang_persist() {
    _lang="$1"
    mkdir -p "${KAMFW_DIR}" 2>/dev/null || true

    if [ -z "$_lang" ] || [ "$_lang" = "auto" ]; then
        [ -f "${KAM_LANG_FILE}" ] && rm -f "${KAM_LANG_FILE}" 2>/dev/null || true
        unset KAM_LANG
        return 0
    fi

    printf 'export KAM_LANG="%s"\n' "$_lang" >"${KAM_LANG_FILE}"
}

# Best-effort setprop/resetprop for system locale
_lang_setprop() {
    [ "${KAM_LANG_SET_SYSTEM:-0}" = "1" ] || return 0
    _lang="$1"
    if command -v resetprop >/dev/null 2>&1; then
        resetprop -w persist.sys.locale "$_lang" >/dev/null 2>&1 || true
    elif command -v setprop >/dev/null 2>&1; then
        setprop persist.sys.locale "$_lang" >/dev/null 2>&1 || true
    fi
}

# Set language (public)
set_lang() {
    _lang="$1"
    [ -n "$_lang" ] || return 1

    # immediate effect for current session
    if [ "$_lang" = "auto" ]; then
        _lang_persist "auto" &&
            success "$(i18n 'LANG_SAVE' 2>/dev/null || echo 'Language saved'): $(i18n 'lang_auto' 2>/dev/null || echo 'Auto (system)')" ||
            error "$(i18n 'LANG_SAVE_ERROR' 2>/dev/null || echo 'Failed to remove language override')"
        return $?
    fi

    export KAM_LANG="$_lang"

    if _lang_persist "$_lang"; then
        _lang_setprop "$_lang"
        success "$(i18n 'LANG_SAVE' 2>/dev/null || echo 'Language saved'): $(i18n "lang_${_lang}" 2>/dev/null || echo "$_lang")"
        return 0
    else
        error "$(i18n 'LANG_SAVE_ERROR' 2>/dev/null || echo 'Failed to write language override')"
        return 1
    fi
}

# Remove language override (public)
unset_lang() {
    set_lang auto
}

# Interactive language menu (uses ask); exported as `select_language`
select_lang() {
    # Ensure helpers available (import is a kamfw helper)
    import i18n || true
    import rich || true

    # Ensure i18n system is properly initialized by forcing a call
    _test_i18n=$(i18n "SWITCH_LANGUAGE" 2>/dev/null)
    [ -z "$_test_i18n" ] && {
        # Fallback to English if i18n is not working
        export KAM_LANG="en"
    }

    # Determine current normalized language (may return 'auto')
    _cur="$(_lang_current)"

    # Discover available language codes from i18n exports (extract language tokens)
    _dic_langs=$(env | grep '^_I18N_' | sed -n 's/^_I18N_.*_\([^=]*\)=.*/\1/p' | sort -u)
    if [ -z "$_dic_langs" ]; then
        # fallback to a sensible default set
        _dic_langs="en zh ja ko"
    fi

    _default=0
    _idx=0

    # Build ask arguments as positional parameters to avoid eval.
    # ask expects: ask "QUESTION" "opt1_text" "opt1_cmd" "opt2_text" "opt2_cmd" ... [default_index]
    set -- "SWITCH_LANGUAGE"

    # Always add the AUTO option first
    _label_auto=$(i18n "LANG_AUTO")
    set -- "$@" "${_label_auto}" "set_lang auto"
    if [ "$_cur" = "auto" ]; then
        _default=0
    fi
    _idx=1

    for _l in $_dic_langs; do
        # sanitize token and normalize
        case "$_l" in
        [A-Za-z0-9._-]*) ;; # ok
        *) continue ;;      # skip suspicious tokens
        esac

        _l_norm=$(printf '%s' "$_l" | tr '[:upper:]' '[:lower:]')
        _upper=$(printf '%s' "$_l_norm" | tr '[:lower:]' '[:upper:]')
        _label=$(i18n "LANG_${_upper}")

        set -- "$@" "${_label}" "set_lang ${_l_norm}"

        # pick the default index if it matches current normalized language
        if [ "$_l_norm" = "$_cur" ]; then
            _default=$((_idx))
        fi

        _idx=$((_idx + 1))
    done

    # Ensure default is within the valid range
    if [ "$_default" -ge "$_idx" ]; then
        _default=0
    fi

    ask "$@" "$_default"
}
