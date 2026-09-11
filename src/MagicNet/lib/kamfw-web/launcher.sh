# shellcheck shell=ash
# Android resolves VIEW to the user's default browser; do not pin a vendor APK.
_launch_url() (
    [ -n "${1:-}" ] || return 1
    am start --user current -a android.intent.action.VIEW \
        -c android.intent.category.BROWSABLE -d "$1" >/dev/null 2>&1
)

_launch_app() (
    [ -n "${1:-}" ] || return 1
    case "$1" in
        */*) am start --user current -n "$1" >/dev/null 2>&1 ;;
        *) monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 ;;
    esac
)

# launch browser|url|link URL; launch app|pkg PACKAGE; launch URL
# Subshells isolate scratch state and preserve the Android command's exit status.
launch() (
    case "${1:-}" in
        browser | url | link) _launch_url "${2:-}" ;;
        app | pkg) _launch_app "${2:-}" ;;
        *) _launch_url "${1:-}" ;;
    esac
)
