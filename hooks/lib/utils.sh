#!/bin/bash

RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
NC=$(printf '\033[0m')

log_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$GREEN" "$NC" "$1"; }
log_warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$1"; }

exit_if_sudo() {
    local message="${1:-Do not run this script as root or via sudo. Please run as a normal user.}"
    local mode="${2:-}"

    if (( EUID != 0 )) && [[ -z "${SUDO_USER:-}${SUDO_UID:-}${SUDO_COMMAND:-}" ]]; then
        return 0
    fi

    log_error "$message"
    [[ "$mode" == --return || "$mode" == -r || "${BASH_SOURCE[1]:-}" != "$0" ]] && return 1
    exit 1
}

has_command() {
    local command_name="${1:-}"
    [[ -n "$command_name" ]] || {
        log_error 'has_command: command name is required'
        return 1
    }
    command -v "$command_name" >/dev/null 2>&1
}

require_command() {
    local command_name="${1:-}"
    local message="${2:-}"

    has_command "$command_name" && return 0
    log_error "${message:-Command '$command_name' is required but not found.}"
    exit 1
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        require_command "$command_name"
    done
}

require_env() {
    local name="${1:-}"
    local value

    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        log_error 'require_env: valid variable name required'
        exit 1
    }
    value="${!name-}"
    [[ -n "$value" ]] || {
        log_error "Environment variable '$name' is not set."
        exit 1
    }
}

is_github_actions() {
    case "${GITHUB_ACTIONS:-}" in
        true|TRUE|1|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

is_ci() {
    [[ -n "${CI:-}" && "${CI:-}" != false ]] \
        || is_github_actions \
        || [[ -n "${GITLAB_CI:-}${TRAVIS:-}${CIRCLECI:-}${BUILDKITE:-}${JENKINS_URL:-}${BUILD_NUMBER:-}${TEAMCITY_VERSION:-}" ]]
}

is_termux() {
    [[ -n "${TERMUX_VERSION:-}" ]] && return 0
    case "${PREFIX:-}:${HOME:-}" in
        *'/data/data/com.termux'*) return 0 ;;
    esac
    [[ -d /data/data/com.termux || -d /data/data/com.termux/files/usr \
        || -f /data/data/com.termux/files/usr/etc/termux/termux.env \
        || -x /data/data/com.termux/files/usr/bin/termux-change-repo ]]
}

run_as_root() {
    (( EUID == 0 )) || {
        log_error 'run_as_root: not running as root'
        return 1
    }
    "$@"
}

ci_install() {
    local -a packages=("$@")
    local manager

    ((${#packages[@]})) || {
        log_error 'ci_install: at least one package name is required'
        return 1
    }
    is_ci || {
        log_warn "ci_install: not running in CI; skipping: ${packages[*]}"
        return 1
    }

    for manager in apt-get apk pacman dnf yum zypper pkg brew; do
        has_command "$manager" || continue
        log_info "ci_install: trying $manager for ${packages[*]}"
        case "$manager" in
            apt-get)
                run_as_root apt-get update || true
                run_as_root apt-get install -y "${packages[@]}" && return 0
                ;;
            apk) run_as_root apk add --no-cache "${packages[@]}" && return 0 ;;
            pacman) run_as_root pacman -S --noconfirm "${packages[@]}" && return 0 ;;
            dnf) run_as_root dnf install -y "${packages[@]}" && return 0 ;;
            yum) run_as_root yum install -y "${packages[@]}" && return 0 ;;
            zypper) run_as_root zypper --non-interactive install "${packages[@]}" && return 0 ;;
            pkg) run_as_root pkg install -y "${packages[@]}" && return 0 ;;
            brew) brew install "${packages[@]}" && return 0 ;;
        esac
        log_warn "ci_install: $manager failed"
    done

    log_error "ci_install: failed to install: ${packages[*]}"
    return 1
}

require_command_or_ci_install() {
    local command_name="${1:-}"
    local message="${2:-}"

    has_command "$command_name" && return 0
    if is_ci && ci_install "$command_name"; then
        return 0
    fi
    require_command "$command_name" "$message"
}

