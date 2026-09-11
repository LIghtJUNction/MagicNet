# shellcheck shell=ash
# Internal CGI worker. Never source this file in an installer.
set +x
set -eu
umask 077
export LC_ALL=C
BB=$KWI_BB
RUN=$KWI_RUN
TMP=''
LOCKED=0
finish() {
    [ -z "$TMP" ] || "$BB" rm -f "$TMP"
    if [ "$LOCKED" = 1 ]; then "$BB" rmdir "$RUN/submit.lock" 2>/dev/null || :; fi
}
trap finish 0
trap 'exit 1' 1 2 3 15
reply() {
    printf 'Status: %s\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n%s\n' "$1" "$2"
    exit 0
}
[ "${HTTP_HOST:-}" = "${KWI_ORIGIN#http://}" ] || reply '403 Forbidden' forbidden
[ "${HTTP_X_SETUP_TOKEN:-}" = "$KWI_TOKEN" ] || reply '403 Forbidden' forbidden
[ -z "${HTTP_ORIGIN:-}" ] || [ "$HTTP_ORIGIN" = "$KWI_ORIGIN" ] || reply '403 Forbidden' forbidden
[ "${HTTP_SEC_FETCH_SITE:-}" != cross-site ] || reply '403 Forbidden' forbidden
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
[ "${#LEN}" -le 4 ] && [ "$LEN" -le 8192 ] || reply '413 Content Too Large' too_long
TMP=$("$BB" mktemp "$RUN/request.XXXXXX")
"$BB" dd bs=1 count="$LEN" of="$TMP" 2>/dev/null || reply '400 Bad Request' invalid
[ "$("$BB" wc -c <"$TMP" | "$BB" tr -d ' ')" = "$LEN" ] || reply '400 Bad Request' invalid
# Single-line text protocol; percent escapes, quotes, ampersands and '+' stay data.
BAD=$("$BB" tr -cd '\000-\040\177' <"$TMP" | "$BB" wc -c | "$BB" tr -d ' ')
[ "$BAD" = 0 ] || reply '400 Bad Request' invalid
if [ -n "$KWI_VALIDATOR" ]; then
    "$BB" ash "$KWI_VALIDATOR" "$TMP" >/dev/null 2>&1 || reply '422 Unprocessable Entity' invalid
fi
[ ! -L "$KWI_OUT" ] || reply '409 Conflict' changed
[ ! -e "$KWI_OUT" ] || [ -f "$KWI_OUT" ] || reply '409 Conflict' changed
NOW=absent
[ ! -e "$KWI_OUT" ] || NOW=$("$BB" sha256sum <"$KWI_OUT")
[ "$NOW" = "$KWI_BEFORE" ] || reply '409 Conflict' changed
printf '\n' >>"$TMP"
"$BB" chmod 600 "$TMP"
"$BB" mv -f "$TMP" "$KWI_OUT" || reply '500 Internal Server Error' save_failed
TMP=''
printf 'saved\n' >"$RUN/done.new"
"$BB" mv "$RUN/done.new" "$RUN/done"
reply '200 OK' saved
