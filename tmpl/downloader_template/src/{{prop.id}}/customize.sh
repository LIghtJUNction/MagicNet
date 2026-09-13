SKIPUNZIP=1
# Run inside the manager's existing installer; do not recursively launch ksud.
[ "${BOOTMODE:-false}" = true ] || abort '! Install from the running Android system'
[ "${ARCH:-}" = arm64 ] || abort '! This downloader requires Android arm64'
command -v install_module >/dev/null 2>&1 || abort '! Manager install_module API unavailable'
unzip -o "$ZIPFILE" module.prop download.json 'bin/*' -d "$MODPATH" >&2 || abort '! Cannot extract downloader'
chmod 0755 "$MODPATH/bin/module-downloader" || abort '! Cannot set executable permission'
ui_print '- Checking network and latest release...'
(
  set -eu
  umask 077
  work=$(mktemp -d "${MODPATH}.download.XXXXXX")
  trap 'rm -rf "$work"' 0
  trap 'exit 130' 2
  trap 'exit 143' 1 15
  unset LD_LIBRARY_PATH LD_PRELOAD
  "$MODPATH/bin/module-downloader" -config "$MODPATH/download.json" -out "$work/module.zip"
  ui_print '- Verified. Installing target module...'
  (
    ZIPFILE="$work/module.zip"
    TMPDIR="$work/manager"
    unset SKIPUNZIP
    install_module
  )
) || abort '! Download or installation failed; see the error above'
touch "$MODPATH/skip_mount"
ui_print '- Done. Reboot to activate the downloaded module.'
