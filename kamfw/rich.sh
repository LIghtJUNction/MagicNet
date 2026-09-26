# shellcheck shell=ash
# This file is a compatibility loader; implementation lives in focused files.
__kamfw_rich_dir="${KAMFW_DIR:-${MODDIR:-${0%/*}}/lib/kamfw}"
if [ ! -d "${__kamfw_rich_dir}/rich_rendering" ]; then
    printf '%s\n' "Missing rich rendering library: ${__kamfw_rich_dir}/rich_rendering" >&2
    return 1 2>/dev/null || exit 1
fi
. "${__kamfw_rich_dir}/rich_rendering/layout.sh" || { __kam_part_status=$?; unset __kamfw_rich_dir; return "$__kam_part_status" 2>/dev/null || exit "$__kam_part_status"; }
. "${__kamfw_rich_dir}/rich_rendering/interactive_prompts.sh" || { __kam_part_status=$?; unset __kamfw_rich_dir; return "$__kam_part_status" 2>/dev/null || exit "$__kam_part_status"; }
. "${__kamfw_rich_dir}/rich_rendering/install_prompts.sh" || { __kam_part_status=$?; unset __kamfw_rich_dir; return "$__kam_part_status" 2>/dev/null || exit "$__kam_part_status"; }
unset __kamfw_rich_dir __kam_part_status
