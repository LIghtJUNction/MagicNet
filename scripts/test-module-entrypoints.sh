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

# entry.sh is normally sourced, but direct execution must still fail cleanly
# instead of falling through after an invalid top-level return.
set +e
output=$(MODDIR="$fixture" sh "$ENTRY" 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || fail 'direct bootstrap execution unexpectedly succeeded without framework'
[[ "$output" == *'MagicNet: required framework file is missing:'* ]] || fail 'direct bootstrap failure lost its diagnostic'
[[ "$output" != *'return:'* ]] || fail 'direct bootstrap failure leaked a shell return error'

# Module entry scripts source entry.sh. A bootstrap failure must stop them before
# they attempt to call Kamfw, rather than turning one actionable error into a
# second misleading "kamfw: not found" failure.
mkdir -p "$fixture/lib/magicnet"
cp "$ENTRY" "$fixture/lib/magicnet/entry.sh"
for script in service.sh action.sh boot-completed.sh; do
    cp "$ROOT/src/MagicNet/$script" "$fixture/$script"
    set +e
    output=$(sh "$fixture/$script" 2>&1)
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "$script unexpectedly continued after bootstrap failure"
    [[ "$output" == *'MagicNet: required framework file is missing:'* ]] || fail "$script hid the bootstrap error"
    [[ "$output" != *'kamfw: not found'* ]] || fail "$script continued into Kamfw after bootstrap failure"
done

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
