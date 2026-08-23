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
