# shellcheck shell=ash

support_arch() {
	_arch="$@"
	_flag=false
	for _arch in "$@"; do
		case "$_arch" in
		arm | arm64 | x86 | x64) ;;
		*)
			unset _arch _flag
			abort "out of range [ arm, arm64, x86, x64 ]"
			;;
		esac
		if [ "$ARCH" = "$_arch" ]; then
			_flag=true
			break
		fi
	done

	if [ "$_flag" = false ]; then
		unset _arch _flag
		abort "architecture not supported"
	fi

	unset _arch _flag
}

# is_arch [arch...]
# Return 0 if $ARCH matches any of the given architectures (arm|arm64|x86|x64).
# Does not abort on invalid arguments; invalid names are ignored.
is_arch() {
	# No arguments -> false
	if [ $# -eq 0 ]; then
		return 1
	fi

	for _arch in "$@"; do
		case "$_arch" in
		arm | arm64 | x86 | x64)
			if [ "$ARCH" = "$_arch" ]; then
				unset _arch
				return 0
			fi
			;;
		*)
			# ignore invalid values
			;;
		esac
	done

	unset _arch
	return 1
}
