#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MODDIR="$WORK/module"
mkdir -p "$MODDIR"
export MODDIR

cat >"$MODDIR/cli" <<'SH'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = api ] && [ "$2" = endpoint ]; then
    printf '%s\n' 'http://127.0.0.1:19090'
    exit 0
fi
exit 64
SH
chmod +x "$MODDIR/cli"

ss() {
    printf '%s\n' 'LISTEN 0 4096 127.0.0.1:19090 0.0.0.0:* users:(("sing-box",pid=4321,fd=8))'
}

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/api.sh"

endpoint="$(magicnet_singbox_api_endpoint)"
[ "$endpoint" = 'http://127.0.0.1:19090' ] || {
    printf 'unexpected resolved endpoint: %s\n' "$endpoint" >&2
    exit 1
}

port="$(magicnet_singbox_api_port)"
[ "$port" = '19090' ] || {
    printf 'unexpected resolved API port: %s\n' "$port" >&2
    exit 1
}

magicnet_singbox_listener_owned 4321 || {
    printf 'listener ownership did not follow configured API port\n' >&2
    exit 1
}
if magicnet_singbox_listener_owned 9999; then
    printf 'listener ownership ignored the expected sing-box pid\n' >&2
    exit 1
fi

for runtime_file in \
    "$ROOT/src/MagicNet/lib/magicnet/common.sh" \
    "$ROOT/src/MagicNet/lib/magicnet/core.sh" \
    "$ROOT/src/MagicNet/lib/magicnet/action_menu.sh" \
    "$ROOT/src/MagicNet/lib/magicnet/api.sh"; do
    if grep -Fq '127.0.0.1:9090' "$runtime_file"; then
        printf 'runtime source still hard-codes the default controller: %s\n' "$runtime_file" >&2
        exit 1
    fi
done

printf 'runtime API endpoint regression tests passed\n'
