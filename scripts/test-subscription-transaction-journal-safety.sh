#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export MODDIR="$WORKDIR/module"
mkdir -p \
  "$MODDIR/.config/sing-box" \
  "$MODDIR/.state/sing-box/subscription-work"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
import() { :; }

# Fail only the prepared-phase marker write while keeping fixture setup and
# diagnostics on the real printf implementation.
printf() {
    if [ "${1:-}" = '%s\n' ] && [ "${2:-}" = prepared ] &&
        [ "${MAGICNET_TEST_FAIL_JOURNAL_WRITE:-0}" = "1" ]; then
        return 1
    fi
    if [ "${1:-}" = '%s\n' ] && [ "${2:-}" = active-config ] &&
        [ "${MAGICNET_TEST_FAIL_PHASE_WRITE:-0}" = "1" ]; then
        return 1
    fi
    command printf "$@"
}

# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

printf '%s\n' active-config >"$MODDIR/.config/sing-box/config.json"
printf '%s\n' active-url >"$MODDIR/.config/sing-box/subscription.url"
printf '%s\n' active-work >"$MODDIR/.state/sing-box/subscription-work/marker"
INPUT_SOURCE="$WORKDIR/candidate.url"
printf '%s\n' candidate >"$INPUT_SOURCE"

_sub_input_source="$INPUT_SOURCE"
_sub_source_mode=url
_sub_was_running=0
_sub_generation_id=journal-fixture

MAGICNET_TEST_FAIL_JOURNAL_WRITE=1
export MAGICNET_TEST_FAIL_JOURNAL_WRITE
set +e
magicnet_singbox_transaction_begin
begin_rc=$?
set -e
unset MAGICNET_TEST_FAIL_JOURNAL_WRITE

[ "$begin_rc" -ne 0 ] || {
    printf '%s\n' 'transaction journal creation succeeded after a metadata write failure' >&2
    exit 1
}
[ ! -e "$MODDIR/.state/sing-box/subscription-transaction" ] || {
    printf '%s\n' 'transaction journal was published despite an incomplete phase marker' >&2
    exit 1
}
[ -z "$(find "$MODDIR/.state/sing-box" -maxdepth 1 -name 'subscription-transaction.new.*' -print -quit)" ] || {
    printf '%s\n' 'failed transaction journal staging directory leaked' >&2
    exit 1
}

printf '%s\n' 'subscription transaction journal safety test passed'

# Transaction phase metadata is also journal state.  A failed write must not
# truncate the last durable phase or report success to the caller.
TRANSACTION_DIR="$MODDIR/.state/sing-box/subscription-transaction"
mkdir -p "$TRANSACTION_DIR"
printf '%s\n' old-phase >"$TRANSACTION_DIR/phase"
MAGICNET_TEST_FAIL_PHASE_WRITE=1
export MAGICNET_TEST_FAIL_PHASE_WRITE
set +e
magicnet_singbox_transaction_phase active-config
phase_rc=$?
set -e
unset MAGICNET_TEST_FAIL_PHASE_WRITE

[ "$phase_rc" -ne 0 ] || {
    printf '%s\n' 'transaction phase write reported success after a metadata failure' >&2
    exit 1
}
[ "$(<"$TRANSACTION_DIR/phase")" = old-phase ] || {
    printf '%s\n' 'failed transaction phase write truncated the durable phase' >&2
    exit 1
}
[ -z "$(find "$TRANSACTION_DIR" -maxdepth 1 -name 'phase.tmp.*' -print -quit)" ] || {
    printf '%s\n' 'failed transaction phase write leaked its temporary file' >&2
    exit 1
}

printf '%s\n' 'subscription transaction phase safety test passed'
