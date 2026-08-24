# shellcheck shell=ash
#
# Kamfw-free helpers shared by common.sh and isolated subscribe loads.

magicnet_lib_dir() {
    if [ -n "${MAGICNET_LIB_DIR:-}" ]; then
        printf '%s\n' "$MAGICNET_LIB_DIR"
    elif [ -f "${MODDIR}/lib/magicnet/primitives.sh" ]; then
        printf '%s\n' "${MODDIR}/lib/magicnet"
    elif [ -n "${BASH_VERSION:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
        # BASH_SOURCE is guarded by the Bash-only branch above.
        # shellcheck disable=SC3054
        cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
    else
        printf '%s\n' "${MODDIR}/lib/magicnet"
    fi
}

magicnet_source_primitives() {
    type magicnet_json_escape >/dev/null 2>&1 && return 0
    # Runtime module roots are resolved above.
    # shellcheck disable=SC1091
    . "$(magicnet_lib_dir)/primitives.sh"
}

magicnet_jq_ai_tags_lib() {
    printf '%s\n' "$(magicnet_lib_dir)/jq"
}

magicnet_json_escape() {
    LC_ALL=C printf '%s' "$1" |
        tr '\r\n\t' '   ' |
        sed 's/[[:cntrl:]]//g; s/\\/\\\\/g; s/"/\\"/g'
}

# Host-only compatibility for Bash test fixtures. Android always uses the Rust
# worker below; never stream a device proc pseudo-file through this fallback.
magicnet_host_proc_reader_allowed() {
    [ -n "${BASH_VERSION:-}" ] && [ ! -x /system/bin/getprop ]
}

magicnet_host_proc_reader() (
    _host_kind="$1"
    _host_root="$2"
    _host_pid="$3"
    case "$_host_kind" in
    cmdline)
        [ -r "$_host_root/$_host_pid/cmdline" ] || return 1
        exec 3<"$_host_root/$_host_pid/cmdline" || return 1
        _host_count=0
        _host_newline='
'
        _host_cr=$(printf '\r')
        # Host-only Bash fixture reader.
        # shellcheck disable=SC3045
        while IFS= read -r -d '' _host_argument <&3; do
            [ -n "$_host_argument" ] || return 1
            case "$_host_argument" in
            *"$_host_newline"* | *"$_host_cr"*) return 1 ;;
            esac
            printf '%s\n' "$_host_argument"
            _host_count=$((_host_count + 1))
        done
        [ "$_host_count" -gt 0 ]
        ;;
    comm)
        [ -r "$_host_root/$_host_pid/comm" ] || return 1
        IFS= read -r _host_comm <"$_host_root/$_host_pid/comm" || return 1
        [ -n "$_host_comm" ] || return 1
        printf '%s\n' "$_host_comm"
        ;;
    stat)
        [ -r "$_host_root/$_host_pid/stat" ] || return 1
        IFS= read -r _host_stat <"$_host_root/$_host_pid/stat" || return 1
        _host_tail=${_host_stat##*) }
        # shellcheck disable=SC2086 # proc stat fields are positional.
        set -- $_host_tail
        [ "$#" -ge 20 ] || return 1
        _host_state=$1
        shift 19
        case "$_host_state" in [A-Za-z]) ;; *) return 1 ;; esac
        case "$1" in '' | *[!0-9]*) return 1 ;; esac
        printf '%s %s\n' "$_host_state" "$1"
        ;;
    *) return 1 ;;
    esac
)

