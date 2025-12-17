# shellcheck shell=ash
################################################################################
#
# compat.sh - compatibility helper functions for various installers/runtimes
#
# Provides:
#   - boot2serviceif: when running under Magisk, rename boot-completed.sh -> service/service.sh
#
# Usage:
#   . "$MODPATH/lib/kam_utils/compat.sh"
#   boot2serviceif "magisk"
#
################################################################################

# boot2serviceif <env>
# If <env> is "magisk" and Magisk is detected, attempt to rename:
#   $MODPATH/boot-completed.sh -> $MODPATH/service (or $MODPATH/service.sh)
# The function is safe (no-op) if $MODPATH not set, source missing, or target exists.
boot2serviceif() {
    env="$1"

    # No arg -> nothing to do
    [ -z "$env" ] && return 0

    # Currently only support "magisk"
    [ "$env" != "magisk" ] && return 0

    # Detect Magisk: check common Magisk indicators
    # MAGISK_VER / MAGISK_VER_CODE are commonly provided in Magisk installer env
    if [ -z "${MAGISK_VER:-}" ] && [ -z "${MAGISK_VER_CODE:-}" ] && [ "${MAGISK:-}" != "true" ]; then
        # Not Magisk — nothing to do
        return 0
    fi

    # Ensure MODPATH is available
    if [ -z "${MODPATH:-}" ]; then
        # try fallback to current dir; otherwise warn and return non-zero
        if [ -z "${PWD:-}" ]; then
            printf '%s\n' "boot2serviceif: MODPATH not set, cannot perform rename" >&2
            return 1
        fi
        # fall back (best-effort)
        MODPATH="${PWD}"
    fi

    src="${MODPATH}/boot-completed.sh"
    dst="${MODPATH}/service"
    dst_sh="${dst}.sh"

    # Only proceed if source exists
    [ ! -f "$src" ] && return 0

    # If destination already exists, skip to avoid overwriting
    if [ -f "$dst" ] || [ -f "$dst_sh" ]; then
        if command -v ui_print >/dev/null 2>&1; then
            ui_print "- service or service.sh already exists; skipping rename"
        else
            printf '%s\n' "- service or service.sh already exists; skipping rename"
        fi
        return 0
    fi

    # Try renaming to $MODPATH/service first, then fallback to service.sh
    if mv "$src" "$dst" 2>/dev/null; then
        if command -v set_perm >/dev/null 2>&1; then
            set_perm "$dst" 0 0 0755
        else
            chmod 0755 "$dst" 2>/dev/null || true
        fi
        if command -v ui_print >/dev/null 2>&1; then
            ui_print "- Renamed boot-completed.sh -> service (Magisk)"
        else
            printf '%s\n' "- Renamed boot-completed.sh -> service (Magisk)"
        fi
        return 0
    elif mv "$src" "$dst_sh" 2>/dev/null; then
        if command -v set_perm >/dev/null 2>&1; then
            set_perm "$dst_sh" 0 0 0755
        else
            chmod 0755 "$dst_sh" 2>/dev/null || true
        fi
        if command -v ui_print >/dev/null 2>&1; then
            ui_print "- Renamed boot-completed.sh -> service.sh (Magisk)"
        else
            printf '%s\n' "- Renamed boot-completed.sh -> service.sh (Magisk)"
        fi
        return 0
    else
        if command -v ui_print >/dev/null 2>&1; then
            ui_print "- Failed to rename boot-completed.sh to service/service.sh"
        else
            printf '%s\n' "- Failed to rename boot-completed.sh to service/service.sh" >&2
        fi
        return 1
    fi
}
