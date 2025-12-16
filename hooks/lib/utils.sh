#!/bin/bash
# Common utility functions for Kam hooks

# Colors
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
NC=$(printf '\033[0m') # No Color

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

# exit_if_sudo [<message>] [--return]
# If --return (or -r) is passed as second arg, the function returns 1 instead of exiting.
# This implementation is Bash-only and relies on $EUID (no POSIX fallbacks).
exit_if_sudo() {
    local message="${1:-Do not run this script as root or via sudo. Please run as a normal user.}"
    local do_return=0

    case "$2" in
        --return|-r) do_return=1 ;;
    esac

    # Running as root or invoked via sudo (Bash-only).
    if (( EUID == 0 )) || [[ -n "${SUDO_USER:-}" ]] || [[ -n "${SUDO_UID:-}" ]] || [[ -n "${SUDO_COMMAND:-}" ]]; then
        if declare -F log_error >/dev/null 2>&1; then
            log_error "$message"
        else
            printf '%s\n' "$message" >&2
        fi

        # Explicit request to return instead of exit
        if (( do_return != 0 )); then
            return 1
        fi

        # If this function was invoked from a sourced script (rather than a top-level
        # invoked script), prefer returning so we don't terminate the caller's shell.
        # BASH_SOURCE[1] is the caller; $0 is the top-level invocation.
        if [[ "${BASH_SOURCE[1]:-}" != "${0}" ]]; then
            return 1
        fi

        exit 1
    fi
}

