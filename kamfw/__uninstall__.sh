# shellcheck shell=ash
#
# Optional uninstall phase helpers.
#
# Modules that need uninstall-time cleanup can either:
# - ship a root-manager uninstall.sh that calls `kamfw run uninstall -- "$@"`, or
# - register rollback commands through prop.sh, which creates uninstall.sh lazily.
#
# The default phase is intentionally quiet when no uninstall hooks exist.

kamfw_run_uninstall_hooks() {
	_uninstall_rc=0
	for _uninstall_hook_dir in \
		"${KAM_HOME}/.config/kamfw/uninstall.d" \
		"${KAM_HOME}/lib/kamfw/uninstall.d"; do
		[ -d "$_uninstall_hook_dir" ] || continue
		for _uninstall_hook in "$_uninstall_hook_dir"/*.sh; do
			[ -f "$_uninstall_hook" ] || continue
			sh "$_uninstall_hook" "$@" || _uninstall_rc=1
		done
	done
	unset _uninstall_hook_dir _uninstall_hook
	return "$_uninstall_rc"
}

kamfw_phase_uninstall() {
	kamfw_run_uninstall_hooks "$@"
}
