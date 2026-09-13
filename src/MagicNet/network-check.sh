#!/system/bin/sh
# Read-only HTTPS acceptance probes. Unlike cli pingtest, an HTTP error is NOT a pass.
# No subscription, route, firewall, service, or account state is changed.
set -eu
umask 077
MODDIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PATH="$MODDIR/system/bin:$MODDIR/bin:$PATH"
export PATH
TARGETS="$MODDIR/lib/magicnet/network-targets.tsv"
MODE=proxy
FAMILY=auto
JOBS=4
ROUNDS=1
TIMEOUT=12
PROXY=http://127.0.0.1:7892

usage() {
    cat <<'EOF'
Usage: sh network-check.sh [options]
  --mode proxy|system       proxy: loopback mixed inbound (default)
                            system: this process's OS path, NOT proof of app/TUN routing
  --family auto|4|6         system mode only; a proxy does not prove destination IP family
  --jobs 1..8               bounded parallel requests (default 4)
  --rounds 1..3             independent requests; never hide a failed round (default 1)
  --timeout 1..30           seconds per request (default 12)
  --proxy URL               http://127.0.0.1:PORT only (default :7892)
  --targets FILE            id|category|https_url|expected_status, no header
Exit: 0 all HTTPS probes passed; 1 failures; 2 incomplete/capability gap; 64 bad input.
This is not an authenticated app, UDP/WebRTC, DNS-leak, or transparent-UID acceptance test.
EOF
}
invalid() { printf '%s\n' "$1" >&2; exit 64; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --mode|--family|--jobs|--rounds|--timeout|--proxy|--targets)
            [ "$#" -ge 2 ] || invalid 'missing option value'
            case "$1" in
                --mode) MODE=$2 ;;
                --family) FAMILY=$2 ;;
                --jobs) JOBS=$2 ;;
                --rounds) ROUNDS=$2 ;;
                --timeout) TIMEOUT=$2 ;;
                --proxy) PROXY=$2 ;;
                --targets) TARGETS=$2 ;;
            esac
            shift 2 ;;
        *) invalid 'unknown option' ;;
    esac
done
case "$MODE" in proxy|system) ;; *) invalid 'invalid mode' ;; esac
case "$FAMILY" in auto|4|6) ;; *) invalid 'invalid family' ;; esac
case "$JOBS" in [1-8]) ;; *) invalid 'jobs must be 1..8' ;; esac
case "$ROUNDS" in [1-3]) ;; *) invalid 'rounds must be 1..3' ;; esac
case "$TIMEOUT" in [1-9]|[12][0-9]|30) ;; *) invalid 'timeout must be 1..30' ;; esac
[ "$MODE" != proxy ] || [ "$FAMILY" = auto ] || invalid 'proxy mode cannot prove destination IPv4/IPv6'
case "$PROXY" in
    http://127.0.0.1:*) PORT=${PROXY##*:} ;;
    *) invalid 'proxy must be a loopback HTTP endpoint without credentials' ;;
esac
case "$PORT" in ''|*[!0-9]*) invalid 'invalid proxy port' ;; esac
[ "${#PORT}" -le 5 ] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || invalid 'invalid proxy port'
[ -r "$TARGETS" ] || invalid 'targets file is unreadable'
command -v curl >/dev/null 2>&1 || { printf 'INCOMPLETE: curl unavailable\n' >&2; exit 2; }

# Validate everything before making requests. A typo/empty corpus must never pass.
# Do not print URLs: a user-supplied corpus might contain private paths/tokens.
awk -F '|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    NF != 4 || length($1) > 64 || $1 !~ /^[a-z0-9][a-z0-9_-]*$/ || $2 !~ /^[a-z0-9_-]+$/ ||
    $3 !~ /^https:\/\/[^[:space:]|]+$/ || $3 ~ /@/ || $4 !~ /^(200|204)$/ {bad=1}
    seen[$1]++ {bad=1}
    {count++}
    END {exit (bad || count == 0 || count > 64)}
' "$TARGETS" || invalid 'invalid, duplicate, empty, or oversized target corpus'

