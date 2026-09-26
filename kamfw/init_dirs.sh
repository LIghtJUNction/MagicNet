#!/usr/bin/env sh
# kamfw directory initialization helpers

kam_init_dirs() {
  _kam_check_required="${KAM_INIT_DIRS_REQUIRED:-0}"
  if [ "${1:-}" = "--required" ]; then
    _kam_check_required=1
    shift
  fi

  if [ -z "${KAM_HOME:-}" ]; then
    if command -v print >/dev/null 2>&1; then
      print "ERROR: KAM_HOME is not set; cannot init dirs"
    else
      printf '%s\n' "ERROR: KAM_HOME is not set; cannot init dirs" >&2
    fi
    return 1
  fi

  # Temporary workspaces are created by their owners on demand.
  # Remove only the unused legacy directory, never active/non-empty data.
  rmdir "$KAM_HOME/tmp" 2>/dev/null || true

  # Keep runtime state under $KAM_HOME.
  _kam_dirs="\
$KAM_HOME/.config \
$KAM_HOME/.cache \
$KAM_HOME/.state \
$KAM_HOME/.log\
"

  for _d in $_kam_dirs; do
    if [ -n "$_d" ] && [ ! -d "$_d" ]; then
      mkdir -p "$_d" 2>/dev/null
      if [ $? -ne 0 ]; then
        if command -v print >/dev/null 2>&1; then
          print "ERROR: failed to mkdir -p '$_d'"
        else
          printf '%s\n' "ERROR: failed to mkdir -p '$_d'" >&2
        fi
        return 1
      fi
    fi
  done

  if [ "$_kam_check_required" = "1" ]; then
    for _d in $_kam_dirs; do
      [ -n "$_d" ] || continue
      if [ ! -d "$_d" ]; then
        if command -v print >/dev/null 2>&1; then
          print "ERROR: required dir missing: $_d"
        else
          printf '%s\n' "ERROR: required dir missing: $_d" >&2
        fi
        return 1
      fi
    done
  fi

  return 0
}
