# shellcheck shell=ash
# One-shot local HTTP(S)-URL collection. No daemon or install-time downloads.
# web_form_collect_url <static-assets> <private-output> [seconds]
# Returns: 0 saved; 2 skipped; 3 expired; 4 unavailable; 5 existing output.
# Requires kamfw's import/print and an existing BusyBox with httpd CGI support.
# Optional web_form_ready <url> <seconds> callback runs after a live CGI probe.

web_form_busybox() (
    if [ -n "${KAM_WEB_FORM_BUSYBOX:-}" ]; then
        set -- "$KAM_WEB_FORM_BUSYBOX"
    else
        set -- /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
            /data/adb/ap/bin/busybox /data/adb/apatch/bin/busybox \
            /debug_ramdisk/.magisk/busybox/busybox /sbin/.magisk/busybox/busybox \
            /system/xbin/busybox /system/bin/busybox "$(command -v busybox 2>/dev/null || :)"
    fi
    for candidate do
        case "$candidate" in /*) ;; *) continue ;; esac
        case "$candidate" in *[[:space:]]*) continue ;; esac
        [ -x "$candidate" ] || continue
        applets=$("$candidate" --list 2>/dev/null) || continue
        ok=1
        for applet in ash httpd wget timeout setsid od tr dd cat mkdir mktemp chmod cp mv rm rmdir wc grep sleep kill; do
            printf '%s\n' "$applets" | "$candidate" grep -qx "$applet" || { ok=0; break; }
        done
        [ "$ok" = 1 ] || continue
        printf '%s\n' "$candidate"
        exit 0
    done
    exit 4
)

# Check each existing ancestor, not just the leaf, before using private storage.
web_form_safe_path() (
    case "${1:-}" in /*) ;; *) exit 1 ;; esac
    p=$1
    case "$p" in /|*/../*|*/./*|*/..|*/.|*//*|*/) exit 1 ;; esac
    while [ "$p" != / ] && [ -n "$p" ]; do
        [ ! -L "$p" ] || exit 1
        p=${p%/*}
    done
)

web_form_collect_url() (
    # Installer tracing must not copy form credentials into persistent logs.
    set +x
    set -eu
    umask 077
    export LC_ALL=C
    ASSETS=${1:-}
    OUT=${2:-}
    TTL=${3:-180}
    case "$TTL" in ''|*[!0-9]*|0*) exit 4 ;; esac
    [ "${#TTL}" -le 4 ] && [ "$TTL" -ge 5 ] && [ "$TTL" -le 1800 ] || exit 4
    web_form_safe_path "$OUT" || exit 4
    [ ! -e "$OUT" ] || [ -f "$OUT" ] || exit 4
    [ ! -s "$OUT" ] || exit 5
    [ -d "$ASSETS" ] && [ -f "$ASSETS/index.html" ] || exit 4
    BB=$(web_form_busybox) || exit 4
    import launcher || exit 4
    PARENT=${OUT%/*}
    [ -d "$PARENT" ] || exit 4
    LOCK="$OUT.web-form.lock"
    "$BB" mkdir "$LOCK" 2>/dev/null || exit 4
    RUN=''
    SERVER_PID=''
    NOTICE_SENT=0
    # Invoked by the EXIT trap; exercised by lifecycle regression tests.
    # shellcheck disable=SC2317
    cleanup() {
        trap - 0 1 2 15
        if [ -n "$SERVER_PID" ]; then
            "$BB" kill -TERM -- "-$SERVER_PID" 2>/dev/null || kill "$SERVER_PID" 2>/dev/null || :
            wait "$SERVER_PID" 2>/dev/null || :
        fi
        if [ "$NOTICE_SENT" = 1 ]; then
            "$BB" timeout 4 cmd notification post -t "$KAM_WEB_FORM_NOTICE_TITLE" \
                "$NOTICE_TAG" "$KAM_WEB_FORM_NOTICE_DONE" >/dev/null 2>&1 || :
        fi
        [ -z "$RUN" ] || "$BB" rm -rf "$RUN"
        "$BB" rmdir "$LOCK" 2>/dev/null || :
    }
    # This trap belongs to a subshell; the installer's kamfw EXIT chain is intact.
    trap cleanup 0
    trap 'exit 130' 2
    trap 'exit 143' 1 15
    RUN=$("$BB" mktemp -d "$PARENT/.web-form.XXXXXX") || exit 4
    "$BB" mkdir -p "$RUN/www/cgi-bin" || exit 4
    # A strict asset allowlist prevents accidentally serving module secrets.
    for asset in index.html style.css app.js; do
        [ -f "$ASSETS/$asset" ] && [ ! -L "$ASSETS/$asset" ] || exit 4
        "$BB" cp "$ASSETS/$asset" "$RUN/www/$asset" || exit 4
    done
    "$BB" cp "$KAMFW_DIR/web_form/handler.sh" "$RUN/handler.sh" || exit 4
    "$BB" cp "$KAMFW_DIR/web_form.sh" "$RUN/library.sh" || exit 4
    printf 'A:127.0.0.1\nD:*\n' >"$RUN/httpd.conf" || exit 4
    TOKEN=$("$BB" od -An -N24 -tx1 /dev/urandom | "$BB" tr -d ' \n')
    [ "${#TOKEN}" = 48 ] || exit 4
    export KAM_FORM_BB="$BB" KAM_FORM_RUN="$RUN" KAM_FORM_TOKEN="$TOKEN" KAM_FORM_OUT="$OUT"
    export KAM_FORM_HTTPS_ONLY="${KAM_WEB_FORM_HTTPS_ONLY:-0}"
    {
        printf '#!%s ash\n' "$BB"
        printf '%s\n' 'exec "$KAM_FORM_BB" timeout 8 "$KAM_FORM_BB" ash "$KAM_FORM_RUN/handler.sh"'
    } >"$RUN/www/cgi-bin/api" || exit 4
    "$BB" chmod 700 "$RUN/www/cgi-bin/api" || exit 4
    attempt=0
    while [ "$attempt" -lt 8 ]; do
        attempt=$((attempt + 1))
        random=$("$BB" od -An -N2 -tu2 /dev/urandom | "$BB" tr -d ' \n')
        PORT=$((20000 + random % 30000))
        ORIGIN="http://127.0.0.1:$PORT"
        export KAM_FORM_ORIGIN="$ORIGIN"
        "$BB" setsid "$BB" timeout "$((TTL + 30))" "$BB" httpd -f \
            -p "127.0.0.1:$PORT" -h "$RUN/www" -c "$RUN/httpd.conf" \
            </dev/null >"$RUN/server.log" 2>&1 &
        SERVER_PID=$!
        "$BB" sleep 1
        kill -0 "$SERVER_PID" 2>/dev/null && break
        wait "$SERVER_PID" 2>/dev/null || :
        SERVER_PID=''
        "$BB" grep -qi 'address already in use' "$RUN/server.log" || exit 4
    done
    [ -n "$SERVER_PID" ] || exit 4
    health=$("$BB" timeout 6 "$BB" wget -Y off -q -O - \
        --header "X-Setup-Token: $TOKEN" "$ORIGIN/cgi-bin/api/health" 2>/dev/null) || exit 4
    [ "$health" = ready ] || exit 4
    URL="$ORIGIN/#$TOKEN"
    if command -v web_form_ready >/dev/null 2>&1; then web_form_ready "$URL" "$TTL"; fi
    if command -v cmd >/dev/null 2>&1 && [ -n "${KAM_WEB_FORM_NOTICE_TITLE:-}" ] &&
        [ -n "${KAM_WEB_FORM_NOTICE_TEXT:-}" ] && [ -n "${KAM_WEB_FORM_NOTICE_DONE:-}" ]; then
        NOTICE_TAG="kamfw_setup_$PORT"
        if "$BB" timeout 4 cmd notification post -t "$KAM_WEB_FORM_NOTICE_TITLE" \
            -c activity "$URL" "$NOTICE_TAG" "$KAM_WEB_FORM_NOTICE_TEXT" >/dev/null 2>&1; then
            NOTICE_SENT=1
        fi
    fi
    # Launch via the public kamfw API, with its own deadline. No URL in log files.
    KAM_LAUNCH_BUSYBOX="$BB" launch browser "$URL" >/dev/null 2>&1 || :
    elapsed=0
    while [ "$elapsed" -lt "$TTL" ]; do
        if [ -f "$RUN/done" ]; then
            result=$("$BB" cat "$RUN/done")
            if [ "$result" = saved ]; then
                "$BB" sleep 1
                exit 0
            fi
            "$BB" sleep 1
            [ "$result" != existing ] || exit 5
            exit 2
        fi
        kill -0 "$SERVER_PID" 2>/dev/null || exit 4
        "$BB" sleep 1
        elapsed=$((elapsed + 1))
    done
    exit 3
)
