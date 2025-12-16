#!/bin/bash

. "$KAM_HOOKS_ROOT/lib/utils.sh"

if [ "$KAM_INTERACTIVE" = "1" ]; then
    log_info "Interactive mode enabled"

    require_command adb "adb not found!"

    # Collect connected adb device IDs (ignore header and offline lines)
    mapfile -t ADB_DEVICES < <(adb devices | awk 'NR>1 && NF>=2 && $2 != "offline" {print $1}')

    if [ ${#ADB_DEVICES[@]} -eq 0 ]; then
        log_warn "No adb devices detected"
        prompt DEVICE "No adb devices found. Enter device id" ""
    else
        # Default to the first device id (string) and pass all devices as options
        choice DEVICE "Select device" "${ADB_DEVICES[0]}" "${ADB_DEVICES[@]}"
    fi

    # choice module manager
    choice MODULE_MANAGER "Select" "ksud" "apud" "magisk"
    # push package to device and install via the selected module manager
    module_zip="${KAM_DIST_DIR:-$KAM_PROJECT_ROOT/dist}/$KAM_MODULE_ID.zip"
    remote_zip="/sdcard/kam/tmp/$KAM_MODULE_ID.zip"
    adb shell "su -c 'mkdir -p /sdcard/kam/tmp'" >/dev/null 2>&1 || true
    adb push "$module_zip" "$remote_zip"

    case "$MODULE_MANAGER" in
        ksud)
            adb shell "su -c 'ksud module install $remote_zip'"
            ;;
        apud)
            # Replace the following with the correct apud command if different
            adb shell "su -c 'apud module install $remote_zip'"
            ;;
        magisk)
            adb shell "su -c 'magisk --install-module $remote_zip'"
            ;;
        *)
            log_error "Unknown installer: $MODULE_MANAGER"
            exit 1
            ;;
    esac

    choice IF_REBOOT "Reboot device after installation?" "yes" "no"
    if [ "$IF_REBOOT" = "yes" ]; then
        adb reboot
    fi

elif [ "$KAM_INTERACTIVE" = "false" ]; then
    log_info "kam build -i to enable interactive mode"
fi
