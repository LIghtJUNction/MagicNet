#!/system/bin/sh
# Read-only HTTPS probes. A successful mixed-in request is NOT a TUN/app test.
set -u
set -f
LC_ALL=C
export LC_ALL
umask 077

usage() {
    cat <<'EOF'
Usage: sh website_probe.sh [--path mixed|native] [--family auto|4|6]
       [--jobs 1..8] [--repeat 1..3] [--timeout 1..30]
       [--targets FILE] [--proxy-port PORT]
Defaults: mixed (SOCKS5h 127.0.0.1:7892), auto, 4 jobs, 1 round, 12s/request.
Native uses this process's UID/network policy, NOT necessarily an app's path.
Exit: 0 = all requested HTTP checks passed, 1 = failed checks, 2 = tool error,
      64 = invalid arguments/catalog. UDP, login and downloads are not certified.
EOF
}
fail() { printf '%s\n' "$*" >&2; exit 64; }
number_in_range() {
    case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 2
module_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd) || exit 2
PATH="$module_dir/bin:${PATH:-/system/bin:/system/xbin:/usr/bin:/bin}"
export PATH
targets="$module_dir/.config/magicnet/website-targets.tsv"
probe_path=mixed
family=auto
jobs=4
rounds=1
timeout=12
proxy_port=7892
while [ "$#" -gt 0 ]; do
    case "$1" in
    --help|-h) usage; exit 0 ;;
    --path|--family|--jobs|--repeat|--timeout|--targets|--proxy-port)
        [ "$#" -ge 2 ] || fail "Missing value for $1"
        case "$1" in
        --path) probe_path=$2 ;; --family) family=$2 ;; --jobs) jobs=$2 ;;
        --repeat) rounds=$2 ;; --timeout) timeout=$2 ;; --targets) targets=$2 ;;
        --proxy-port) proxy_port=$2 ;;
        esac
        shift 2 ;;
    *) fail "Unknown option: $1" ;;
    esac
done
case "$probe_path" in mixed|native) ;; *) fail 'Invalid path' ;; esac
case "$family" in auto|4|6) ;; *) fail 'Invalid address family' ;; esac
# curl -6 with SOCKS5h selects the PROXY address family, not the target's.
[ "$probe_path" != mixed ] || [ "$family" = auto ] || fail 'SOCKS5h cannot certify the target IP family; use native for -4/-6 checks'
number_in_range "$jobs" 1 8 || fail 'Invalid jobs'
number_in_range "$rounds" 1 3 || fail 'Invalid repeat'
number_in_range "$timeout" 1 30 || fail 'Invalid timeout'
number_in_range "$proxy_port" 1 65535 || fail 'Invalid proxy port'
[ -r "$targets" ] || fail 'Target catalog is not readable'
curl_bin=${MAGICNET_CURL:-"$module_dir/bin/curl"}
[ -x "$curl_bin" ] || curl_bin=${MAGICNET_CURL:-curl}
command -v "$curl_bin" >/dev/null 2>&1 || { printf 'curl is required\n' >&2; exit 2; }
for tool in awk mktemp id cat rm; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'Required tool missing: %s\n' "$tool" >&2; exit 2; }
done
tmp_base=${TMPDIR:-}
if [ -z "$tmp_base" ]; then
    if [ -d "$module_dir/.state" ]; then tmp_base="$module_dir/.state"; else tmp_base=/tmp; fi