# Check if a command exists
has_command() {
    cmd="$1"

    if [ -z "$cmd" ]; then
        log_error "has_command: command name is required"
        return 1  # Changed to return 1 instead of exit to avoid terminating the script
    fi

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Usage: require_command <command> [<error message>]
# If the command is not available and a custom message is provided, it will be printed;
# otherwise a default error message is shown.
require_command() {
    cmd="$1"
    msg="$2"

    if has_command "$cmd"; then
        return 0
    else
        if [ -n "$msg" ]; then
            log_error "$msg"
        else
            log_error "Command '$cmd' is required but not found."
        fi
        exit 1
    fi
}

# Check if a variable is set
require_env() {
    var_name="$1"
    eval value=\$$var_name
    if [ -z "$value" ]; then
        log_error "Environment variable '$var_name' is not set."
        exit 1
    fi
}

# Magisk-like utility functions

is_github_actions() {
    # GitHub Actions sets GITHUB_ACTIONS to a truthy value. Treat common truthy forms as true.
    case "${GITHUB_ACTIONS:-}" in
        true|TRUE|1|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_ci() {
    # Generic CI detection: prefer the generic CI variable and some common CI-specific ones.
    if [ -n "${CI:-}" ] && [ "${CI:-}" != "false" ]; then
        return 0
    fi

    if is_github_actions; then
        return 0
    fi

    if [ -n "${GITLAB_CI:-}" ] || [ -n "${TRAVIS:-}" ] || [ -n "${CIRCLECI:-}" ] || [ -n "${BUILDKITE:-}" ]; then
        return 0
    fi

    if [ -n "${JENKINS_URL:-}" ] || [ -n "${BUILD_NUMBER:-}" ] || [ -n "${TEAMCITY_VERSION:-}" ]; then
        return 0
    fi

    return 1
}

run_as_root() {
    # Run a command as root using sudo if needed (and available), otherwise run as-is (best-effort).
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return $?
    fi

    log_warn "run_as_root: sudo not found; attempting to run the command without escalation"
    "$@"
    return $?
}

ci_install() {
    # Usage: ci_install <pkg1> [pkg2 ...]
    # Try multiple package managers in CI (apt-get, apk, pacman, dnf, yum, zypper, pkg, brew).
    if ! is_ci; then
        log_warn "ci_install: not running in a recognized CI environment; skipping installation: $*"
        return 1
    fi

    if [ $# -eq 0 ]; then
        log_error "ci_install: at least one package name is required"
        return 1
    fi

    pkgs=( "$@" )

    # Debian/Ubuntu: apt-get
    if command -v apt-get >/dev/null 2>&1; then
        log_info "ci_install: attempting apt-get install: ${pkgs[*]}"
        # update - ignore failures
        run_as_root apt-get update || true
        if run_as_root apt-get install -y "${pkgs[@]}"; then
            log_success "ci_install: installed ${pkgs[*]} via apt-get"
            return 0
        fi
        log_warn "ci_install: apt-get install failed"
    fi

    # Alpine: apk
    if command -v apk >/dev/null 2>&1; then
        log_info "ci_install: attempting apk add: ${pkgs[*]}"
        if run_as_root apk add --no-cache "${pkgs[@]}"; then
            log_success "ci_install: installed ${pkgs[*]} via apk"
            return 0
        fi
        log_warn "ci_install: apk add failed"
    fi

    # Arch: pacman
    if command -v pacman >/dev/null 2>&1; then
        log_info "ci_install: attempting pacman -S: ${pkgs[*]}"
        if run_as_root pacman -S --noconfirm "${pkgs[@]}"; then
            log_success "ci_install: installed ${pkgs[*]} via pacman"
            return 0
        fi
        log_warn "ci_install: pacman install failed"
    fi

    # Fedora/RHEL (dnf)
    if command -v dnf >/dev/null 2>&1; then
        log_info "ci_install: attempting dnf install: ${pkgs[*]}"
        if run_as_root dnf install -y "${pkgs[@]}"; then
            log_success "ci_install: installed ${pkgs[*]} via dnf"
            return 0
        fi
        log_warn "ci_install: dnf install failed"
    fi

    # RHEL/CentOS (yum)
    if command -v yum >/dev/null 2>&1; then
        log_info "ci_install: attempting yum install: ${pkgs[*]}"
        if run_as_root yum install -y "${pkgs[@]}"; then
            log_success "ci_install: installed ${pkgs[*]} via yum"
            return 0
        fi
        log_warn "ci_install: yum install failed"
    fi

    # openSUSE (zypper)
    if command -v zypper >/dev/null 2>&1; then
        log_info "ci_install: attempting zypper install: ${pkgs[*]}"
        if run_as_root zypper --non-interactive install "${pkgs[@]}"; then
            log_success "ci_install: installed ${pkgs[*]} via zypper"
            return 0
        fi
        log_warn "ci_install: zypper install failed"
    fi

    # FreeBSD pkg
    if command -v pkg >/dev/null 2>&1; then
        log_info "ci_install: attempting pkg install: ${pkgs[*]}"
        if run_as_root pkg install -y "${pkgs[@]}"; then
            log_success "ci_install: installed ${pkgs[*]} via pkg"
            return 0
        fi
        log_warn "ci_install: pkg install failed"
    fi

    # Homebrew (macOS)
    if command -v brew >/dev/null 2>&1; then
        log_info "ci_install: attempting brew install: ${pkgs[*]}"
        if brew install "${pkgs[@]}"; then
            log_success "ci_install: installed ${pkgs[*]} via brew"
            return 0
        fi
        log_warn "ci_install: brew install failed"
    fi

    log_error "ci_install: failed to install packages: ${pkgs[*]} using supported package managers"
    return 1
}

require_command_or_ci_install() {
    cmd="$1"
    msg="$2"

    # If the command already exists, we are done
    if has_command "$cmd"; then
        return 0
    fi

    # If running in CI, attempt to install using the available package manager(s).
    if is_ci; then
        log_info "$cmd not found — attempting CI install"
        if ci_install "$cmd"; then
            log_success "$cmd installed in CI"
            return 0
        fi
        log_warn "ci_install failed for $cmd"
    fi

    require_command "$cmd" "$msg"
}

ui_print() {
    printf "  ${NC}• %s${NC}\n" "$1"
}

abort() {
    printf "  ${RED}! %s${NC}\n" "$1"
    exit 1
}

set_perm() {
    target="$1"
    owner="$2"
    group="$3"
    permission="$4"
    context="$5"

    if [ -z "$context" ]; then
        context="u:object_r:system_file:s0"
    fi

    # Attempt chown/chcon but ignore failures on host build environments
    chown "$owner.$group" "$target" >/dev/null 2>&1 || true
    chmod "$permission" "$target"
    chcon "$context" "$target" >/dev/null 2>&1 || true
}

set_perm_recursive() {
    target="$1"
    owner="$2"
    group="$3"
    dpermission="$4"
    fpermission="$5"
    context="$6"

    if [ -z "$context" ]; then
        context="u:object_r:system_file:s0"
    fi

    find "$target" -type d | while read -r dir; do
        set_perm "$dir" "$owner" "$group" "$dpermission" "$context"
    done

    find "$target" -type f | while read -r file; do
        set_perm "$file" "$owner" "$group" "$fpermission" "$context"
    done
}

# Interactive helper utilities
# `prompt` - Request user input and assign to a shell variable
# Usage:
#   prompt VAR "Prompt message" [DEFAULT] [--hide]
# Example:
#   prompt MY_VAR "Enter value" "default"
#   echo "Value is: $MY_VAR"
prompt() {
    target_var="$1"
    prompt_msg="$2"
    default="$3"
    # optional fourth parameter could be --hide to not echo input (password)
    hide="$4"

    if [ -z "$target_var" ] || [ -z "$prompt_msg" ]; then
        log_error "Usage: prompt VAR \"Prompt message\" [DEFAULT] [--hide]"
        return 1
    fi

    # Non-interactive mode - prefer defaults or fail
    if [ "${KAM_NONINTERACTIVE:-}" = "1" ] || [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
        if [ -n "$default" ]; then
            eval "$target_var=\"\$default\""
            return 0
        else
            log_error "Non-interactive environment and no default for prompt: $prompt_msg"
            return 1
        fi
    fi

    while :; do
        # Show prompt text and optional default
        if [ -n "$default" ]; then
            printf "%s [%s]: " "$prompt_msg" "$default"
        else
            printf "%s: " "$prompt_msg"
        fi

        if [ "$hide" = "--hide" ] || [ "$hide" = "true" ]; then
            if command -v stty >/dev/null 2>&1; then
                stty -echo
                IFS= read -r value || true  # Use IFS= to preserve leading/trailing spaces
                stty echo
                printf "\n"
            else
                # Fallback if stty not available
                IFS= read -r value || true
            fi
        else
            IFS= read -r value || true  # Preserve spaces
        fi

        if [ -z "$value" ]; then
            if [ -n "$default" ]; then
                value="$default"
            fi
        fi

        if [ -n "$value" ]; then
            # assign to the requested variable name in the calling shell
            eval "$target_var=\"\$value\""
            return 0
        fi

        log_warn "Value cannot be empty."
    done
}

# `choice` - Present a list of choices to the user and set the selection
# Usage:
#   choice VAR "Prompt message" DEFAULT CHOICE1 [CHOICE2 CHOICE3...]
# DEFAULT may be the exact choice string or the 1-based index of the default choice
choice() {
    target_var="$1"
    prompt_msg="$2"
    default="$3"
    shift 3

    # If the provided default is not a numeric index and is not present
    # in the provided options, automatically prepend it so it appears
    # in the choice list. This makes it less error-prone when callers
    # pass the default but forget to include it as an option.
    if ! echo "$default" | grep -qE '^[0-9]+$' 2>/dev/null && [ -n "$default" ]; then
        found_default=0
        for opt in "$@"; do
            if [ "$opt" = "$default" ]; then
                found_default=1
                break
            fi
        done
        if [ "$found_default" -eq 0 ]; then
            set -- "$default" "$@"
        fi
    fi

    if [ -z "$target_var" ] || [ -z "$prompt_msg" ]; then
        log_error "Usage: choice VAR \"Prompt message\" DEFAULT CHOICE1 [CHOICE2 ...]"
        return 1
    fi

    if [ $# -lt 1 ]; then
        log_error "choice requires at least one option"
        return 1
    fi

    # Build array-like ordering by using $@; determine default value
    default_val=""
    index=1
    for opt in "$@"; do
        if [ "$default" = "$index" ] || [ "$default" = "$opt" ]; then
            default_val="$opt"
            break
        fi
        index=$((index + 1))
    done
    # If default not found, fall back to the first option
    if [ -z "$default_val" ]; then
        default_val="$1"
    fi

    # Non-interactive mode - choose the default automatically
    if [ "${KAM_NONINTERACTIVE:-}" = "1" ] || [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
        eval "$target_var=\"\$default_val\""
        return 0
    fi

    while :; do
        printf "%s\n" "$prompt_msg"
        idx=1
        for opt in "$@"; do
            if [ "$opt" = "$default_val" ]; then
                printf "  %d) %s (default)\n" "$idx" "$opt"
            else
                printf "  %d) %s\n" "$idx" "$opt"
            fi
            idx=$((idx + 1))
        done

        max=$((idx - 1))

        printf "Choose [default: %s]: " "$default_val"
        IFS= read -r ans || true  # Preserve spaces

        if [ -z "$ans" ]; then
            ans="$default_val"
        fi

        # If numeric index provided:
        if echo "$ans" | grep -qE '^[0-9]+$'; then
            if [ "$ans" -ge 1 ] 2>/dev/null && [ "$ans" -le "$max" ] 2>/dev/null; then
                sel_idx="$ans"
                cur=1
                for opt in "$@"; do
                    if [ "$cur" -eq "$sel_idx" ]; then
                        eval "$target_var=\"\$opt\""
                        return 0
                    fi
                    cur=$((cur + 1))
                done
            fi
        else
            # If text matches an option exactly:
            cur=1
            for opt in "$@"; do
                if [ "$opt" = "$ans" ]; then
                    eval "$target_var=\"\$opt\""
                    return 0
                fi
                cur=$((cur + 1))
            done
        fi

        log_warn "Invalid choice: $ans"
    done
}

if [ -f /etc/os-release ]; then
    . /etc/os-release
fi
