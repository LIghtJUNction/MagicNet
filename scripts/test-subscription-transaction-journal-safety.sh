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

# This journal-mechanics fixture models core acceptance for named generations.
# Real JSON validation and failed core checks are covered by baseline-safety.
magicnet_singbox_recovery_config_valid() {
  case "$(cat "$1" 2>/dev/null)" in
  active-config | candidate-config | old-config | stable-config | term-old-config | old-config-without-url-or-work) return 0 ;;
  *) return 1 ;;
  esac
}

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

# A corrupt generation identifier is metadata, never a path for recursive
# cleanup. Reject it before changing the active config, work, or source files.
GENERATION_ROOT="$MODDIR/.state/sing-box/subscription-generations"
UNRELATED_DIR="$MODDIR/.state/sing-box/unrelated-data"
mkdir -p "$GENERATION_ROOT" "$UNRELATED_DIR"
printf '%s\n' preserve-me >"$UNRELATED_DIR/marker"
printf '%s\n' active-local >"$MODDIR/.config/sing-box/subscription.local"
for invalid_generation in '../unrelated-data' . .. 'invalid token' "$(printf '%0129d' 0)"; do
    rm -rf "$TRANSACTION_DIR"
    mkdir -p "$TRANSACTION_DIR/old-work"
    : >"$TRANSACTION_DIR/had-config"
    : >"$TRANSACTION_DIR/had-work"
    : >"$TRANSACTION_DIR/had-url"
    : >"$TRANSACTION_DIR/had-local"
    printf '%s\n' old-config >"$TRANSACTION_DIR/old-config"
    printf '%s\n' old-work >"$TRANSACTION_DIR/old-work/marker"
    printf '%s\n' old-url >"$TRANSACTION_DIR/old-url"
    printf '%s\n' old-local >"$TRANSACTION_DIR/old-local"
    printf '%s\n' "$invalid_generation" >"$TRANSACTION_DIR/generation-id"
    if magicnet_singbox_transaction_reconcile; then
        printf '%s\n' 'transaction recovery accepted an invalid generation identifier' >&2
        exit 1
    fi
    test "$(cat "$MODDIR/.config/sing-box/config.json")" = active-config
    test "$(cat "$MODDIR/.state/sing-box/subscription-work/marker")" = active-work
    test "$(cat "$MODDIR/.config/sing-box/subscription.url")" = active-url
    test "$(cat "$MODDIR/.config/sing-box/subscription.local")" = active-local
    test "$(cat "$UNRELATED_DIR/marker")" = preserve-me
    test -d "$TRANSACTION_DIR"
done

# A valid interrupted generation still restores its backup and removes only
# its own staged files. The malformed journal can be retried after correction.
printf '%s\n' journal-fixture >"$TRANSACTION_DIR/generation-id"
mkdir -p "$GENERATION_ROOT/journal-fixture" "$GENERATION_ROOT/unrelated-generation"
: >"$MODDIR/.config/sing-box/config.json.candidate-journal-fixture"
: >"$MODDIR/.config/sing-box/config.json.candidate-journal-fixture.new"
magicnet_singbox_transaction_reconcile
test "$(cat "$MODDIR/.config/sing-box/config.json")" = old-config
test "$(cat "$MODDIR/.state/sing-box/subscription-work/marker")" = old-work
test "$(cat "$MODDIR/.config/sing-box/subscription.url")" = old-url
test "$(cat "$MODDIR/.config/sing-box/subscription.local")" = old-local
test "$(cat "$UNRELATED_DIR/marker")" = preserve-me
test -d "$GENERATION_ROOT/unrelated-generation"
test ! -e "$GENERATION_ROOT/journal-fixture"
test ! -e "$MODDIR/.config/sing-box/config.json.candidate-journal-fixture"
test ! -e "$MODDIR/.config/sing-box/config.json.candidate-journal-fixture.new"
test ! -e "$TRANSACTION_DIR"
printf '%s\n' 'subscription transaction generation safety test passed'
