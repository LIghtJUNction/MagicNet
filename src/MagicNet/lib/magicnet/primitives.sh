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

# Read /proc/<pid>/stat starttime. Optional second argument overrides the proc
# root (tests inject a fixture tree via MAGICNET_SUB_REFRESH_PROC_ROOT).
magicnet_proc_start() {
    _proc_pid="$1"
    _proc_root="${2:-${MAGICNET_PROC_ROOT:-/proc}}"
    case "$_proc_pid" in
        '' | *[!0-9]*)
            unset _proc_pid _proc_root _proc_stat _proc_start
            return 1
            ;;
    esac
    case "$_proc_root" in
        /*) ;;
        *)
            unset _proc_pid _proc_root _proc_stat _proc_start
            return 1
            ;;
    esac
    _proc_stat="${_proc_root}/${_proc_pid}/stat"
    [ -r "$_proc_stat" ] || {
        unset _proc_pid _proc_root _proc_stat _proc_start
        return 1
    }
    _proc_start="$(awk '{ line = $0; sub(/^.*\) /, "", line); count = split(line, field, /[[:space:]]+/); if (count >= 20) print field[20] }' \
        "$_proc_stat" 2>/dev/null || true)"
    case "$_proc_start" in
        '' | *[!0-9]*)
            unset _proc_pid _proc_root _proc_stat _proc_start
            return 1
            ;;
    esac
    printf '%s\n' "$_proc_start"
    unset _proc_pid _proc_root _proc_stat _proc_start
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
    awk '{ line = $0; sub(/^.*\) /, "", line); count = split(line, field, /[[:space:]]+/); if (count >= 20) print field[20] }' \
        "$_proc_stat_path" 2>/dev/null || true
    unset _proc_stat_path
}

# KernelSU WebUI commands inherit the manager app's killable cgroup. Move only
# verified MagicNet daemons into stable parent cgroups before the bridge exits.
magicnet_detach_pid_from_app_cgroup() (
    _detach_pid="$1"
    _detach_proc_root="${MAGICNET_PROC_ROOT:-/proc}"
    case "$_detach_pid" in
        '' | *[!0-9]* | 0 | 1) return 1 ;;
    esac
    _detach_cgroup_file="${_detach_proc_root}/${_detach_pid}/cgroup"
    [ -r "$_detach_cgroup_file" ] || return 1
    _detach_cgroup="$(cat "$_detach_cgroup_file" 2>/dev/null || true)"
    _detach_app_lines=$(printf '%s\n' "$_detach_cgroup" | grep -c '/apps/uid_' 2>/dev/null || true)
    [ "$_detach_app_lines" -gt 0 ] || return 0

    _detach_default_roots='/sys/fs/cgroup:/dev/memcg/apps:/dev/cpuset:/dev/cpuctl:/dev/blkio:/dev/freezer'
    _detach_roots="${MAGICNET_PROCESS_CGROUP_ROOTS:-$_detach_default_roots}"
    _detach_custom=0
    [ -z "${MAGICNET_PROCESS_CGROUP_ROOTS:-}" ] || _detach_custom=1
    _detach_old_ifs=$IFS
    IFS=:
    _detach_required=0
    _detach_moved=0
    _detach_failed=0
    for _detach_root in $_detach_roots; do
        _detach_applicable=0
        if [ "$_detach_custom" -eq 1 ]; then
            _detach_applicable=1
        else
            case "$_detach_root" in
                /sys/fs/cgroup)
                    printf '%s\n' "$_detach_cgroup" | grep -q '^0::/apps/uid_' && _detach_applicable=1
                    ;;
                /dev/memcg/apps)
                    printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*memory[^:]*:/apps/uid_' && _detach_applicable=1
                    ;;
                /dev/cpuset)
                    printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*cpuset[^:]*:/apps/uid_' && _detach_applicable=1
                    ;;
                /dev/cpuctl)
                    printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*(cpu|cpuacct)[^:]*:/apps/uid_' && _detach_applicable=1
                    ;;
                /dev/blkio)
                    printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*blkio[^:]*:/apps/uid_' && _detach_applicable=1
                    ;;
                /dev/freezer)
                    printf '%s\n' "$_detach_cgroup" | grep -Eq ':[^:]*freezer[^:]*:/apps/uid_' && _detach_applicable=1
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
    IFS=$_detach_old_ifs
    [ "$_detach_required" -ge "$_detach_app_lines" ] &&
        [ "$_detach_moved" -eq "$_detach_required" ] &&
        [ "$_detach_failed" -eq 0 ]
)
