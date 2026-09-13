SKIPUNZIP=1
# Run inside the manager's existing installer; do not recursively launch ksud.
[ "${BOOTMODE:-false}" = true ] || abort '! Install from the running Android system'
[ "${ARCH:-}" = arm64 ] || abort '! This downloader requires Android arm64'
command -v install_module >/dev/null 2>&1 || abort '! Manager install_module API unavailable'
unzip -o "$ZIPFILE" module.prop download.json 'bin/*' -d "$MODPATH" >&2 || abort '! Cannot extract downloader'
chmod 0755 "$MODPATH/bin/module-downloader" || abort '! Cannot set executable permission'
ui_print '- Smart install: checking release, local components and verified cache...'
(
  set -eu
  umask 077
  work=$(mktemp -d "${MODPATH}.download.XXXXXX") || exit 1
  trap 'rm -rf "$work"' 0
  trap 'exit 130' 2
  trap 'exit 143' 1 15
  unset LD_LIBRARY_PATH LD_PRELOAD
  "$MODPATH/bin/module-downloader" -config "$MODPATH/download.json" -out "$work/module.zip" || exit $?
  if [ -f "$work/module.zip.current" ]; then
    ui_print '- Components are already current or staged. No module download needed.'
    exit 0
  fi
  ui_print '- Verified. Installing target module; unchanged components will be reused...'
  (
    ZIPFILE="$work/module.zip"
    TMPDIR="$work/manager"
    unset SKIPUNZIP
    # Manager helpers intentionally read optional arguments and unset variables.
    # Keep strict options out of the manager and target customize.sh.
    set +eu
    install_module
    result=$?
    exit "$result"
  )
) || abort '! Download or installation failed; see the error above'
touch "$MODPATH/skip_mount"
ui_print '- Done. Reboot to activate the downloaded module.'
