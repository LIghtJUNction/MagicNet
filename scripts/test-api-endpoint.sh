#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MODDIR="$WORK/module"
TRACE="$WORK/curl.trace"
mkdir -p "$MODDIR"
: >"$TRACE"
export MODDIR TRACE

cat >"$MODDIR/cli" <<'SH'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = api ] && [ "$2" = endpoint ]; then
    printf '%s\n' 'http://127.0.0.1:19090'
    exit 0
fi
exit 64
SH
chmod +x "$MODDIR/cli"

magicnet_cmd_exists() {
    [ "$1" = curl ]
}

curl() {
    printf '%s\n' "$*" >>"$TRACE"
    printf '%s\n' '{"proxies":{"proxy":{"type":"Selector"}}}'
}

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/api.sh"

endpoint="$(magicnet_singbox_api_endpoint)"
[ "$endpoint" = 'http://127.0.0.1:19090' ] || {
    printf 'unexpected resolved endpoint: %s\n' "$endpoint" >&2
    exit 1
}

magicnet_singbox_api_has_nodes || {
    printf 'dynamic sing-box API node probe failed\n' >&2
    exit 1
}

grep -Fq 'http://127.0.0.1:19090/proxies' "$TRACE" || {
    printf 'node probe did not use the resolved endpoint\n' >&2
    cat "$TRACE" >&2
    exit 1
}

if grep -Fq '9090' "$TRACE"; then
    printf 'node probe regressed to a hard-coded 9090 endpoint\n' >&2
    cat "$TRACE" >&2
    exit 1
fi

printf 'runtime API endpoint regression tests passed\n'
