# shellcheck shell=ash
# Uninstall-only helpers. Importing this file has no side effects.

magicnet_uninstall_busybox() (
    for _bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox \
        /data/adb/ap/bin/busybox /data/adb/apatch/bin/busybox \
        /debug_ramdisk/.magisk/busybox/busybox /sbin/.magisk/busybox/busybox \
        "${MODDIR}/bin/busybox" /system/bin/busybox /system/xbin/busybox \
        "$(command -v busybox 2>/dev/null)"; do
        case "$_bb" in /*) ;; *) continue ;; esac
        [ -x "$_bb" ] || continue
        "$_bb" --list 2>/dev/null | grep -qx timeout || continue
        printf '%s\n' "$_bb"
        exit 0
    done
    exit 1
)

magicnet_uninstall_run() {
    _mn_timeout=$1
    shift
    if [ -n "${MN_UNINSTALL_BB:-}" ]; then
        "$MN_UNINSTALL_BB" timeout -k 2 "$_mn_timeout" "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout -k 2 "$_mn_timeout" "$@"
    else
        # Managers normally provide BusyBox. Do not skip network cleanup in
        # damaged installations just because that optional binary is absent.
        "$@"
    fi
}

magicnet_uninstall_cleanup() (
    _rc=0
    # This is a final uninstall hook, not a reversible UI "remove" request.
    # Prevent a supervisor from restarting the core during teardown.
    [ ! -L "$MODDIR/disable" ] && : >"$MODDIR/disable" || _rc=1
    if [ -x "$MODDIR/cli" ]; then
        # Stop remote writers first, then watchers, then use the existing
        # ownership-aware service stop (DNS/hotspot/TUN/eBPF teardown).
        magicnet_uninstall_run 12 "$MODDIR/cli" mcp stop || _rc=1
        magicnet_uninstall_run 15 "$MODDIR/cli" supervisor stop all || _rc=1
        magicnet_uninstall_run 30 "$MODDIR/cli" service stop || _rc=1
        magicnet_uninstall_run 8 "$MODDIR/cli" state reconcile || _rc=1
    else
        printf '%s\n' '[MagicNet] cli is missing; runtime cleanup could not be verified.' >&2
        _rc=1
    fi
    # The manager owns removal of MODDIR, including config, logs and caches.
    # Never delete Download exports, another VPN's processes, or global rules.
    [ "$_rc" = 0 ] || printf '%s\n' \
        '[MagicNet] Some cleanup failed. Reboot and verify networking; no global rules were flushed.' >&2
    exit "$_rc"
)

magicnet_farewell_parent() {
    printf '%s\n' /data/adb
}

magicnet_farewell_allowed() {
    [ "${MAGICNET_NONINTERACTIVE:-0}" != 1 ] &&
        [ "${MAGICNET_UNINSTALL_FAREWELL:-1}" != 0 ] || return 1
    case "${BOOTMODE:-}" in false | 0) return 1 ;; esac
    [ -x /system/bin/am ] && [ -x /system/bin/getprop ]
}

magicnet_farewell_stage() (
    set +x
    umask 077
    _bb=${MN_UNINSTALL_BB:-}
    [ -n "$_bb" ] && [ -x "$_bb" ] || exit 1
    _applets=$("$_bb" --list) || exit 1
    for _applet in ash httpd wget timeout setsid od tr cp chmod cat \
        mkdir mktemp rm sleep kill; do
        printf '%s\n' "$_applets" | grep -qx "$_applet" || exit 1
    done
    _parent=$(magicnet_farewell_parent) || exit 1
    [ -d "$_parent" ] && [ ! -L "$_parent" ] || exit 1
    _run=$("$_bb" mktemp -d "$_parent/.magicnet-farewell.XXXXXX") || exit 1
    # Delete incomplete staging; once handed off, the worker owns it.
    trap '[ -z "$_run" ] || "$_bb" rm -rf -- "$_run"' 0
    trap 'exit 1' 1 2 3 15
    "$_bb" cp "$_bb" "$_run/busybox" || exit 1
    "$_bb" chmod 700 "$_run/busybox" || exit 1
    "$_bb" cp "$MODDIR/lib/magicnet/uninstall.sh" "$_run/uninstall.sh" || exit 1
    "$_bb" cp "$MODDIR/lib/kamfw-web/launcher.sh" "$_run/launcher.sh" || exit 1
    _token=$("$_bb" od -An -N16 -tx1 /dev/urandom | "$_bb" tr -d ' \n')
    [ "${#_token}" = 32 ] || exit 1
    "$_bb" mkdir -p "$_run/www/$_token" || exit 1
    "$_bb" cp "$MODDIR/lib/magicnet/farewell/index.html" "$_run/www/$_token/index.html" || exit 1
    printf '%s\n' "$_token" >"$_run/token" || exit 1
    # Read module metadata as DATA, never source module.prop or user config.
    _version=$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)
    case "$_version" in '' | *[!A-Za-z0-9._+-]*) _version=unknown ;; esac
    [ "${#_version}" -le 64 ] || _version=unknown
    printf '%s\n' "$_version" >"$_run/version" || exit 1
    printf 'A:127.0.0.1\nD:*\n' >"$_run/httpd.conf" || exit 1
    cat >"$_run/worker.sh" <<'WORKER'
#!/system/bin/sh
MN_FAREWELL_RUN=${0%/*}
. "$MN_FAREWELL_RUN/uninstall.sh" || exit 1
magicnet_farewell_worker "$MN_FAREWELL_RUN"
WORKER
    # All assets, including BusyBox, survive deletion of the module directory.
    # No persistent service.d entry, recurring task, or always-on server.
    "$_run/busybox" setsid "$_run/busybox" timeout -k 2 480 \
        "$_run/busybox" ash "$_run/worker.sh" </dev/null >/dev/null 2>&1 &
    _worker=$!
    "$_bb" sleep 1
    kill -0 "$_worker" 2>/dev/null || exit 1
    _run=''
)

magicnet_farewell_android_ready() {
    [ "$(/system/bin/getprop sys.boot_completed 2>/dev/null)" = 1 ]
}

magicnet_farewell_open() (
    unset LD_LIBRARY_PATH LD_PRELOAD
    PATH="/system/bin:${PATH:-}"
    export PATH
    . "$1/launcher.sh" || exit 1
    # The existing launcher resolves the current user's default browser and
    # checks ActivityManager's textual errors as well as the exit status.
    # shellcheck disable=SC2317
    _launch_run() {
        _tool=$1
        shift
        case "$_tool" in am | cmd) ;; *) return 127 ;; esac
        "$MN_FAREWELL_BB" timeout -k 1 5 "/system/bin/$_tool" "$@"
    }
    launch browser "$2"
)

magicnet_farewell_worker() (
    set +x
    umask 077
    _run=$1
    case "${_run##*/}" in .magicnet-farewell.??????) ;; *) exit 1 ;; esac
    [ -d "$_run" ] && [ ! -L "$_run" ] || exit 1
    MN_FAREWELL_BB="$_run/busybox"
    _bb=$MN_FAREWELL_BB
    _http=''
    # Only kill the process group created here, never by process name.
    # shellcheck disable=SC2317
    _farewell_cleanup() {
        trap - 0 1 2 3 15
        if [ -n "$_http" ]; then
            "$_bb" kill -TERM -- "-$_http" 2>/dev/null || :
            wait "$_http" 2>/dev/null || :
        fi
        "$_bb" rm -rf -- "$_run"
    }
    trap _farewell_cleanup 0
    trap 'exit 1' 1 2 3 15
    # KernelSU/Magisk may invoke uninstall before Android has a browser.
    # Wait only in this detached, time-bounded worker, never in the hook.
    _attempt=0
    until magicnet_farewell_android_ready; do
        [ "$_attempt" -lt 150 ] || exit 1
        "$_bb" sleep 2
        _attempt=$((_attempt + 1))
    done
    _token=$("$_bb" cat "$_run/token") || exit 1
    _version=$("$_bb" cat "$_run/version") || exit 1
    case "$_token" in '' | *[!0-9a-f]*) exit 1 ;; esac
    [ "${#_token}" = 32 ] || exit 1
    case "$_version" in '' | *[!A-Za-z0-9._+-]*) exit 1 ;; esac
    _attempt=0
    while [ "$_attempt" -lt 8 ]; do
        _attempt=$((_attempt + 1))
        _random=$("$_bb" od -An -N2 -tu2 /dev/urandom | "$_bb" tr -d ' \n')
        case "$_random" in '' | *[!0-9]*) exit 1 ;; esac
        _port=$((20000 + _random % 30000))
        _url="http://127.0.0.1:$_port/$_token/"
        "$_bb" setsid "$_bb" timeout -k 2 120 "$_bb" httpd -f \
            -p "127.0.0.1:$_port" -h "$_run/www" -c "$_run/httpd.conf" \
            </dev/null >/dev/null 2>&1 &
        _http=$!
        "$_bb" sleep 1
        if kill -0 "$_http" 2>/dev/null; then break; fi
        wait "$_http" 2>/dev/null || :
        _http=''
    done
    [ -n "$_http" ] || exit 1
    # Verify our random URL before opening it; do not open a colliding service.
    _page=$("$_bb" timeout -k 1 4 "$_bb" wget -Y off -q -O - "$_url") || exit 1
    case "$_page" in *'id="farewell"'*) ;; *) exit 1 ;; esac
    magicnet_farewell_open "$_run" "${_url}#version=$_version" || exit 1
    # All CSS/JS are inline. Once loaded, the tab works after the listener and
    # staging directory disappear; the user decides when to close the tab.
    wait "$_http" 2>/dev/null || :
    _http=''
)

