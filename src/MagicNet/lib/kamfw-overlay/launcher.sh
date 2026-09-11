# shellcheck shell=ash

# No import-time side effects. Subshells keep caller variables and status intact.
_launch_run() {
    if [ -n "${KAM_LAUNCH_BUSYBOX:-}" ] && [ -x "$KAM_LAUNCH_BUSYBOX" ]; then
        "$KAM_LAUNCH_BUSYBOX" timeout 5 "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout 5 "$@"
    else
        "$@"
    fi
}
_launch_url() (
    [ -n "${1:-}" ] || exit 2
    command -v am >/dev/null 2>&1 || exit 127
    _launch_run am start --user current -a android.intent.action.VIEW -d "$1" >/dev/null 2>&1
)

# Ask Android for its current user's browser, never assume Chrome is installed.
# A browser-role lookup is optional: ACTION_VIEW remains the portable fallback.
_launch_browser() (
    case "${1:-}" in http://?*|https://?*) ;; *) exit 2 ;; esac
    command -v am >/dev/null 2>&1 || exit 127
    _lb_package=''
    # Older role services reject USER_CURRENT before resolving it. Query the
    # numeric foreground user first, while still launching with --user current.
    _lb_user=$(_launch_run am get-current-user 2>/dev/null) || _lb_user=''
    case "$_lb_user" in ''|*[!0-9]*) _lb_user='' ;; esac
    if [ -n "$_lb_user" ] && command -v cmd >/dev/null 2>&1; then
        _lb_package=$(_launch_run cmd role get-role-holders --user "$_lb_user" android.app.role.BROWSER 2>/dev/null) || _lb_package=''
    fi
    case "$_lb_package" in ''|*[!A-Za-z0-9_.]*) _lb_package='' ;; esac
    if [ -n "$_lb_package" ]; then
        _launch_run am start --user current -a android.intent.action.VIEW \
            -c android.intent.category.BROWSABLE -p "$_lb_package" -d "$1" >/dev/null 2>&1 && exit 0
    fi
    _launch_run am start --user current -a android.intent.action.VIEW \
        -c android.intent.category.BROWSABLE -d "$1" >/dev/null 2>&1
)

_launch_app() (
    [ -n "${1:-}" ] || exit 2
    case "$1" in
        */*)
            command -v am >/dev/null 2>&1 || exit 127
            _launch_run am start --user current -n "$1" >/dev/null 2>&1 ;;
        *)
            command -v monkey >/dev/null 2>&1 || exit 127
            _launch_run monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 ;;
    esac
)

launch() {
    case "${1:-}" in
        url|link) _launch_url "${2:-}" ;;
        browser) _launch_browser "${2:-}" ;;
        app|pkg) _launch_app "${2:-}" ;;
        *) _launch_url "${1:-}" ;;
    esac
}
