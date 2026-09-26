#!/usr/bin/env bash
# Body loaded by fake-magisk-smoke.sh's write_mock; no network is performed.
set -euo pipefail
out=""
url=""
write_out=""
header_out=""
fail_http=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            out="${2:?missing output path}"
            shift 2
            ;;
        -w|--write-out)
            write_out="${2:?missing write-out format}"
            shift 2
            ;;
        -D|--dump-header)
            header_out="${2:?missing header path}"
            shift 2
            ;;
        -x|--proxy|--max-time|--connect-timeout|-H|--header|--data|--data-binary|--max-redirs|--proto|--proto-redir|--max-filesize|--resolve|--user-agent|--noproxy)
            [[ $# -ge 2 ]] || exit 2
            shift 2
            ;;
        -f|-fs|--fail)
            fail_http=1
            shift
            ;;
        --*) shift ;;
        -*) shift ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
render_http_metrics() {
    local code="$1" connect="$2" start="$3" total="$4"
    local rendered="$write_out"
    rendered="${rendered//\%\{http_code\}/$code}"
    rendered="${rendered//\%\{redirect_url\}/}"
    rendered="${rendered//\%\{time_connect\}/$connect}"
    rendered="${rendered//\%\{time_starttransfer\}/$start}"
    rendered="${rendered//\%\{time_total\}/$total}"
    printf '%b' "$rendered"
}
emit_headers() {
    local code="$1"
    [[ -n "$header_out" ]] || return 0
    if [[ "$header_out" == '-' ]]; then
        printf 'HTTP/1.1 %s Fixture\r\nContent-Type: application/yaml\r\n\r\n' "$code"
    else
        printf 'HTTP/1.1 %s Fixture\r\nContent-Type: application/yaml\r\n\r\n' "$code" >"$header_out"
    fi
}
if [[ -n "${MAGICNET_FAKE_CURL_FAIL_URL:-}" && "$url" == "$MAGICNET_FAKE_CURL_FAIL_URL" ]]; then
    [[ -z "$write_out" ]] || render_http_metrics 000 0.000 0.000 0.000
    exit 7
fi
if [[ -n "${MAGICNET_FAKE_CURL_HTTP_CODE_URL:-}" && "$url" == "$MAGICNET_FAKE_CURL_HTTP_CODE_URL" ]]; then
    code="${MAGICNET_FAKE_CURL_HTTP_CODE:-429}"
    emit_headers "$code"
    [[ -z "$write_out" ]] || render_http_metrics "$code" 0.010 0.020 0.030
    if [[ "$fail_http" == 1 && "$code" =~ ^[45][0-9][0-9]$ ]]; then
        exit 22
    fi
    exit 0
fi
case "$url" in
    http://127.0.0.1:9090/version)
        printf '%s\n' '{"version":"fake"}'
        exit 0
        ;;
    http://127.0.0.1:9090/providers/proxies*)
        printf '%s\n' '{"providers":{"premium_a":{"proxies":[{"name":"fake-node","type":"VMess"}]}}}'
        exit 0
        ;;
    http://127.0.0.1:9090/proxies*)
        printf '%s\n' '{"proxies":{"fake-node":{"name":"fake-node","type":"VMess"}},"all":["fake-node"]}'
        exit 0
        ;;
    http://127.0.0.1:7892*|https://www.baidu.com|https://www.google.com|https://chatgpt.com)
        emit_headers 200
        if [[ -n "$write_out" ]]; then
            render_http_metrics 200 0.010 0.020 0.030
        else
            printf '%s\n' 'HTTP/1.1 200 OK'
        fi
        exit 0
        ;;
esac
emit_subscription_fixture() {
    cat <<YAML
proxies:
  - name: fresh-sub-node
    type: vmess
    server: 127.0.0.1
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    alterId: 0
    cipher: auto
YAML
    printf '%b' '    tls: true\n    servername: "edge.example\r.test"\n'
}
if [[ -n "$out" ]]; then
    emit_headers 200
    if [[ "$out" == '-' ]]; then
        emit_subscription_fixture
    else
        emit_subscription_fixture >"$out"
    fi
    # curl writes transfer metadata after the body, including when -o is a FIFO.
    [[ -z "$write_out" ]] || render_http_metrics 200 0.010 0.020 0.030
    exit 0
fi
printf '%s\n' '{}'
