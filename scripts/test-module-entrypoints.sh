#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/src/MagicNet/lib/magicnet/entry.sh"
ACTION_MENU="$ROOT/src/MagicNet/lib/magicnet/action_menu.sh"

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

# The action menu is sourced by Kamfw after i18n is available. Stub only that
# registration hook here so the diagnostic helpers can be exercised directly.
set_i18n() { :; }
# shellcheck source=/dev/null
. "$ACTION_MENU"
export MODDIR="$fixture"
printf '%s\n' 'version=v9.9.9' > "$fixture/module.prop"
magicnet_transparent_mode() { printf '%s\n' ebpf; }
[[ "$(magicnet_diag_module_version)" == v9.9.9 ]] || fail 'diagnostics did not report the module version'
[[ "$(magicnet_diag_transparent_mode)" == ebpf ]] || fail 'diagnostics did not report transparent mode'

cat > "$fixture/network-check.sh" <<'EOF'
printf '%s\n' "$*" > "$MODDIR/network-check.args"
EOF
magicnet_action_network_acceptance || fail 'network acceptance action failed to launch'
[[ "$(cat "$fixture/network-check.args")" == '--rounds 1 --jobs 4' ]] || fail 'network acceptance action used unexpected arguments'

printf 'module entrypoint regression passed\n'
