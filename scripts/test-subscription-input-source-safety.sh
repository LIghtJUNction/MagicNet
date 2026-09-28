#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
cleanup() {
    exec 3<&- 4<&- 5<&- 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

export MODDIR="$WORKDIR/module"
mkdir -p \
    "$MODDIR/.config/sing-box" \
    "$MODDIR/.state/sing-box/subscription-work"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
import() { :; }

# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

# This journal-mechanics fixture models core acceptance for named generations.
# Real JSON validation and failed core checks are covered by baseline-safety.
magicnet_singbox_recovery_config_valid() {
    case "$(cat "$1" 2>/dev/null)" in
    active-config) return 0 ;;
    *) return 1 ;;
    esac
}

printf '%s\n' active-config >"$MODDIR/.config/sing-box/config.json"
printf '%s\n' active-url >"$MODDIR/.config/sing-box/subscription.url"
printf '%s\n' active-work >"$MODDIR/.state/sing-box/subscription-work/marker"
TRANSACTION="$MODDIR/.state/sing-box/subscription-transaction"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

assert_rejected_path() {
    _label="$1"
    _path="$2"
    if magicnet_singbox_input_source_usable "$_path"; then
        fail "accepted unusable subscription source (${_label})"
    fi
}

assert_usable_path() {
    _label="$1"
    _path="$2"
    if ! magicnet_singbox_input_source_usable "$_path"; then
        fail "rejected usable subscription source (${_label})"
    fi
}

no_journal() {
    [ ! -e "$TRANSACTION" ] || fail "transaction journal leaked"
    [ -z "$(find "$MODDIR/.state/sing-box" -maxdepth 1 -name 'subscription-transaction.new.*' -print -quit)" ] ||
        fail "transaction staging directory leaked"
}

reset_begin() {
    rm -rf "$TRANSACTION" "${TRANSACTION}.new."* 2>/dev/null || true
    _sub_source_mode=local
    _sub_was_running=0
    _sub_generation_id=input-source-fixture
}

begin_with() {
    reset_begin
    _sub_input_source="$1"
    magicnet_singbox_transaction_begin
}

# Helper rejects empty, missing, named-path, and non-self fd paths.
: >"$WORKDIR/empty.src"
printf '%s\n' candidate >"$WORKDIR/named.src"
ln -s "$WORKDIR/named.src" "$WORKDIR/named.link"
mkdir -p "$WORKDIR/dir.src"
assert_rejected_path empty "$WORKDIR/empty.src"
assert_rejected_path missing "$WORKDIR/missing.src"
assert_rejected_path named-symlink "$WORKDIR/named.link"
assert_rejected_path directory "$WORKDIR/dir.src"
assert_rejected_path other-proc-pid "/proc/1/fd/1"
assert_rejected_path padded-fd "/proc/self/fd/03"
assert_rejected_path extra-component "/proc/self/fd/1/../fd/1"
assert_usable_path regular-file "$WORKDIR/named.src"

# Inherited descriptor of a still-named regular file is the CLI-compatible form.
exec 3<"$WORKDIR/named.src"
assert_usable_path inherited-fd /proc/self/fd/3
assert_rejected_path traversal-from-fd /proc/self/fd/3/../fd/3

# Official payload apply unlinks the candidate inode before spawn.
printf '%s\n' anonymous-candidate >"$WORKDIR/anon.src"
exec 4<"$WORKDIR/anon.src"
rm -f "$WORKDIR/anon.src"
assert_usable_path unlinked-fd /proc/self/fd/4
: >"$WORKDIR/empty-anon.src"
exec 5<"$WORKDIR/empty-anon.src"
rm -f "$WORKDIR/empty-anon.src"
assert_rejected_path empty-unlinked-fd /proc/self/fd/5

# Named path symlink still cannot open a journal.
if begin_with "$WORKDIR/named.link"; then
    fail "transaction begin accepted a named symlink"
fi
no_journal
[ -f "$WORKDIR/named.src" ] || fail "named symlink reject deleted the target"

# Regular file still publishes a journal and is consumed after copy.
if ! begin_with "$WORKDIR/named.src"; then
    fail "transaction begin rejected a regular file"
fi
[ "$(<"$TRANSACTION/input-source")" = candidate ] || fail "journal lost regular-file bytes"
[ "$(<"$TRANSACTION/input-mode")" = local ] || fail "journal lost local source mode"
[ ! -e "$WORKDIR/named.src" ] || fail "named candidate was not consumed after copy"
rm -rf "$TRANSACTION"

# Unlinked /proc/self/fd handle copies into the journal without needing a name.
if ! begin_with /proc/self/fd/4; then
    fail "transaction begin rejected the official inherited fd source"
fi
[ "$(<"$TRANSACTION/input-source")" = anonymous-candidate ] ||
    fail "journal lost inherited-fd bytes"
[ -f /proc/self/fd/4 ] || fail "inherited fd was closed by transaction begin"
[ "$(cat /proc/self/fd/4)" = anonymous-candidate ] ||
    fail "inherited fd inode changed during transaction begin"
rm -rf "$TRANSACTION"

# An empty inherited descriptor still fails closed before a journal exists.
if begin_with /proc/self/fd/5; then
    fail "transaction begin accepted an empty inherited fd"
fi
no_journal

printf '%s\n' 'subscription input source fd/symlink safety test passed'
