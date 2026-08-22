#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MODDIR="$WORK/module"
KAM_HOME="$MODDIR"
export MODDIR KAM_HOME
mkdir -p "$MODDIR/.state/fswatch" "$MODDIR/.state/watchdog"

set_i18n() { :; }

# shellcheck disable=SC1091
. "$ROOT/src/MagicNet/lib/magicnet/supervisors.sh"

magicnet_fswatch_name() { printf '%s\n' magicnet-config; }
magicnet_supervisor_pidfile_matches() {
    printf '%s\n' "$2" >>"$WORK/candidates"
    [ "$2" = 101 ]
}
ps() {
    cat <<EOF
101  sh $MODDIR/.state/fswatch/magicnet-config.loop.sh
202  com.example.unrelated
303  $MODDIR/cli config apply
EOF
}

output="$(magicnet_supervisor_orphan_pids fswatch)"
[ "$output" = 101 ] || {
    printf '%s\n' "unexpected orphan output: $output" >&2
    exit 1
}
[ "$(tr '\n' ' ' <"$WORK/candidates")" = "101 303 " ] || {
    printf '%s\n' 'ps prefilter did not narrow candidates before /proc validation' >&2
    exit 1
}

printf '%s\n' 'supervisor orphan ps-prefilter test passed'