ui_print() { printf '  %s• %s%s\n' "$NC" "$1" "$NC"; }
abort() { printf '  %s! %s%s\n' "$RED" "$1" "$NC"; exit 1; }

set_perm() {
    local target="$1" owner="$2" group="$3" permission="$4"
    local context="${5:-u:object_r:system_file:s0}"

    chown "$owner.$group" "$target" >/dev/null 2>&1 || true
    chmod "$permission" "$target"
    chcon "$context" "$target" >/dev/null 2>&1 || true
}

set_perm_recursive() {
    local target="$1" owner="$2" group="$3" dir_mode="$4" file_mode="$5"
    local context="${6:-u:object_r:system_file:s0}"
    local path

    while IFS= read -r path; do
        set_perm "$path" "$owner" "$group" "$dir_mode" "$context"
    done < <(find "$target" -type d)
    while IFS= read -r path; do
        set_perm "$path" "$owner" "$group" "$file_mode" "$context"
    done < <(find "$target" -type f)
}

prompt() {
    local target="${1:-}" message="${2:-}" default="${3:-}" hide="${4:-}"
    local input

    [[ -n "$target" && -n "$message" ]] || {
        log_error 'Usage: prompt VAR "Prompt message" [DEFAULT] [--hide]'
        return 1
    }

    if [[ "${KAM_NONINTERACTIVE:-}" == 1 || -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
        [[ -n "$default" ]] || {
            log_error "Non-interactive environment and no default for prompt: $message"
            return 1
        }
        printf -v "$target" '%s' "$default"
        return 0
    fi

    while :; do
        if [[ -n "$default" ]]; then
            printf '%s [%s]: ' "$message" "$default"
        else
            printf '%s: ' "$message"
        fi

        if [[ "$hide" == --hide || "$hide" == true ]] && has_command stty; then
            stty -echo
            IFS= read -r input || true
            stty echo
            printf '\n'
        else
            IFS= read -r input || true
        fi

        input="${input:-$default}"
        if [[ -n "$input" ]]; then
            printf -v "$target" '%s' "$input"
            return 0
        fi
        log_warn 'Value cannot be empty.'
    done
}

choice() {
    local target="${1:-}" message="${2:-}" default="${3:-}"
    local option selected answer index
    shift 3 || true

    [[ -n "$target" && -n "$message" && $# -gt 0 ]] || {
        log_error 'Usage: choice VAR "Prompt message" DEFAULT CHOICE1 [CHOICE2 ...]'
        return 1
    }

    selected=''
    if [[ "$default" =~ ^[0-9]+$ ]]; then
        index=1
        for option in "$@"; do
            [[ "$index" == "$default" ]] && selected="$option" && break
            ((index++))
        done
    else
        for option in "$@"; do
            [[ "$option" == "$default" ]] && selected="$option" && break
        done
        if [[ -z "$selected" && -n "$default" ]]; then
            set -- "$default" "$@"
            selected="$default"
        fi
    fi
    [[ -n "$selected" ]] || selected="$1"

    if [[ "${KAM_NONINTERACTIVE:-}" == 1 || -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
        printf -v "$target" '%s' "$selected"
        return 0
    fi

    while :; do
        printf '%s\n' "$message"
        index=1
        for option in "$@"; do
            if [[ "$option" == "$selected" ]]; then
                printf '  %d) %s (default)\n' "$index" "$option"
            else
                printf '  %d) %s\n' "$index" "$option"
            fi
            ((index++))
        done
        printf 'Choose [default: %s]: ' "$selected"
        IFS= read -r answer || true
        answer="${answer:-$selected}"

        if [[ "$answer" =~ ^[0-9]+$ && "$answer" -ge 1 && "$answer" -lt "$index" ]]; then
            local current=1
            for option in "$@"; do
                if [[ "$current" == "$answer" ]]; then
                    printf -v "$target" '%s' "$option"
                    return 0
                fi
                ((current++))
            done
        else
            for option in "$@"; do
                if [[ "$option" == "$answer" ]]; then
                    printf -v "$target" '%s' "$option"
                    return 0
                fi
            done
        fi
        log_warn "Invalid choice: $answer"
    done
}

# shellcheck source=/etc/os-release
[[ ! -f /etc/os-release ]] || . /etc/os-release
