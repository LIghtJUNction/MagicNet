#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-singbox-preflight.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

export MODDIR="$FIXTURE/module"
mkdir -p "$MODDIR/bin"
ln -s "$(command -v jq)" "$MODDIR/bin/jq"

import() { :; }
set_i18n() { :; }
i18n() { printf '%s' "$1"; }
info() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; }
success() { :; }
print() { printf '%s\n' "$*"; }

# shellcheck disable=SC1090
. "$ROOT/src/MagicNet/lib/kamfw/__singbox__.sh"

TUN_MARKER="$FIXTURE/tun-called"
singbox_tun() { : >"$TUN_MARKER"; }

cat >"$FIXTURE/ebpf.json" <<'JSON'
{"inbounds":[{"type":"mixed","tag":"mixed-in"},{"type":"ebpf","tag":"tun-in","mode":"local","network":"tcp,udp"}]}
JSON
singbox_prepare_dataplane "$FIXTURE/ebpf.json"
test ! -e "$TUN_MARKER" || {
  echo "eBPF preflight unexpectedly checked the TUN device" >&2
  exit 1
}

cat >"$FIXTURE/tun.json" <<'JSON'
{"inbounds":[{"type":"mixed","tag":"mixed-in"},{"type":"tun","tag":"custom-transparent","interface_name":"custom-tun"}]}
JSON
singbox_prepare_dataplane "$FIXTURE/tun.json"
test -e "$TUN_MARKER" || {
  echo "TUN preflight did not check the kernel TUN device" >&2
  exit 1
}
rm -f "$TUN_MARKER"

cat >"$FIXTURE/duplicate.json" <<'JSON'
{"inbounds":[{"type":"tun","tag":"tun-in"},{"type":"ebpf","tag":"tun-in"}]}
JSON
if singbox_prepare_dataplane "$FIXTURE/duplicate.json" >/dev/null 2>&1; then
  echo "duplicate managed transparent inbounds were accepted" >&2
  exit 1
fi
test ! -e "$TUN_MARKER"

cat >"$FIXTURE/missing.json" <<'JSON'
{"inbounds":[{"type":"mixed","tag":"mixed-in"}]}
JSON
singbox_prepare_dataplane "$FIXTURE/missing.json"
test ! -e "$TUN_MARKER" || {
  echo "config without a transparent inbound unexpectedly checked TUN" >&2
  exit 1
}

printf '%s\n' "sing-box dataplane preflight test passed"