magicnet_uninstall_main() (
    set +x
    umask 077
    [ -n "${MODDIR:-}" ] && [ "$MODDIR" != / ] && [ ! -L "$MODDIR" ] || exit 1
    [ -f "$MODDIR/module.prop" ] && grep -qx 'id=MagicNet' "$MODDIR/module.prop" || exit 1
    [ ! -L "$MODDIR/.state" ] || exit 1
    mkdir -p "$MODDIR/.state" || exit 1
    # At most one concurrent teardown, and at most one browser attempt per
    # module removal. No permanent markers are written outside MODDIR.
    mkdir "$MODDIR/.state/uninstall.lock" 2>/dev/null || exit 0
    trap 'rmdir "$MODDIR/.state/uninstall.lock" 2>/dev/null || :' 0
    trap 'exit 1' 1 2 3 15
    MN_UNINSTALL_BB=$(magicnet_uninstall_busybox) || MN_UNINSTALL_BB=''
    _cleanup_rc=0
    magicnet_uninstall_cleanup || _cleanup_rc=1
    if magicnet_farewell_allowed &&
        mkdir "$MODDIR/.state/uninstall-farewell.attempted" 2>/dev/null; then
        magicnet_farewell_stage || printf '%s\n' \
            '[MagicNet] Farewell page unavailable; uninstall cleanup was not blocked.' >&2
    fi
    exit "$_cleanup_rc"
)
