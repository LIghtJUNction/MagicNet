# shellcheck shell=ash
#
# Kamfw-free helpers shared by common.sh and isolated subscribe loads.

# High-bit fwmark reserved for direct sing-box UDP DNS sockets. Android's
# netd fwmark rules use the low bits, so this mark distinguishes resolver
# traffic without changing the selected network route.
magicnet_dns_capture_singbox_mark() {
    printf '%s\n' 1073741824
}

magicnet_lib_dir() {
    # Prefer the module-owned tree when it is present. MAGICNET_LIB_DIR is a
    # host-test fallback only; a caller must not redirect a live module.
    if [ -f "${MODDIR}/lib/magicnet/primitives.sh" ]; then
        printf '%s\n' "${MODDIR}/lib/magicnet"
    elif [ -n "${MAGICNET_LIB_DIR:-}" ]; then
        printf '%s\n' "$MAGICNET_LIB_DIR"
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

# Create a private scratch file for process discovery. Callers may obtain the
# pathname with command substitution, but process presence is always conveyed
# by the tri-state return code of the *_to_file APIs below.
magicnet_proc_query_temp_create() (
    _query_dir="${MAGICNET_PROC_QUERY_DIR:-${MODDIR}/.state/sing-box}"
    case "$_query_dir" in /*) ;; *) return 1 ;; esac
    if [ ! -d "$_query_dir" ]; then
        mkdir -p "$_query_dir" || return 1
    fi
    [ -d "$_query_dir" ] && [ ! -L "$_query_dir" ] || return 1
    chmod 700 "$_query_dir" 2>/dev/null || return 1
    umask 077
    _query_file=$(mktemp "$_query_dir/.proc-query.XXXXXX") || return 1
    chmod 600 "$_query_file" 2>/dev/null || {
        rm -f "$_query_file"
        return 1
    }
    printf '%s\n' "$_query_file"
)

# Validate the count-framed output of the hidden Rust pid lookup. Return 0 with
# one PID per line in the destination, 1 for an authoritative empty result, and
# 2 for malformed/truncated/otherwise indeterminate output.
magicnet_proc_framed_pids_to_file() (
    _framed_source="$1"
    _framed_output="$2"
    [ -f "$_framed_source" ] && [ ! -L "$_framed_source" ] || return 2
    [ -f "$_framed_output" ] && [ ! -L "$_framed_output" ] || return 2
    [ "$(stat -c %h "$_framed_source" 2>/dev/null)" = 1 ] || return 2
    [ "$(stat -c %h "$_framed_output" 2>/dev/null)" = 1 ] || return 2
    chmod 600 "$_framed_output" 2>/dev/null || return 2
    : >"$_framed_output" || return 2
    exec 3<"$_framed_source" || return 2
    IFS= read -r _framed_line <&3 || return 2
    [ "$_framed_line" = MAGICNET_PROC_PIDS_V1 ] || return 2
    _framed_count=0
    _framed_seen=' '
    _framed_complete=0
    while IFS= read -r _framed_line <&3; do
        case "$_framed_line" in
        'MAGICNET_PROC_PIDS_END '*)
            [ "$_framed_complete" -eq 0 ] || return 2
            _framed_expected=${_framed_line#MAGICNET_PROC_PIDS_END }
            case "$_framed_expected" in '' | *[!0-9]*) return 2 ;; esac
            [ "$_framed_expected" -eq "$_framed_count" ] || return 2
            _framed_complete=1
            _framed_extra=
            if IFS= read -r _framed_extra <&3 || [ -n "$_framed_extra" ]; then
                return 2
            fi
            break
            ;;
        '' | *[!0-9]* | 0) return 2 ;;
        *)
            case "$_framed_seen" in *" $_framed_line "*) return 2 ;; esac
            _framed_seen="${_framed_seen}${_framed_line} "
            printf '%s\n' "$_framed_line" >>"$_framed_output" || return 2
            _framed_count=$((_framed_count + 1))
            ;;
        esac
    done
    [ "$_framed_complete" -eq 1 ] || return 2
    [ "$_framed_count" -gt 0 ] && return 0
    return 1
)

magicnet_proc_unframed_pids_to_file() (
    _unframed_source="$1"
    _unframed_output="$2"
    [ -f "$_unframed_source" ] && [ ! -L "$_unframed_source" ] || return 2
    [ -f "$_unframed_output" ] && [ ! -L "$_unframed_output" ] || return 2
    chmod 600 "$_unframed_output" 2>/dev/null || return 2
    : >"$_unframed_output" || return 2
    _unframed_count=0
    _unframed_seen=' '
    while IFS= read -r _unframed_line || [ -n "$_unframed_line" ]; do
        # shellcheck disable=SC2086 # pidof emits a whitespace-separated list.
        for _unframed_pid in $_unframed_line; do
            case "$_unframed_pid" in '' | *[!0-9]* | 0) return 2 ;; esac
            case "$_unframed_seen" in *" $_unframed_pid "*) continue ;; esac
            _unframed_seen="${_unframed_seen}${_unframed_pid} "
            printf '%s\n' "$_unframed_pid" >>"$_unframed_output" || return 2
            _unframed_count=$((_unframed_count + 1))
        done
    done <"$_unframed_source"
    [ "$_unframed_count" -gt 0 ] && return 0
    return 1
)

# Query a process name without exposing a partially written list. Production
# Android uses a bounded Rust worker with a count-framed protocol. Host-only
# fixtures may use pidof directly. Return: 0=found, 1=definitely empty,
# 2=indeterminate.
magicnet_proc_named_pids_to_file() (
    _named_process="$1"
    _named_output="$2"
    case "$_named_process" in '' | *[!A-Za-z0-9._-]*) return 2 ;; esac
    [ -f "$_named_output" ] && [ ! -L "$_named_output" ] || return 2
    chmod 600 "$_named_output" 2>/dev/null || return 2
    : >"$_named_output" || return 2
    _named_raw=$(magicnet_proc_query_temp_create) || return 2
    _named_result=$(magicnet_proc_query_temp_create) || {
        rm -f "$_named_raw"
        return 2
    }
    _named_rc=2
    if type magicnet_proc_named_pids_test_hook >/dev/null 2>&1; then
        if magicnet_proc_named_pids_test_hook "$_named_process" >"$_named_raw" 2>/dev/null; then
            _named_lookup_rc=0
        else
            _named_lookup_rc=$?
        fi
        if [ "$_named_lookup_rc" -eq 0 ]; then
            if magicnet_proc_framed_pids_to_file "$_named_raw" "$_named_result"; then
                _named_rc=0
            else
                _named_rc=$?
            fi
        fi
    elif [ -x /system/bin/getprop ]; then
        _named_reader="${MODDIR}/cli"
        if [ -x "$_named_reader" ]; then
            if "$_named_reader" __proc-pids "$_named_process" >"$_named_raw" 2>/dev/null; then
                _named_lookup_rc=0
            else
                _named_lookup_rc=$?
            fi
            if [ "$_named_lookup_rc" -eq 0 ]; then
                if magicnet_proc_framed_pids_to_file "$_named_raw" "$_named_result"; then
                    _named_rc=0
                else
                    _named_rc=$?
                fi
            fi
        fi
    elif command -v pidof >/dev/null 2>&1; then
        if pidof "$_named_process" >"$_named_raw" 2>/dev/null; then
            _named_lookup_rc=0
        else
            _named_lookup_rc=$?
        fi
        case "$_named_lookup_rc" in
        0)
            if magicnet_proc_unframed_pids_to_file "$_named_raw" "$_named_result"; then
                _named_rc=0
            else
                _named_rc=$?
            fi
            ;;
        1)
            if : >"$_named_result"; then
                _named_rc=1
            else
                _named_rc=2
            fi
            ;;
        *) _named_rc=2 ;;
        esac
    fi
    if [ "$_named_rc" -eq 0 ]; then
        while IFS= read -r _named_pid; do
            printf '%s\n' "$_named_pid" >>"$_named_output" || {
                _named_rc=2
                break
            }
        done <"$_named_result"
    fi
    if [ "$_named_rc" -eq 2 ]; then
        : >"$_named_output" 2>/dev/null || true
    fi
    rm -f "$_named_raw" "$_named_result"
    return "$_named_rc"
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
    _proc_pid_dir="$_proc_root/$_proc_pid"
    [ -d "$_proc_pid_dir" ] || return 1
    if type magicnet_proc_reader_test_hook >/dev/null 2>&1; then
        if magicnet_proc_reader_test_hook cmdline "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    elif magicnet_host_proc_reader_allowed; then
        if magicnet_host_proc_reader cmdline "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    else
        _proc_reader="${MODDIR}/cli"
        [ -x "$_proc_reader" ] || return 2
        if "$_proc_reader" __proc-cmdline "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    fi
    [ "$_proc_rc" -eq 0 ] && return 0
    [ -d "$_proc_pid_dir" ] || return 1
    return 2
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
    _proc_pid_dir="$_proc_root/$_proc_pid"
    [ -d "$_proc_pid_dir" ] || return 1
    if type magicnet_proc_reader_test_hook >/dev/null 2>&1; then
        if magicnet_proc_reader_test_hook comm "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    elif magicnet_host_proc_reader_allowed; then
        if magicnet_host_proc_reader comm "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    else
        _proc_reader="${MODDIR}/cli"
        [ -x "$_proc_reader" ] || return 2
        if "$_proc_reader" __proc-comm "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    fi
    [ "$_proc_rc" -eq 0 ] && return 0
    [ -d "$_proc_pid_dir" ] || return 1
    return 2
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
    _proc_pid_dir="$_proc_root/$_proc_pid"
    [ -d "$_proc_pid_dir" ] || return 1
    if type magicnet_proc_reader_test_hook >/dev/null 2>&1; then
        if magicnet_proc_reader_test_hook stat "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    elif magicnet_host_proc_reader_allowed; then
        if magicnet_host_proc_reader stat "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    else
        _proc_reader="${MODDIR}/cli"
        [ -x "$_proc_reader" ] || return 2
        if "$_proc_reader" __proc-stat "$_proc_root" "$_proc_pid"; then _proc_rc=0; else _proc_rc=$?; fi
    fi
    [ "$_proc_rc" -eq 0 ] && return 0
    [ -d "$_proc_pid_dir" ] || return 1
    return 2
)

# Read /proc/<pid>/stat starttime. Optional second argument overrides the proc
# root (tests inject a fixture tree via MAGICNET_SUB_REFRESH_PROC_ROOT).
magicnet_proc_start() {
    _proc_pid="$1"
    _proc_root="${2:-${MAGICNET_PROC_ROOT:-/proc}}"
    case "$_proc_pid" in
    '' | *[!0-9]*)
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start _proc_read_rc
        return 1
        ;;
    esac
    case "$_proc_root" in
    /*) ;;
    *)
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start _proc_read_rc
        return 1
        ;;
    esac
    if _proc_identity="$(magicnet_proc_stat_identity "$_proc_pid" "$_proc_root")"; then
        _proc_read_rc=0
    else
        _proc_read_rc=$?
    fi
    if [ "$_proc_read_rc" -ne 0 ]; then
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start
        return "$_proc_read_rc"
    fi
    _proc_state=${_proc_identity%% *}
    _proc_start=${_proc_identity#* }
    case "$_proc_state" in
    [A-Za-z]) ;;
    *)
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start _proc_read_rc
        return 2
        ;;
    esac
    case "$_proc_start" in
    '' | *[!0-9]*)
        unset _proc_pid _proc_root _proc_identity _proc_state _proc_start _proc_read_rc
        return 2
        ;;
    esac
    printf '%s\n' "$_proc_start"
    unset _proc_pid _proc_root _proc_identity _proc_state _proc_start _proc_read_rc
}

magicnet_proc_state() {
    _proc_state_pid="$1"
    _proc_state_root="${2:-${MAGICNET_PROC_ROOT:-/proc}}"
    if _proc_state_identity="$(magicnet_proc_stat_identity "$_proc_state_pid" "$_proc_state_root")"; then
        _proc_state_read_rc=0
    else
        _proc_state_read_rc=$?
    fi
    if [ "$_proc_state_read_rc" -ne 0 ]; then
        unset _proc_state_pid _proc_state_root _proc_state_identity _proc_state
        return "$_proc_state_read_rc"
    fi
    _proc_state=${_proc_state_identity%% *}
    case "$_proc_state" in
    [A-Za-z]) printf '%s\n' "$_proc_state" ;;
    *)
        unset _proc_state_pid _proc_state_root _proc_state_identity _proc_state _proc_state_read_rc
        return 2
        ;;
    esac
    unset _proc_state_pid _proc_state_root _proc_state_identity _proc_state _proc_state_read_rc
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
