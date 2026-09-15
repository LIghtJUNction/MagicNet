#!/bin/bash
# Logging and command checks shared by build hooks.

RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
NC=$(printf '\033[0m')

log_info() {
    printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$1"
}

log_success() {
    printf '%s[SUCCESS]%s %s\n' "$GREEN" "$NC" "$1"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$1"
}

has_command() {
    local command_name="${1:-}"
    if [ -z "$command_name" ]; then
        log_error 'has_command: command name is required'
        return 1
    fi
    command -v "$command_name" >/dev/null 2>&1
}

require_command() {
    local command_name="${1:-}"
    local message="${2:-}"
    if has_command "$command_name"; then
        return 0
    fi
    log_error "${message:-Command '$command_name' is required but not found.}"
    exit 1
}
