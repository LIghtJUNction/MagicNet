# shellcheck shell=ash
# Private, bounded browser input. Importing this helper has no side effects.
# web_input_collect PUBLIC_DIR OUTPUT_FILE [SECONDS] [VALIDATOR_SCRIPT]
# The validator receives a private body-file path, never the input in argv.
# Return: 0 saved, 2 skipped, 3 timed out, 1 unavailable/error.
# OUTPUT_FILE is atomically replaced only if it has not changed since opening.
import launcher

web_input_busybox() (
    for candidate in "${KAMFW_WEB_INPUT_BUSYBOX:-}" \
        /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
        /data/adb/ap/bin/busybox /data/adb/apatch/bin/busybox \
        /debug_ramdisk/.magisk/busybox/busybox /sbin/.magisk/busybox/busybox \
        /system/xbin/busybox /system/bin/busybox "$(command -v busybox 2>/dev/null)"; do
        case "$candidate" in /*) ;; *) continue ;; esac
        case "$candidate" in *[[:space:]]*) continue ;; esac
        [ -x "$candidate" ] || continue
        applets=$("$candidate" --list 2>/dev/null) || continue
        ok=1
        for applet in ash awk httpd wget timeout setsid od tr dd cat mkdir mktemp chmod \
            cp mv rm rmdir wc grep sleep kill sha256sum; do
            printf '%s\n' "$applets" | "$candidate" grep -qx "$applet" || { ok=0; break; }
        done
        [ "$ok" = 1 ] && { printf '%s\n' "$candidate"; exit 0; }
    done
    exit 1
)

web_input_collect() (
    # Never change the sourced installer's shell options, umask or EXIT trap.
    set +x
    set -eu
    umask 077
    export LC_ALL=C
    PUBLIC=${1:-}; OUT=${2:-}; WAIT=${3:-180}; VALIDATOR=${4:-}
    case "$WAIT" in ''|*[!0-9]*|0*) exit 1 ;; esac
    [ "${#WAIT}" -le 4 ] && [ "$WAIT" -ge 5 ] && [ "$WAIT" -le 1800 ] || exit 1
    case "$PUBLIC" in /*) ;; *) exit 1 ;; esac
    case "$OUT" in /*) ;; *) exit 1 ;; esac
    [ -f "$PUBLIC/index.html" ] || exit 1
    [ -z "$VALIDATOR" ] || { [ -f "$VALIDATOR" ] && [ ! -L "$VALIDATOR" ]; } || exit 1
    # All output ancestors must be real directories, not symlinks.
    parent=${OUT%/*}
    [ -d "$parent" ] || exit 1
    check=$OUT
    while [ -n "$check" ]; do
        [ ! -L "$check" ] || exit 1
        check=${check%/*}
    done
    [ ! -e "$OUT" ] || [ -f "$OUT" ] || exit 1
    BB=$(web_input_busybox) || { print 'Browser setup unavailable: BusyBox httpd/CGI is required.'; exit 1; }
    RUN=$("$BB" mktemp -d "$parent/.web-input.XXXXXX") || exit 1
    SERVER_PID=''
    cleanup() {
        trap - 0 1 2 3 15
        if [ -n "$SERVER_PID" ]; then
            "$BB" kill -TERM -- "-$SERVER_PID" 2>/dev/null || kill "$SERVER_PID" 2>/dev/null || :
            wait "$SERVER_PID" 2>/dev/null || :
        fi
        "$BB" rm -rf "$RUN"
    }
    trap cleanup 0
    trap 'exit 1' 1 2 3 15
    "$BB" mkdir "$RUN/www" "$RUN/www/cgi-bin" || exit 1
    # Only explicitly public assets are exposed; no module/config directory.
    for asset in index.html setup.css setup.js; do
        [ ! -L "$PUBLIC/$asset" ] || exit 1
        [ ! -f "$PUBLIC/$asset" ] || "$BB" cp "$PUBLIC/$asset" "$RUN/www/$asset" || exit 1
    done
    printf 'A:127.0.0.1\nD:*\n' >"$RUN/httpd.conf" || exit 1
    TOKEN=$("$BB" od -An -N24 -tx1 /dev/urandom | "$BB" tr -d ' \n')
    [ "${#TOKEN}" = 48 ] || exit 1
    BEFORE=absent
    [ ! -e "$OUT" ] || BEFORE=$("$BB" sha256sum <"$OUT") || exit 1
    export KWI_BB="$BB" KWI_RUN="$RUN" KWI_OUT="$OUT" KWI_TOKEN="$TOKEN"
    export KWI_BEFORE="$BEFORE" KWI_VALIDATOR="$VALIDATOR" KWI_LIFETIME=$((WAIT + 20))
    "$BB" cp "$KAMFW_DIR/web_input_handler.sh" "$RUN/handler.sh" || exit 1
    {
        printf '#!%s ash\n' "$BB"
        printf '%s\n' 'exec "$KWI_BB" timeout 8 "$KWI_BB" ash "$KWI_RUN/handler.sh"'
    } >"$RUN/www/cgi-bin/api" || exit 1
    "$BB" chmod 700 "$RUN/www/cgi-bin/api" || exit 1
    # This watchdog belongs to the HTTP process group, not the installer. Even
    # SIGKILL of the installer cannot leave a permanent root listener behind.
    cat >"$RUN/server.sh" <<'SERVER' || exit 1
set -eu
("$KWI_BB" sleep "$KWI_LIFETIME"; "$KWI_BB" kill -TERM -- "-$$" 2>/dev/null) &
exec "$KWI_BB" httpd -f -p "$KWI_BIND" -h "$KWI_RUN/www" -c "$KWI_RUN/httpd.conf"
SERVER
    attempt=0
    while [ "$attempt" -lt 12 ]; do
        attempt=$((attempt + 1))
        number=$("$BB" od -An -N2 -tu2 /dev/urandom | "$BB" tr -d ' \n')
        PORT=$((20000 + number % 30000))
        export KWI_BIND="127.0.0.1:$PORT" KWI_ORIGIN="http://127.0.0.1:$PORT"
        "$BB" setsid "$BB" ash "$RUN/server.sh" </dev/null >"$RUN/server.log" 2>&1 &
        SERVER_PID=$!
        "$BB" sleep 1
        if kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
        "$BB" kill -TERM -- "-$SERVER_PID" 2>/dev/null || :
        wait "$SERVER_PID" 2>/dev/null || :
        SERVER_PID=''
        "$BB" grep -qi 'address already in use' "$RUN/server.log" || break
    done
    if [ -z "$SERVER_PID" ]; then
        print 'Browser setup unavailable: local server could not start.'
        exit 1
    fi
    health=$("$BB" timeout 6 "$BB" wget -Y off -q -O - \
        --header "X-Setup-Token: $TOKEN" "$KWI_ORIGIN/cgi-bin/api/health" 2>/dev/null) || health=''
    [ "$health" = ready ] || { print 'Browser setup unavailable: CGI self-test failed.'; exit 1; }
    page=$("$BB" timeout 6 "$BB" wget -Y off -q -O - "$KWI_ORIGIN/" 2>/dev/null) || page=''
    [ -n "$page" ] || exit 1
    URL="$KWI_ORIGIN/?ttl=$WAIT#$TOKEN"
    print "$URL"
    # Run the framework launcher in a bounded worker, rather than invoking am
    # directly in consuming modules. No browser package is hard-coded.
    if [ "${KAMFW_WEB_INPUT_NO_OPEN:-0}" != 1 ]; then
        cat >"$RUN/open.sh" <<'OPEN' || exit 1
. "$1"
launch browser "$2"
OPEN
        "$BB" timeout 6 "$BB" ash "$RUN/open.sh" "$KAMFW_DIR/launcher.sh" "$URL" >/dev/null 2>&1 || \
            print 'Open the local address above in your browser.'
    fi
    elapsed=0
    while [ "$elapsed" -lt "$WAIT" ]; do
        if [ -f "$RUN/done" ]; then
            result=$("$BB" cat "$RUN/done")
            "$BB" sleep 1 # Allow the HTTP response to flush before shutdown.
            [ "$result" != saved ] || exit 0
            exit 2
        fi
        kill -0 "$SERVER_PID" 2>/dev/null || exit 1
        "$BB" sleep 1
        elapsed=$((elapsed + 1))
    done
    exit 3
)
