# shellcheck shell=ash
# CGI entry invoked only by the private, bounded BusyBox wrapper.
set -eu
umask 077
export LC_ALL=C
bb=$MN_SETUP_BB
run=$MN_SETUP_RUN
root=$MN_SETUP_ROOT
body=''
stage=''
locked=0
# EXIT/signal callback is exercised by request and interruption tests.
# shellcheck disable=SC2317
cleanup() {
    [ -z "$body" ] || "$bb" rm -f "$body"
    [ -z "$stage" ] || "$bb" rm -f "$stage"
    [ "$locked" != 1 ] || "$bb" rmdir "$run/submit.lock" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 1' 1 2 3 15
reply() {
    printf 'Status: %s\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n{"code":"%s"}\n' "$1" "$2"
    exit 0
}
[ "${HTTP_HOST:-}" = "${MN_SETUP_ORIGIN#http://}" ] || reply '403 Forbidden' forbidden
[ "${HTTP_X_SETUP_TOKEN:-}" = "$MN_SETUP_TOKEN" ] || reply '403 Forbidden' forbidden
[ -z "${HTTP_ORIGIN:-}" ] || [ "$HTTP_ORIGIN" = "$MN_SETUP_ORIGIN" ] || reply '403 Forbidden' forbidden
case "${HTTP_SEC_FETCH_SITE:-}" in '' | same-origin | none) ;; *) reply '403 Forbidden' forbidden ;; esac
if [ "${REQUEST_METHOD:-}" = GET ] && [ "${PATH_INFO:-}" = /health ]; then
    reply '200 OK' ready
fi
if [ "${REQUEST_METHOD:-}" = GET ] && [ "${PATH_INFO:-}" = /subscriptions ]; then
    [ ! -e "$run/result" ] || reply '409 Conflict' finished
    printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n'
    if [ -f "$run/baseline-subscription.url" ]; then
        "$bb" cat "$run/baseline-subscription.url"
    fi
    exit 0
fi
[ "${REQUEST_METHOD:-}" = POST ] || reply '405 Method Not Allowed' method
case "${PATH_INFO:-}" in /save | /skip) ;; *) reply '404 Not Found' missing ;; esac
"$bb" mkdir "$run/submit.lock" 2>/dev/null || reply '409 Conflict' busy
locked=1
[ ! -e "$run/result" ] || reply '409 Conflict' finished
if [ "$PATH_INFO" = /skip ]; then
    printf '%s\n' skipped >"$run/result.new"
    "$bb" mv "$run/result.new" "$run/result"
    reply '200 OK' skipped
fi
case "${CONTENT_TYPE:-}" in text/plain | text/plain\;*) ;; *) reply '415 Unsupported Media Type' format ;; esac
length=${CONTENT_LENGTH:-}
case "$length" in '' | *[!0-9]* | 0*) reply '400 Bad Request' invalid ;; esac
[ "${#length}" -le 4 ] && [ "$length" -le 8192 ] || reply '413 Content Too Large' too_long
body=$("$bb" mktemp "$run/request.XXXXXX")
"$bb" dd bs=1 count="$length" of="$body" 2>/dev/null || reply '400 Bad Request' invalid
[ "$("$bb" wc -c <"$body" | "$bb" tr -d ' ')" = "$length" ] || reply '400 Bad Request' invalid
bad=$("$bb" tr -cd '\000-\011\013-\040\177' <"$body" | "$bb" wc -c | "$bb" tr -d ' ')
[ "$bad" = 0 ] || reply '400 Bad Request' invalid
count=0
while IFS= read -r value || [ -n "$value" ]; do
    count=$((count + 1))
    [ "$count" -le 5 ] || reply '400 Bad Request' invalid
    # Match the runtime's HTTPS-only policy; never eval/source the received value.
    case "$value" in https://?*) ;; *) reply '400 Bad Request' invalid ;; esac
    case "$value" in *'@'* | *'#'* | *\\*) reply '400 Bad Request' invalid ;; esac
    authority=${value#https://}
    authority=${authority%%[/?]*}
    printf '%s\n' "$authority" | "$bb" grep -Eq '^([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?$' || reply '400 Bad Request' invalid
    case "$authority" in
        \[*\]) ;;
        *:*)
            port=${authority##*:}
            # Strip leading zeroes before arithmetic to avoid ash's octal rules.
            while [ "${port#0}" != "$port" ]; do port=${port#0}; done
            [ -n "$port" ] && [ "$port" -le 65535 ] || reply '400 Bad Request' invalid
            ;;
    esac
done <"$body"
[ "$count" -gt 0 ] || reply '400 Bad Request' invalid
for path in "$root" "$root/.config" "$root/.config/sing-box"; do
    [ -d "$path" ] && [ ! -L "$path" ] || reply '409 Conflict' unsafe_path
done
out="$root/.config/sing-box/subscription.url"
for path in "$out" "$root/.config/sing-box/subscription.local" "$root/.config/sing-box/standalone-config"; do
    [ ! -L "$path" ] || reply '409 Conflict' unsafe_path
    [ ! -e "$path" ] || [ -f "$path" ] || reply '409 Conflict' unsafe_path
done
# Recheck the private baseline immediately before publication.
for name in subscription.url subscription.local standalone-config; do
    path="$root/.config/sing-box/$name"
    if [ -f "$run/baseline-$name" ]; then
        "$bb" cmp -s "$run/baseline-$name" "$path" || reply '409 Conflict' existing
    elif [ -e "$path" ]; then
        reply '409 Conflict' existing
    fi
done
stage=$("$bb" mktemp "$root/.config/sing-box/.install-subscription.XXXXXX")
"$bb" cat "$body" >"$stage" || reply '500 Internal Server Error' save_failed
printf '\n' >>"$stage" || reply '500 Internal Server Error' save_failed
"$bb" chmod 600 "$stage" || reply '500 Internal Server Error' save_failed
"$bb" rm -f "$root/.config/sing-box/standalone-config" || reply '500 Internal Server Error' save_failed
"$bb" mv -f "$stage" "$out" || reply '500 Internal Server Error' save_failed
stage=''
printf '%s\n' saved >"$run/result.new"
"$bb" mv "$run/result.new" "$run/result"
reply '200 OK' saved
