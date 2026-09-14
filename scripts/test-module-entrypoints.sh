#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/src/MagicNet/lib/magicnet/entry.sh"

fail() {
    printf 'module entrypoint test failed: %s\n' "$*" >&2
    exit 1
}

for script in service.sh action.sh boot-completed.sh; do
    first_line=$(head -n 1 "$ROOT/src/MagicNet/$script")
    [[ "$first_line" == '#!/system/bin/sh' ]] || fail "$script is not directly executable by Android's shell"
done

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/lib/kamfw" "$fixture/lib"
printf '%s\n' 'import() { :; }' > "$fixture/lib/kamfw/.kamfwrc"
: > "$fixture/lib/magicnet.sh"

MODDIR="$fixture" sh -c '. "$1"' entry-test "$ENTRY" || fail 'valid bootstrap fixture did not load'

rm -f "$fixture/lib/kamfw/.kamfwrc"
set +e
output=$(MODDIR="$fixture" sh -c '. "$1"' entry-test "$ENTRY" 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || fail 'missing framework bootstrap unexpectedly succeeded'
[[ "$output" == *'MagicNet: required framework file is missing:'* ]] || fail 'missing framework error is not actionable'
[[ "$output" != *'abort: not found'* ]] || fail 'missing framework path still calls an undefined abort helper'

printf 'module entrypoint regression passed\n'