# Emit one validated argv entry per line through the Rust bounded proc reader.
# It caps cmdline at 64 KiB, enforces a monotonic deadline, fails closed on
# malformed entries, and kills its reader worker if this shell disappears.
magicnet_proc_cmdline_lines() (
    _proc_pid="$1"
    _proc_root="${2:-${MAGICNET_PROC_ROOT:-/proc}}"
    case "$_proc_pid" in
    '' | *[!0-9]* | 0) return 1 ;;
    esac
    case "$_proc_root" in
    /*) ;;
    *) return 1 ;;
    esac
    if type magicnet_proc_reader_test_hook >/dev/null 2>&1; then
        magicnet_proc_reader_test_hook cmdline "$_proc_root" "$_proc_pid"
        return $?
    fi
    if magicnet_host_proc_reader_allowed; then
        magicnet_host_proc_reader cmdline "$_proc_root" "$_proc_pid"
        return $?
    fi
    _proc_reader="${MODDIR}/cli"
    [ -x "$_proc_reader" ] || return 1
    "$_proc_reader" __proc-cmdline "$_proc_root" "$_proc_pid"
)

magicnet_proc_comm() (
    _proc_pid="$1"
    _proc_root="${2:-${MAGICNET_PROC_ROOT:-/proc}}"
    case "$_proc_pid" in
    '' | *[!0-9]* | 0) return 1 ;;
    esac
    case "$_proc_root" in
    /*) ;;
    *) return 1 ;;
    esac
    if type magicnet_proc_reader_test_hook >/dev/null 2>&1; then
        magicnet_proc_reader_test_hook comm "$_proc_root" "$_proc_pid"
        return $?
    fi
    if magicnet_host_proc_reader_allowed; then
        magicnet_host_proc_reader comm "$_proc_root" "$_proc_pid"
        return $?
    fi
    _proc_reader="${MODDIR}/cli"
    [ -x "$_proc_reader" ] || return 1
    "$_proc_reader" __proc-comm "$_proc_root" "$_proc_pid"
)

magicnet_proc_stat_identity() (
    _proc_pid="$1"
    _proc_root="${2:-${MAGICNET_PROC_ROOT:-/proc}}"
    case "$_proc_pid" in
    '' | *[!0-9]* | 0) return 1 ;;
    esac
    case "$_proc_root" in
    /*) ;;
    *) return 1 ;;
    esac
    if type magicnet_proc_reader_test_hook >/dev/null 2>&1; then
        magicnet_proc_reader_test_hook stat "$_proc_root" "$_proc_pid"
        return $?
    fi
    if magicnet_host_proc_reader_allowed; then
        magicnet_host_proc_reader stat "$_proc_root" "$_proc_pid"
        return $?
    fi
    _proc_reader="${MODDIR}/cli"
    [ -x "$_proc_reader" ] || return 1
    "$_proc_reader" __proc-stat "$_proc_root" "$_proc_pid"
)

# Read /proc/<pid>/stat starttime. Optional second argument overrides the proc
# root (tests inject a fixture tree via MAGICNET_SUB_REFRESH_PROC_ROOT).
magicnet_proc_start() {
    _proc_pid="$1"
    _proc_root="${2:-${MAGICNET_PROC_ROOT:-/proc}}"
    case "$_proc_pid" in
    '' | *[!0-9]*)
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start
        return 1
        ;;
    esac
    case "$_proc_root" in
    /*) ;;
    *)
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start
        return 1
        ;;
    esac
    _proc_identity="$(magicnet_proc_stat_identity "$_proc_pid" "$_proc_root")" || {
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start
        return 1
    }
    _proc_state=${_proc_identity%% *}
    _proc_start=${_proc_identity#* }
    case "$_proc_state" in
    [A-Za-z]) ;;
    *)
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start
        return 1
        ;;
    esac
    case "$_proc_start" in
    '' | *[!0-9]*)
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start
        return 1
        ;;
    esac
    printf '%s\n' "$_proc_start"
    unset _proc_pid _proc_root _proc_identity _proc_state _proc_start
}

magicnet_proc_state() {
    _proc_state_pid="$1"
    _proc_state_root="${2:-${MAGICNET_PROC_ROOT:-/proc}}"
    _proc_state_identity="$(magicnet_proc_stat_identity "$_proc_state_pid" "$_proc_state_root")" || {
        unset _proc_state_pid _proc_state_root _proc_state_identity
        return 1
    }
    _proc_state=${_proc_state_identity%% *}
    case "$_proc_state" in
    [A-Za-z]) printf '%s\n' "$_proc_state" ;;
    *)
        unset _proc_state_pid _proc_state_root _proc_state_identity _proc_state
        return 1
        ;;
    esac
    unset _proc_state_pid _proc_state_root _proc_state_identity _proc_state
}

magicnet_singbox_proc_start() {
    _proc_stat_path="$1"
    case "$_proc_stat_path" in
    */[0-9]*/stat)
        _proc_pid="${_proc_stat_path%/stat}"
        _proc_pid="${_proc_pid##*/}"
        _proc_root="${_proc_stat_path%/"$_proc_pid"/stat}"
        magicnet_proc_start "$_proc_pid" "$_proc_root"
        _proc_rc=$?
        unset _proc_stat_path _proc_pid _proc_root
        return "$_proc_rc"
        ;;
    esac
    unset _proc_stat_path
    return 1
}

