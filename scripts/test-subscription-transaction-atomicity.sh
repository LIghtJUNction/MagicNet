#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export MODDIR="$WORKDIR/module"
mkdir -p \
  "$MODDIR/.config/sing-box" \
  "$MODDIR/.state/sing-box/subscription-work" \
  "$MODDIR/.state/sing-box/subscription-transaction/old-work"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
import() { :; }

# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

ACTIVE_WORK="$MODDIR/.state/sing-box/subscription-work"
TRANSACTION="$MODDIR/.state/sing-box/subscription-transaction"
printf '%s\n' current >"$ACTIVE_WORK/marker"
printf '%s\n' old >"$TRANSACTION/old-work/marker"
printf '%s\n' new-config >"$MODDIR/.config/sing-box/config.json"
printf '%s\n' old-config >"$TRANSACTION/old-config"
touch "$TRANSACTION/had-config"
printf '%s\n' new-url >"$MODDIR/.config/sing-box/subscription.url"
printf '%s\n' old-url >"$TRANSACTION/old-url"
touch "$TRANSACTION/had-url" "$TRANSACTION/had-work"

# Fail only on the first move into the active work path.  The production
# recovery must be able to restore the current directory after that failure;
# the old implementation deleted it before attempting the move.
failed_work_move=0
TEST_ACTIVE_WORK="$ACTIVE_WORK"
mv() {
    if [ "$2" = "$TEST_ACTIVE_WORK" ] && [ "$failed_work_move" -eq 0 ]; then
        failed_work_move=1
        return 1
    fi
    command mv "$@"
}

set +e
magicnet_singbox_transaction_reconcile
reconcile_rc=$?
set -e
unset -f mv

[ "$reconcile_rc" -ne 0 ] || {
    printf '%s\n' 'transaction recovery unexpectedly succeeded after work-directory move failure' >&2
    exit 1
}
[ "$(<"$ACTIVE_WORK/marker")" = current ] || {
    printf '%s\n' 'transaction recovery lost the current work directory on failure' >&2
    exit 1
}
[ -d "$TRANSACTION" ] || {
    printf '%s\n' 'failed transaction journal was removed before recovery completed' >&2
    exit 1
}

printf '%s\n' 'subscription transaction atomicity test passed'
