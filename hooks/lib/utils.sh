#!/bin/bash
# Common utility functions for Kam hooks.

RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
NC=$(printf '\033[0m')

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

has_command() {
    local cmd="${1:-}"

    if [ -z "$cmd" ]; then
        log_error "has_command: command name is required"
        return 1
    fi

    command -v "$cmd" >/dev/null 2>&1
}

require_command() {
    local cmd="${1:-}"
    local message="${2:-}"

    if has_command "$cmd"; then
        return 0
    fi

    if [ -n "$message" ]; then
        log_error "$message"
    else
        log_error "Command '$cmd' is required but not found."
    fi
    exit 1
}
