#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# Internal status helpers - _status.sh
#
# Implements:
#   - _status_msg_impl "message"
#   - _status_ok_impl
#   - _status_fail_impl
#
# These functions are internal implementations and are expected to be
# exposed via a public wrapper (e.g. lib/kam_utils/status.sh).
# =============================================================================

# Print a status message without newline and (if supported) save cursor.
# Usage: _status_msg_impl "Your message..."
_status_msg_impl() {
    STATUS_MSG="$1"
    if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
        # print message without newline and save cursor
        printf '%s' "$STATUS_MSG"
        tput sc 2>/dev/null || true
    else
        printf '%s' "$STATUS_MSG"
    fi
}

# Print an OK indication. If a STATUS_MSG exists, restore cursor and
# overwrite the line with "<STATUS_MSG> [OK]". Otherwise print "[OK]".
# Usage: _status_ok_impl
_status_ok_impl() {
    if [ -z "${STATUS_MSG:-}" ]; then
        if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
            tput bold 2>/dev/null || true
            tput setaf 2 2>/dev/null || true
            printf '%s\n' "[OK]"
            tput sgr0 2>/dev/null || true
        else
            printf '%s\n' "[OK]"
        fi
    else
        if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
            tput rc 2>/dev/null || true
            tput el 2>/dev/null || true
            tput bold 2>/dev/null || true
            tput setaf 2 2>/dev/null || true
            printf '%s %s\n' "$STATUS_MSG" "[OK]"
            tput sgr0 2>/dev/null || true
        else
            printf '%s %s\n' "$STATUS_MSG" "[OK]"
        fi
        unset STATUS_MSG
    fi
}

# Print a failure indication. Behavior mirrors _status_ok_impl but uses
# a failure label and color.
# Usage: _status_fail_impl
_status_fail_impl() {
    if [ -z "${STATUS_MSG:-}" ]; then
        if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
            tput bold 2>/dev/null || true
            tput setaf 1 2>/dev/null || true
            printf '%s\n' "[FAILED]"
            tput sgr0 2>/dev/null || true
        else
            printf '%s\n' "[FAILED]"
        fi
    else
        if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
            tput rc 2>/dev/null || true
            tput el 2>/dev/null || true
            tput bold 2>/dev/null || true
            tput setaf 1 2>/dev/null || true
            printf '%s %s\n' "$STATUS_MSG" "[FAILED]"
            tput sgr0 2>/dev/null || true
        else
            printf '%s %s\n' "$STATUS_MSG" "[FAILED]"
        fi
        unset STATUS_MSG
    fi
}
