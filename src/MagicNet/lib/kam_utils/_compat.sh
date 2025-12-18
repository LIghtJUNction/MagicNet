#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# Compat - internal implementation (private)
# -----------------------------------------------------------------------------
# This file contains the internal implementation for compatibility helpers
# (functions that adjust behavior depending on the runtime/install environment).
#
# Public wrapper (compat.sh) should source this file (via kam_source_impl or
# direct inclusion) and expose thin wrappers that call the underscored
# functions implemented here.
# =============================================================================

# Internal print helper - use the best available printing function
# (prefers `msg`/`ui_print`/`pprint`, falls back to writing to OUTFD or stdout).
_compat__print() {
    _m="$1"
    if command -v msg >/dev/null 2>&1; then
        msg "$_m"
        return 0
    fi

    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$_m"
        return 0
    fi

    if command -v pprint >/dev/null 2>&1; then
        pprint "$_m"
        return 0
    fi

    # If OUTFD is set (some installers read /proc/self/fd/$OUTFD), use that channel:
    if [ -n "${OUTFD:-}" ]; then
        printf '%s\n' "ui_print $_m" >>"/proc/self/fd/$OUTFD" 2>/dev/null || printf '%s\n' "$_m"
        printf '%s\n' "ui_print" >>"/proc/self/fd/$OUTFD" 2>/dev/null || true
        return 0
    fi

    # Final fallback: plain stdout
    printf '%s\n' "$_m"
}

# _boot2serviceif_impl <env>
# Move/rename boot-completed.sh -> service (or service.sh) when appropriate.
# Designed for handling Magisk compatibility where service files are expected.
#
# Returns:
#   0 on success / nothing-to-do
#   1 on failure
_boot2serviceif_impl() {
    env="$1"

    # no-op if no env specified
    [ -n "$env" ] || return 0

    # currently only implemented for magisk behavior
    case "$env" in
        magisk) ;;
        *) return 0 ;;
    esac

    # If running under KernelSU/APatch, do nothing
    if [ "${KSU:-}" = "true" ] || [ "${APATCH:-}" = "true" ]; then
        return 0
    fi

    # Quick detection for Magisk-like environment; bail out if none detected
    if [ -z "${MAGISK_VER:-}" ] && [ -z "${MAGISK_VER_CODE:-}" ] && [ "${MAGISK:-}" != "true" ]; then
        _compat__print "boot2serviceif: not a Magisk environment; skipping"
        return 0
    fi

    # Ensure MODPATH is set (try fallback to current working dir as last resort)
    if [ -z "${MODPATH:-}" ]; then
        if [ -n "${PWD:-}" ]; then
            MODPATH="${PWD}"
        else
            _compat__print "boot2serviceif: MODPATH not set, cannot perform rename" >&2
            return 1
        fi
    fi

    src="${MODPATH}/boot-completed.sh"
    dst="${MODPATH}/service"
    dst_sh="${dst}.sh"

    # Nothing to do if source missing
    [ -f "$src" ] || return 0

    # If service or service.sh already exists, skip to avoid overwriting
    if [ -f "$dst" ] || [ -f "$dst_sh" ]; then
        _compat__print "- service or service.sh already exists; skipping rename"
        return 0
    fi

    # Try to rename to $MODPATH/service first
    if mv "$src" "$dst" 2>/dev/null; then
        if command -v set_perm >/dev/null 2>&1; then
            # Use set_perm if available (host/build helpers)
            set_perm "$dst" 0 0 0755
        else
            chmod 0755 "$dst" 2>/dev/null || true
        fi

        _compat__print "- Renamed boot-completed.sh -> service (Magisk)"
        return 0
    elif mv "$src" "$dst_sh" 2>/dev/null; then
        # fallback to service.sh
        if command -v set_perm >/dev/null 2>&1; then
            set_perm "$dst_sh" 0 0 0755
        else
            chmod 0755 "$dst_sh" 2>/dev/null || true
        fi

        _compat__print "- Renamed boot-completed.sh -> service.sh (Magisk)"
        return 0
    else
        _compat__print "- Failed to rename boot-completed.sh to service/service.sh" >&2
        return 1
    fi
}

# End of _compat.sh
