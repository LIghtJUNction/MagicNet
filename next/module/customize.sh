#!/system/bin/sh
# shellcheck shell=ash
# KernelSU sources this file. Do not exec, exit, poll keys, or source user data.
case "${ARCH:-}" in
    arm64) expected_abi=aarch64-linux-android ;;
    x64) expected_abi=x86_64-linux-android ;;
    *) abort "MagicNet Next: unsupported device architecture" ;;
esac
IFS= read -r package_abi < "$MODPATH/abi" || abort "MagicNet Next: ABI metadata is missing"
[ "$package_abi" = "$expected_abi" ] || abort "MagicNet Next: package ABI does not match this device"
IFS= read -r module_id < "$MODPATH/module-id" || abort "MagicNet Next: module identity is missing"
case "$module_id" in
    ''|*[!A-Za-z0-9._-]*) abort "MagicNet Next: invalid module identity" ;;
esac
for binary in magicnet-cli sing-box curl yq; do
    set_perm "$MODPATH/bin/$binary" 0 0 0755
done
for hook in service.sh boot-completed.sh action.sh uninstall.sh; do
    set_perm "$MODPATH/$hook" 0 0 0755
done
previous="/data/adb/modules/$module_id"
if [ -f "$previous/.magicnet-candidate.json" ] && [ "$previous" != "$MODPATH" ]; then
    "$MODPATH/bin/magicnet-cli" --root "$MODPATH" --hook install --upgrade-from "$previous" || abort "MagicNet Next: upgrade validation failed; previous data was not changed"
else
    "$MODPATH/bin/magicnet-cli" --root "$MODPATH" --hook install || abort "MagicNet Next: package validation failed"
fi
set_perm_recursive "$MODPATH/.config" 0 0 0700 0600
ui_print "MagicNet Next installed. Existing MagicNet v1 is not replaced."