# KernelSU WebUI commands inherit the manager app's killable cgroups. Move an
# explicitly selected MagicNet launcher into each matching stable parent before
# the bridge exits, so its persistent children are not reclaimed with the app.
magicnet_detach_pid_from_app_cgroup() (
    _detach_pid="$1"
    _detach_proc_root="${MAGICNET_PROC_ROOT:-/proc}"
    case "$_detach_pid" in
    '' | *[!0-9]* | 0 | 1) return 1 ;;
    esac
    _detach_cgroup_file="${_detach_proc_root}/${_detach_pid}/cgroup"
    [ -r "$_detach_cgroup_file" ] || return 1
    _detach_cgroup="$(cat "$_detach_cgroup_file" 2>/dev/null || true)"
    _detach_app_lines=$(printf '%s\n' "$_detach_cgroup" |
        awk -F: '$3 ~ "^/apps/" { count++ } END { print count + 0 }')
    [ "$_detach_app_lines" -gt 0 ] || return 0

    _detach_default_roots='/sys/fs/cgroup:/dev/memcg/apps:/dev/cpuset:/dev/cpuctl:/dev/blkio:/dev/freezer'
    _detach_roots="${MAGICNET_PROCESS_CGROUP_ROOTS:-$_detach_default_roots}"
    _detach_custom=0
    [ -z "${MAGICNET_PROCESS_CGROUP_ROOTS:-}" ] || _detach_custom=1
    _detach_required=0
    _detach_moved=0
    _detach_failed=0
    _detach_remaining=$_detach_roots
    while [ -n "$_detach_remaining" ]; do
        case "$_detach_remaining" in
        *:*)
            _detach_root=${_detach_remaining%%:*}
            _detach_remaining=${_detach_remaining#*:}
            ;;
        *)
            _detach_root=$_detach_remaining
            _detach_remaining=''
            ;;
        esac
        [ -n "$_detach_root" ] || continue
        _detach_applicable=0
        if [ "$_detach_custom" -eq 1 ]; then
            _detach_applicable=1
        else
            case "$_detach_root" in
            /sys/fs/cgroup)
                printf '%s\n' "$_detach_cgroup" | grep -q '^0::/apps/' && _detach_applicable=1
                ;;
            /dev/memcg/apps)
                printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*memory[^:]*:/apps/' && _detach_applicable=1
                ;;
            /dev/cpuset)
                printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*cpuset[^:]*:/apps/' && _detach_applicable=1
                ;;
            /dev/cpuctl)
                printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*(cpu|cpuacct)[^:]*:/apps/' && _detach_applicable=1
                ;;
            /dev/blkio)
                printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*blkio[^:]*:/apps/' && _detach_applicable=1
                ;;
            /dev/freezer)
                printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*freezer[^:]*:/apps/' && _detach_applicable=1
                ;;
            esac
        fi
        [ "$_detach_applicable" -eq 1 ] || continue
        _detach_required=$((_detach_required + 1))
        if [ -d "$_detach_root" ] && [ -w "${_detach_root}/cgroup.procs" ] &&
            printf '%s\n' "$_detach_pid" >"${_detach_root}/cgroup.procs" 2>/dev/null; then
            _detach_moved=$((_detach_moved + 1))
        elif [ -d "$_detach_root" ] && [ -w "${_detach_root}/tasks" ] &&
            printf '%s\n' "$_detach_pid" >"${_detach_root}/tasks" 2>/dev/null; then
            _detach_moved=$((_detach_moved + 1))
        else
            _detach_failed=1
        fi
    done
    [ "$_detach_required" -ge "$_detach_app_lines" ] &&
        [ "$_detach_moved" -eq "$_detach_required" ] &&
        [ "$_detach_failed" -eq 0 ]
)
