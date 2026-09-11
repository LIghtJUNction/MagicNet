# shellcheck shell=ash
# Install-only UI. Sourced after kamfw initialization and configuration migration.
# No core startup, subscription download, APK, external assets or firewall changes.

magicnet_install_has_subscription() (
    _root=$1
    for _file in subscription.url subscription.local; do
        _path="$_root/.config/sing-box/$_file"
        # Treat any non-comment data as user state, even if it needs later repair.
        [ ! -L "$_path" ] || exit 0
        if [ -f "$_path" ] && LC_ALL=C grep -qEv '^[[:space:]]*(#.*)?$' "$_path"; then
            exit 0
        fi
    done
    [ -f "$_root/.config/sing-box/standalone-config" ] &&
        [ -s "$_root/.config/sing-box/config.json" ]
)

magicnet_onboarding_android_ready() {
    [ -x /system/bin/am ] && [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]
}

magicnet_onboarding_allowed() {
    [ "${MAGICNET_NONINTERACTIVE:-0}" != 1 ] &&
        [ "${MAGICNET_INSTALL_ONBOARDING:-1}" != 0 ] &&
        [ "${MAGICNET_SETUP:-1}" != 0 ] &&
        [ "${MAGIC_SINGBOX:-1}" != 0 ] || return 1
    case "${BOOTMODE:-}" in false | 0) return 1 ;; esac
    magicnet_install_has_subscription "$MODPATH" && return 1
    magicnet_onboarding_android_ready
}

