# shellcheck shell=ash
#
# Kamfw-free helpers shared by common.sh and isolated subscribe loads.

magicnet_json_escape() {
    LC_ALL=C printf '%s' "$1" |
        tr '\r\n\t' '   ' |
        sed 's/[[:cntrl:]]//g; s/\\/\\\\/g; s/"/\\"/g'
}

magicnet_proc_start_time() {
    _proc_pid="$1"
    _proc_root="${2:-/proc}"
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
