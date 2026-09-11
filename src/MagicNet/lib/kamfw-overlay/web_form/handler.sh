# shellcheck shell=ash
# Invoked only by the generated CGI wrapper, with a bounded runtime.
set -eu
umask 077
export LC_ALL=C
BB=$KAM_FORM_BB
RUN=$KAM_FORM_RUN
. "$RUN/library.sh"
TMP=''
LOCKED=0
# Invoked by the EXIT trap, including request rejection and timeout paths.
# shellcheck disable=SC2317
finish() {
    [ -z "$TMP" ] || "$BB" rm -f "$TMP"
    if [ "$LOCKED" = 1 ]; then "$BB" rmdir "$RUN/submit.lock" 2>/dev/null || :; fi
}
trap finish 0
trap 'exit 1' 1 2 15
reply() {
    # Wire protocol, not user-facing prose; the page localizes stable result codes.
    printf 'Status: %s\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n%s\n' "$1" "$2"
    exit 0
}
[ "${HTTP_HOST:-}" = "${KAM_FORM_ORIGIN#http://}" ] || reply '403 Forbidden' forbidden
[ "${HTTP_X_SETUP_TOKEN:-}" = "$KAM_FORM_TOKEN" ] || reply '403 Forbidden' forbidden
[ -z "${HTTP_ORIGIN:-}" ] || [ "$HTTP_ORIGIN" = "$KAM_FORM_ORIGIN" ] || reply '403 Forbidden' forbidden
if [ "${PATH_INFO:-}" = /health ] && [ "${REQUEST_METHOD:-}" = GET ]; then
    reply '200 OK' ready
fi
[ "${REQUEST_METHOD:-}" = POST ] || reply '405 Method Not Allowed' method
case "${PATH_INFO:-}" in /save|/skip) ;; *) reply '404 Not Found' missing ;; esac
"$BB" mkdir "$RUN/submit.lock" 2>/dev/null || reply '409 Conflict' busy
LOCKED=1
[ ! -e "$RUN/done" ] || reply '409 Conflict' finished
if [ "$PATH_INFO" = /skip ]; then
    printf 'skipped\n' >"$RUN/done.new"
    "$BB" mv "$RUN/done.new" "$RUN/done"
    reply '200 OK' skipped
fi
case "${CONTENT_TYPE:-}" in text/plain|text/plain\;*) ;; *) reply '415 Unsupported Media Type' format ;; esac
LEN=${CONTENT_LENGTH:-}
case "$LEN" in ''|*[!0-9]*|0*) reply '400 Bad Request' invalid ;; esac
[ "${#LEN}" -le 4 ] || reply '413 Content Too Large' too_long
[ "$LEN" -le 8192 ] || reply '413 Content Too Large' too_long
TMP=$("$BB" mktemp "$RUN/request.XXXXXX")
"$BB" dd bs=1 count="$LEN" of="$TMP" 2>/dev/null || reply '400 Bad Request' invalid
[ "$("$BB" wc -c <"$TMP" | "$BB" tr -d ' ')" = "$LEN" ] || reply '400 Bad Request' invalid
BAD=$("$BB" tr -cd '\000-\040\177' <"$TMP" | "$BB" wc -c | "$BB" tr -d ' ')
[ "$BAD" = 0 ] || reply '400 Bad Request' invalid
VALUE=$("$BB" cat "$TMP")
case "$VALUE" in http://?*|https://?*) ;; *) reply '400 Bad Request' invalid ;; esac
if [ "${KAM_FORM_HTTPS_ONLY:-0}" = 1 ]; then
    # Strict subscription readers may treat @ as embedded credentials anywhere.
    case "$VALUE" in https://?*) ;; *) reply '400 Bad Request' invalid ;; esac
    case "$VALUE" in *@*) reply '400 Bad Request' invalid ;; esac
fi
HOST=${VALUE#*://}
HOST=${HOST%%[/?#]*}
case "$HOST" in ''|*\\*|*@*) reply '400 Bad Request' invalid ;; esac
# Never interpret a submitted URL as shell. Commit before acknowledging success.
# Session storage shares the output filesystem, so rename is atomic.
web_form_safe_path "$KAM_FORM_OUT" || reply '500 Internal Server Error' storage
[ ! -e "$KAM_FORM_OUT" ] || [ -f "$KAM_FORM_OUT" ] || reply '500 Internal Server Error' storage
if [ -s "$KAM_FORM_OUT" ]; then
    printf 'existing\n' >"$RUN/done.new"
    "$BB" mv "$RUN/done.new" "$RUN/done"
    reply '409 Conflict' existing
fi
printf '\n' >>"$TMP"
"$BB" chmod 600 "$TMP" || reply '500 Internal Server Error' storage
"$BB" mv -f "$TMP" "$KAM_FORM_OUT" || reply '500 Internal Server Error' storage
TMP=''
printf 'saved\n' >"$RUN/done.new"
"$BB" mv "$RUN/done.new" "$RUN/done"
reply '200 OK' saved
