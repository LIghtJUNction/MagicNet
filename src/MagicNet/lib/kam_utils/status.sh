#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# Status helpers - public wrapper
# -----------------------------------------------------------------------------
# Exposes simple helpers for printing inline status messages:
#   - status_msg "message"   # print a preliminary message (no newline)
#   - status_ok              # mark the previous status as OK
#   - status_fail            # mark the previous status as FAILED
#
# Implementation is delegated to the internal `_status.sh` for testability and
# reuse across scripts.
# =============================================================================

MODDIR=${MODDIR:-${0%/*}}
# shellcheck source=_status.sh
kam_source_impl status || { echo "错误: 无法加载内部实现: _status.sh" >&2; return 1; }

# Public wrappers (keep a small fallback in case internal names differ)
status_msg() {
    _status_msg_impl "$@"
}

status_ok() {
    _status_ok_impl "$@"
}

status_fail() {
    _status_fail_impl "$@"
}
