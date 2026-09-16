#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export MODDIR="$fixture/module"
mkdir -p "$MODDIR/bin" "$MODDIR/.config/sing-box" "$MODDIR/.state/sing-box/subscription-work"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"
import() { :; }
info() { :; }
warn() { :; }
error() { :; }
success() { :; }
. "$ROOT/src/MagicNet/lib/magicnet/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"

# Exercise the production JSON and checkpoint validators, with an explicit
# fake core that can reject semantically invalid JSON or time out independently.
cat >"$MODDIR/bin/sing-box" <<'CORE'
#!/bin/sh
[ "$1" = check ] && [ "$2" = -c ] || exit 99
[ ! -f "$MODDIR/reject-check" ] || exit 42
jq -e '(.invalid != true) and (.inbounds | length > 0) and (.outbounds | length > 0)' "$3" >/dev/null
CORE
chmod +x "$MODDIR/bin/sing-box"
active="$MODDIR/.config/sing-box/config.json"
checkpoint="$MODDIR/.state/sing-box/last-good-config.json"
transaction="$MODDIR/.state/sing-box/subscription-transaction"
source_file="$MODDIR/.config/sing-box/subscription.url"
printf '%s\n' 'https://example.com/fixture' >"$source_file"
printf '%s\n' '{"inbounds":[{"type":"tun","tag":"tun-in"}],"outbounds":[{"type":"direct","tag":"direct"}]}' >"$active"
cp "$active" "$fixture/valid"
printf 'old-work\n' >"$MODDIR/.state/sing-box/subscription-work/marker"
magicnet_singbox_save_last_good
cp "$checkpoint" "$fixture/checkpoint"

begin() {
  _sub_input_source="$source_file"
  _sub_source_mode=url
  _sub_was_running=0
  _sub_generation_id=baseline-fixture
  magicnet_singbox_transaction_begin
}
no_journal() {
  test ! -e "$transaction"
  test -z "$(find "${transaction%/*}" -maxdepth 1 -name 'subscription-transaction.new.*' -print -quit)"
}

# An empty active file is recovered and validated before being snapshotted.
: >"$active"
begin
magicnet_singbox_recovery_config_valid "$transaction/old-config"
cmp "$active" "$transaction/old-config"
test "$(cat "$transaction/old-work/marker")" = old-work
# Failed/uncommitted generations cannot replace the checkpoint.
printf '%s\n' '{"inbounds":[{}],"outbounds":[{}],"candidate":true}' >"$active"
if magicnet_singbox_save_last_good; then exit 1; fi
cmp "$checkpoint" "$fixture/checkpoint"
magicnet_singbox_transaction_reconcile
magicnet_singbox_recovery_config_valid "$active"
no_journal

# No checkpoint + broken active must fail before staging, fetching or restart.
for invalid in '' 'null' '[]' '{' '{"inbounds":[],"outbounds":[]}'; do
  rm -f "$checkpoint"
  printf '%s' "$invalid" >"$active"
  cp "$active" "$fixture/before"
  if begin; then echo 'accepted an invalid rollback baseline' >&2; exit 1; fi
  cmp "$active" "$fixture/before"
  no_journal
  test "$(cat "$MODDIR/.state/sing-box/subscription-work/marker")" = old-work
done

# Core rejection, timeout and an incompatible checkpoint fail closed as well.
cp "$fixture/checkpoint" "$checkpoint"
: >"$active"
touch "$MODDIR/reject-check"
if begin; then exit 1; fi
rm "$MODDIR/reject-check"
no_journal
test ! -s "$active"
timeout() { return 124; }
if begin; then exit 1; fi
unset -f timeout
no_journal
test ! -s "$active"
jq '.mode="ebpf"' "$fixture/checkpoint" >"$checkpoint"
if begin; then exit 1; fi
no_journal
test ! -s "$active"

# Structurally valid but core-invalid user edits are not silently overwritten.
cp "$fixture/checkpoint" "$checkpoint"
jq '.invalid=true' "$fixture/valid" >"$active"
cp "$active" "$fixture/before"
if begin; then exit 1; fi
cmp "$active" "$fixture/before"
no_journal

# Check the bytes actually copied, not just the file before the copy.
cp "$fixture/valid" "$active"
cp() {
  case "${*: -1}" in */old-config) : >"${*: -1}" ;; *) command cp "$@" ;; esac
}
if begin; then exit 1; fi
unset -f cp
cmp "$active" "$fixture/valid"
no_journal

# An old/damaged journal never destroys a usable active config or work tree.
mkdir -p "$transaction"
touch "$transaction/had-config" "$transaction/old-config"
if magicnet_singbox_transaction_reconcile; then exit 1; fi
cmp "$active" "$fixture/valid"
test "$(cat "$MODDIR/.state/sing-box/subscription-work/marker")" = old-work
test -d "$transaction"
rm -rf "$transaction"

# A validated commit can advance the checkpoint only after journal removal.
magicnet_singbox_save_last_good
magicnet_singbox_recovery_config_valid "$active"
no_journal
printf 'Subscription rollback baseline and checkpoint safety passed\n'