fi
work=$(mktemp -d "$tmp_base/magicnet-web.XXXXXX") || exit 2
pids=''
cleanup() {
    for pid in $pids; do kill "$pid" 2>/dev/null || :; done
    for pid in $pids; do wait "$pid" 2>/dev/null || :; done
    rm -rf -- "$work"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
# Validate the WHOLE catalog before making requests. Never source/eval it.
awk -F '\t' '
    /^#/ || /^[[:space:]]*$/ { next }
    NF != 5 || $1 !~ /^[a-z0-9][a-z0-9_-]*$/ ||
    $2 !~ /^[a-z0-9][a-z0-9_-]*$/ ||
    $3 !~ /^https:\/\/[^\/[:space:]@?#]+\/[^[:space:]#]*$/ ||
    $4 !~ /^(200|204|206)(,(200|204|206))*$/ ||
    $5 !~ /^(empty|nonempty)$/ { bad=1; next }
    seen[$1]++ { bad=1; next }
    { count++; print }
    END { if (bad || count == 0 || count > 100) exit 1 }
' "$targets" > "$work/catalog" || fail 'Invalid/empty/oversized target catalog'
# Ignore inherited proxy settings and ~/.curlrc. Never disable TLS verification.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
uid=$(id -u) || exit 2
printf '# scope=http-reachability path=%s uid=%s family=%s transparent=NOT_VERIFIED udp=NOT_TESTED\n' "$probe_path" "$uid" "$family"
if [ "$probe_path" = native ] && [ "$uid" = 0 ]; then
    printf '# WARNING: native UID 0 is excluded by the default TUN config; this is a root-path comparison, not an app verdict.\n'
fi
printf 'id\tgroup\tround\tresult\thttp_code\tcurl_exit\tdns_s\tconnect_s\ttls_s\tttfb_s\ttotal_s\tbytes\tredirects\n'

probe() {
    seq=$1; name=$2; group=$3; url=$4; expected=$5; body=$6; round=$7
    set -- --proxy '' --noproxy '*'
    if [ "$probe_path" = mixed ]; then
        set -- --proxy "socks5h://127.0.0.1:$proxy_port" --noproxy ''
    fi
    case "$family" in 4) set -- "$@" -4 ;; 6) set -- "$@" -6 ;; esac
    connect_timeout=4
    [ "$timeout" -ge 4 ] || connect_timeout=$timeout
    curl_pid=''
    stop_probe() {
        if [ -n "$curl_pid" ]; then
            kill "$curl_pid" 2>/dev/null || :
            wait "$curl_pid" 2>/dev/null || :
        fi
        exit 143
    }
    trap stop_probe INT TERM
    "$curl_bin" -q "$@" --silent --show-error --globoff \
        --proto '=https' --proto-redir '=https' --location --max-redirs 5 \
        --connect-timeout "$connect_timeout" --max-time "$timeout" --retry 0 \
        --max-filesize 2097152 --limit-rate 131072 --output /dev/null \
        --write-out '%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}\t%{size_download}\t%{num_redirects}\n' \
        "$url" > "$work/metrics.$seq" 2>/dev/null &
    curl_pid=$!
    rc=0
    wait "$curl_pid" || rc=$?
    curl_pid=''
    # Transport errors take precedence even if headers already said HTTP 200.
    awk -F '\t' -v rc="$rc" -v name="$name" -v group="$group" \
        -v round="$round" -v expected="$expected" -v body="$body" '
    NR == 1 {
        valid=(NF == 8 && $1 ~ /^[0-9][0-9][0-9]$/)
        for (i=2; i<=8; i++) if ($i !~ /^[0-9]+([.][0-9]+)?$/) valid=0
        for (i=1; i<=8; i++) v[i]=$i
    }
    END {
        if (NR != 1) valid=0
        if (!valid) { v[1]="000"; for (i=2;i<=8;i++) v[i]=0 }
        status="CURL_ERROR"
        if (rc == 5 || rc == 6) status="DNS_ERROR"
        else if (rc == 7) status="CONNECT_ERROR"
        else if (rc == 28) status="TIMEOUT"
        else if (rc == 35) status="TLS_ERROR"
        else if (rc == 51 || rc == 60 || rc == 77) status="TLS_CERT_ERROR"
        else if (rc == 47) status="REDIRECT_LOOP"
        else if (rc == 63) status="DATA_LIMIT"
        else if (rc == 1 || rc == 2 || rc == 3 || rc == 4) status="PROTOCOL_OR_TOOL_ERROR"
        else if (rc == 0) {
            status="HTTP_ERROR"
            if (!valid) status="BAD_METRICS"
            else if (v[1] == "401" || v[1] == "403") status="RESTRICTED"
            else if (v[1] == "429") status="RATE_LIMITED"
            else if (v[1] == "404" || v[1] == "410") status="ENDPOINT_CHANGED"
            else if (index("," expected ",", "," v[1] ",")) {
                status="PASS"
                if (body == "nonempty" && v[7]+0 == 0) status="EMPTY_BODY"
                if (body == "empty" && v[7]+0 != 0) status="UNEXPECTED_BODY"
            }
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s", name,group,round,status,v[1],rc
        for (i=2;i<=8;i++) printf "\t%s",v[i]
        printf "\n"
    }' "$work/metrics.$seq"
}
seq=0
batch_start=1
finish_batch() {
    for pid in $pids; do wait "$pid" || :; done
    pids=''
    index=$batch_start
    while [ "$index" -le "$seq" ]; do
        [ -s "$work/result.$index" ] || { printf 'Probe worker failed\n' >&2; exit 2; }
        cat "$work/result.$index"
        cat "$work/result.$index" >> "$work/results"
        index=$((index + 1))
    done
    batch_start=$((seq + 1))
}
round=1
while [ "$round" -le "$rounds" ]; do
    while IFS="$(printf '\t')" read -r name group url expected body; do
        seq=$((seq + 1))
        probe "$seq" "$name" "$group" "$url" "$expected" "$body" "$round" > "$work/result.$seq" &
        pids="$pids $!"
        [ $((seq - batch_start + 1)) -lt "$jobs" ] || finish_batch
    done < "$work/catalog"
    round=$((round + 1))
done
finish_batch
awk -F '\t' -v requested="$seq" '
    { total++; if ($4 == "PASS") passed++; else failed++ }
    END {
        printf "# total=%d passed=%d failed=%d scope=http-reachability-only\n", total,passed,failed
        if (total != requested) exit 2
        if (failed) exit 1
    }
' "$work/results"