magicnet_onboarding_find_busybox() (
    for _bb in "${MAGICNET_SETUP_BUSYBOX:-}" "${BUSYBOX:-}" \
        "$MODPATH/bin/busybox" /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
        /data/adb/ap/bin/busybox /data/adb/apatch/bin/busybox \
        /debug_ramdisk/.magisk/busybox/busybox /sbin/.magisk/busybox/busybox \
        /system/xbin/busybox /system/bin/busybox "$(command -v busybox 2>/dev/null)"; do
        case "$_bb" in /*) ;; *) continue ;; esac
        case "$_bb" in *[[:space:]]*) continue ;; esac
        [ -x "$_bb" ] || continue
        _applets=$("$_bb" --list 2>/dev/null) || continue
        _ok=1
        for _applet in ash httpd wget timeout setsid od tr dd cat mkdir mktemp chmod cp \
            mv rm rmdir wc grep sleep kill; do
            printf '%s\n' "$_applets" | "$_bb" grep -qx "$_applet" || { _ok=0; break; }
        done
        [ "$_ok" = 1 ] || continue
        printf '%s\n' "$_bb"
        exit 0
    done
    exit 1
)

magicnet_onboarding_android_am() {
    "$MN_SETUP_BB" timeout 5 /system/bin/am "$@" --user current \
        -c android.intent.category.BROWSABLE
}

magicnet_onboarding_android_command() {
    case "$1" in am | cmd) ;; *) return 127 ;; esac
    _android_tool=$1
    shift
    "$MN_SETUP_BB" timeout 5 "/system/bin/$_android_tool" "$@"
}

magicnet_onboarding_open() (
    unset LD_LIBRARY_PATH LD_PRELOAD
    # Keep the upstream framework untouched. The browser extension from #186 is
    # loaded only in this subshell; all other module launch callers keep their API.
    import launcher || exit 1
    if [ -n "${MODPATH:-}" ] && [ -f "$MODPATH/lib/kamfw-web/launcher.sh" ]; then
        . "$MODPATH/lib/kamfw-web/launcher.sh" || exit 1
        PATH="/system/bin:${PATH:-}"
        export PATH
        # Called indirectly by the extension's launch browser dispatcher.
        # shellcheck disable=SC2317
        _launch_run() { magicnet_onboarding_android_command "$@"; }
        launch browser "$1" >"$MN_SETUP_RUN/browser.log" 2>&1
        exit "$?"
    fi
    # Backward-compatible fallback for older packages without the extension.
    # Called indirectly by the pinned kamfw launcher; covered by host tests.
    # shellcheck disable=SC2317
    am() {
        magicnet_onboarding_android_am "$@" >"$MN_SETUP_RUN/browser.log" 2>&1
        exit "$?"
    }
    launch url "$1"
)

magicnet_onboarding_collect() (
    # Isolation preserves the installer's kamfw at_exit migration cleanup.
    set +x
    set -eu
    umask 077
    export LC_ALL=C
    _wait=${MAGICNET_SETUP_TIMEOUT:-180}
    case "$_wait" in '' | *[!0-9]* | 0*) exit 1 ;; esac
    [ "${#_wait}" -le 4 ] && [ "$_wait" -ge 5 ] && [ "$_wait" -le 1800 ] || exit 1
    MN_SETUP_BB=$(magicnet_onboarding_find_busybox) || exit 1
    _bb=$MN_SETUP_BB
    case "$MODPATH" in /*) ;; *) exit 1 ;; esac
    [ "$MODPATH" != / ] || exit 1
    for _path in "$MODPATH" "$MODPATH/.state" "$MODPATH/.config" "$MODPATH/.config/sing-box"; do
        [ ! -L "$_path" ] || exit 1
        [ ! -e "$_path" ] || [ -d "$_path" ] || exit 1
    done
    "$_bb" mkdir -p "$MODPATH/.state" "$MODPATH/.config/sing-box" || exit 1
    _lock="$MODPATH/.state/install-onboarding.lock"
    "$_bb" mkdir "$_lock" 2>/dev/null || exit 1
    MN_SETUP_RUN=''
    _pid=''
    _notice=0
    _tag="MagicNet_setup_$$"
    # EXIT/signal callback, not a direct call in this subshell.
    # shellcheck disable=SC2317
    cleanup() {
        trap - 0 1 2 3 15
        if [ -n "$_pid" ]; then
            "$_bb" kill -TERM -- "-$_pid" 2>/dev/null || kill "$_pid" 2>/dev/null || :
            wait "$_pid" 2>/dev/null || :
        fi
        if [ "$_notice" = 1 ]; then
            "$_bb" timeout 3 /system/bin/cmd notification post -t MagicNet \
                "$_tag" "$(i18n MN_SETUP_CLOSED)" >/dev/null 2>&1 || :
        fi
        [ -z "$MN_SETUP_RUN" ] || "$_bb" rm -rf "$MN_SETUP_RUN"
        "$_bb" rmdir "$_lock" 2>/dev/null || :
    }
    trap cleanup 0
    trap 'exit 130' 2
    trap 'exit 143' 1 3 15
    MN_SETUP_RUN=$("$_bb" mktemp -d "$MODPATH/.state/install-onboarding.XXXXXX") || exit 1
    MN_SETUP_ROOT=$MODPATH
    MN_SETUP_TOKEN=$("$_bb" od -An -N24 -tx1 /dev/urandom | "$_bb" tr -d ' \n')
    [ "${#MN_SETUP_TOKEN}" = 48 ] || exit 1
    export MN_SETUP_BB MN_SETUP_RUN MN_SETUP_ROOT MN_SETUP_TOKEN
    "$_bb" mkdir -p "$MN_SETUP_RUN/www/cgi-bin" || exit 1
    for _asset in index.html style.css app.js; do
        "$_bb" cp "$MODPATH/lib/magicnet/onboarding/$_asset" "$MN_SETUP_RUN/www/$_asset" || exit 1
    done
    "$_bb" cp "$MODPATH/lib/magicnet/onboarding/handler.sh" "$MN_SETUP_RUN/handler.sh" || exit 1
    printf 'A:127.0.0.1\nD:*\n' >"$MN_SETUP_RUN/httpd.conf" || exit 1
    {
        printf '#!%s ash\n' "$_bb"
        printf '%s\n' 'exec "$MN_SETUP_BB" timeout 8 "$MN_SETUP_BB" ash "$MN_SETUP_RUN/handler.sh"'
    } >"$MN_SETUP_RUN/www/cgi-bin/setup" || exit 1
    "$_bb" chmod 700 "$MN_SETUP_RUN/www/cgi-bin/setup" || exit 1
    _attempt=0
    _started=0
    while [ "$_attempt" -lt 12 ]; do
        _attempt=$((_attempt + 1))
        _random=$("$_bb" od -An -N2 -tu2 /dev/urandom | "$_bb" tr -d ' \n')
        _port=$((20000 + _random % 30000))
        MN_SETUP_ORIGIN="http://127.0.0.1:$_port"
        export MN_SETUP_ORIGIN
        # Limit the listener lifetime even if the installer is killed.
        "$_bb" setsid "$_bb" timeout "$((_wait + 30))" "$_bb" httpd -f \
            -p "127.0.0.1:$_port" -h "$MN_SETUP_RUN/www" -c "$MN_SETUP_RUN/httpd.conf" \
            >"$MN_SETUP_RUN/server.log" 2>&1 &
        _pid=$!
        "$_bb" sleep 1
        if kill -0 "$_pid" 2>/dev/null; then _started=1; break; fi
        wait "$_pid" 2>/dev/null || :
        _pid=''
        "$_bb" grep -qi 'address already in use' "$MN_SETUP_RUN/server.log" || break
    done
    [ "$_started" = 1 ] || exit 1
    _health=$("$_bb" timeout 6 "$_bb" wget -Y off -q -O - \
        --header "X-Setup-Token: $MN_SETUP_TOKEN" "$MN_SETUP_ORIGIN/cgi-bin/setup/health" \
        2>/dev/null) || exit 1
    [ "$_health" = '{"code":"ready"}' ] || exit 1
    _page=$("$_bb" timeout 6 "$_bb" wget -Y off -q -O - "$MN_SETUP_ORIGIN/" 2>/dev/null) || exit 1
    case "$_page" in *'id="setup-form"'*) ;; *) exit 1 ;; esac
    _lang=${KAM_UI_LANGUAGE:-${KAM_LANG:-}}
    case "$_lang" in '' | auto) _lang=$(getprop persist.sys.locale 2>/dev/null || :) ;; esac
    _lang=$(printf '%s' "$_lang" | "$_bb" tr 'A-Z_' 'a-z-')
    case "$_lang" in
        zh-tw* | zh-hk* | zh-mo* | zh-hant*) _lang=zh-TW ;;
        zh*) _lang=zh ;;
        ru*) _lang=ru ;;
        ja*) _lang=ja ;;
        ko*) _lang=ko ;;
        en*) _lang=en ;;
        *) _lang=auto ;;
    esac
    _url="$MN_SETUP_ORIGIN/?lang=$_lang#$MN_SETUP_TOKEN"
    print "$(i18n MN_SETUP_WAIT)"
    # A short-lived local capability, never the subscription itself.
    print "$_url"
    if [ -x /system/bin/cmd ]; then
        "$_bb" timeout 4 /system/bin/cmd notification post -t MagicNet \
            -c activity "$_url" "$_tag" "$(i18n MN_SETUP_OPEN)" \
            >/dev/null 2>&1 && _notice=1
    fi
    magicnet_onboarding_open "$_url" || print "$(i18n MN_SETUP_MANUAL)"
    _elapsed=0
    while [ "$_elapsed" -lt "$_wait" ]; do
        if [ -f "$MN_SETUP_RUN/result" ]; then
            _result=$("$_bb" cat "$MN_SETUP_RUN/result")
            "$_bb" sleep 1 # Let the final HTTP response reach the browser.
            case "$_result" in
                saved) print "$(i18n MN_SETUP_SAVED)"; exit 0 ;;
                skipped) print "$(i18n MN_SETUP_CLOSED)"; exit 2 ;;
                *) exit 1 ;;
            esac
        fi
        kill -0 "$_pid" 2>/dev/null || exit 1
        "$_bb" sleep 1
        _elapsed=$((_elapsed + 1))
    done
    print "$(i18n MN_SETUP_CLOSED)"
    exit 3
)

magicnet_install_onboarding() {
    magicnet_onboarding_allowed || return 0
    . "$MODPATH/lib/magicnet/onboarding/messages.sh" || return 1
    if magicnet_onboarding_collect; then
        return 0
    else
        case "$?" in
            2 | 3) return 0 ;;
            130 | 143) return 1 ;;
            *) print "$(i18n MN_SETUP_UNAVAILABLE)"; return 0 ;;
        esac
    fi
}