# Use a private working directory; only aggregate after every worker has finished.
WORK=$(mktemp -d "${TMPDIR:-$MODDIR}/.network-check.XXXXXX") || exit 2
awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print}' "$TARGETS" > "$WORK/targets"
PIDS=''
cleanup() {
    for pid in $PIDS; do kill "$pid" 2>/dev/null || :; done
    for pid in $PIDS; do wait "$pid" 2>/dev/null || :; done
    rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

probe() (
    id=$1; category=$2; url=$3; expected=$4; round=$5
    set -- --disable --silent --show-error --location --max-redirs 5 \
        --proto '=https' --proto-redir '=https' --connect-timeout "$TIMEOUT" \
        --max-time "$TIMEOUT" --max-filesize 2097152 --output /dev/null \
        --write-out '%{http_code}|%{num_redirects}|%{size_download}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_total}|%{http_version}'
    if [ "$MODE" = proxy ]; then
        set -- "$@" --proxy "$PROXY" --noproxy ''
    else
        set -- "$@" --proxy '' --noproxy '*'
        case "$FAMILY" in 4) set -- "$@" --ipv4 ;; 6) set -- "$@" --ipv6 ;; esac
    fi
    rc=0
    curl "$@" --url "$url" > "$WORK/$id.$round.meta" 2>/dev/null || rc=$?
    code=000; redirects=0; bytes=0; dns=-; tcp=-; tls=-; total=-; version=-
    IFS='|' read -r code redirects bytes dns tcp tls total version < "$WORK/$id.$round.meta" || :
    status=FAIL; reason=transport
    case "$rc" in
        0)
            if [ "$code" = "$expected" ]; then
                status=PASS; reason=https_response
                if [ "$expected" = 204 ] && { [ "$redirects" != 0 ] || [ "$bytes" != 0 ]; }; then
                    status=FAIL; reason=captive_portal_or_unexpected_body
                fi
            else
                case "$code" in
                    401|407) reason=authentication_required ;;
                    403) reason=access_denied ;;
                    429) reason=rate_limited ;;
                    5??) reason=server_or_proxy_error ;;
                    *) reason=unexpected_http_status ;;
                esac
            fi ;;
        5|6) reason=dns ;;
        7) reason=connect ;;
        28) reason=timeout ;;
        35|51|58|59|60|77|80|82|83|90|91) reason=tls ;;
        1)
            case "$code" in
                3??) reason=unsafe_redirect ;;
                *) status=INCOMPLETE; reason=curl_capability ;;
            esac ;;
        2|4|48) status=INCOMPLETE; reason=curl_capability ;;
        63) status=INCOMPLETE; reason=response_exceeds_2mib ;;
    esac
    # Timings in proxy mode describe the local proxy/tunnel, not destination DNS.
    [ "$MODE" != proxy ] || dns=proxy_managed
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$category" "$MODE" "$FAMILY" "$round" "$status" "$reason" "$rc" "${code:-000}" \
        "${dns:--}" "${tcp:--}" "${tls:--}" "${total:--}" "${version:--}" > "$WORK/$id.$round.result"
)

printf '# scope=https_get mode=%s family=%s uid=%s rounds=%s jobs=%s\n' "$MODE" "$FAMILY" "$(id -u)" "$ROUNDS" "$JOBS"
printf '# NOT_TESTED: app_uid_routing authenticated_apps udp_webrtc dns_leaks network_handover\n'
printf 'target\tcategory\tmode\tfamily\tround\tstatus\treason\tcurl_exit\thttp\tdns_s\tconnect_s\ttls_s\ttotal_s\thttp_version\n'
round=1; expected_count=0; batch=0
while [ "$round" -le "$ROUNDS" ]; do
    while IFS='|' read -r id category url expected || [ -n "$id" ]; do
        case "$id" in ''|\#*) continue ;; esac
        probe "$id" "$category" "$url" "$expected" "$round" &
        PIDS="$PIDS $!"
        expected_count=$((expected_count + 1)); batch=$((batch + 1))
        if [ "$batch" -ge "$JOBS" ]; then
            for pid in $PIDS; do wait "$pid" || :; done
            PIDS=''; batch=0
        fi
    done < "$WORK/targets"
    round=$((round + 1))
done
for pid in $PIDS; do wait "$pid" || :; done
PIDS=''
# Missing worker output is INCOMPLETE, not success. Any failed round fails the run.
: > "$WORK/results"
for result in "$WORK/"*.result; do
    [ ! -f "$result" ] || cat "$result" >> "$WORK/results"
done
awk -F '\t' -v expected="$expected_count" '
    {print; count++; if ($6 == "PASS") pass++; else if ($6 == "FAIL") fail++; else incomplete++}
    END {
        incomplete += expected-count
        printf "# summary total=%d pass=%d fail=%d incomplete=%d\n", expected, pass, fail, incomplete
        if (fail) exit 1
        if (incomplete || count == 0) exit 2
    }
' "$WORK/results"
