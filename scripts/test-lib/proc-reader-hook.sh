# shellcheck shell=bash

# Test-only bounded proc fixture reader. Production always uses the Rust helper;
# Bash mapfile is sufficient for regular fixture files and preserves argv NUL
# boundaries without spawning the legacy tr pipelines.
magicnet_proc_reader_test_hook() {
  local kind="$1" proc_root="$2" pid="$3" argument count
  local -a argv=()
  if test -n "${PROC_READER_COUNT_FILE:-}"; then
    count=$(cat "$PROC_READER_COUNT_FILE" 2>/dev/null || printf '0\n')
    printf '%s\n' "$((count + 1))" >"$PROC_READER_COUNT_FILE"
  fi

  case "$kind" in
  cmdline)
    mapfile -d '' -t argv <"$proc_root/$pid/cmdline" || true
    test "${#argv[@]}" -gt 0 || return 1
    for argument in "${argv[@]}"; do
      test -n "$argument" || return 1
      case "$argument" in *$'\n'* | *$'\r'*) return 1 ;; esac
      printf '%s\n' "$argument"
    done
    ;;
  comm)
    IFS= read -r argument <"$proc_root/$pid/comm"
    test -n "$argument" || return 1
    case "$argument" in *$'\n'* | *$'\r'*) return 1 ;; esac
    printf '%s\n' "$argument"
    ;;
  stat)
    local stat rest
    local -a fields=()
    test -r "$proc_root/$pid/stat" || return 1
    stat=$(<"$proc_root/$pid/stat")
    rest=${stat##*) }
    read -r -a fields <<<"$rest"
    test "${#fields[@]}" -ge 20 || return 1
    case "${fields[0]}" in [A-Za-z]) ;; *) return 1 ;; esac
    case "${fields[19]}" in '' | *[!0-9]*) return 1 ;; esac
    printf '%s %s\n' "${fields[0]}" "${fields[19]}"
    ;;
  *) return 1 ;;
  esac
}
