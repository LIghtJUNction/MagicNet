#!/system/bin/sh
# shellcheck shell=ash

case "$0" in
    */*) MODDIR=${0%/*} ;;
    *) MODDIR=${MODDIR:-$(pwd)} ;;
esac
export MODDIR MODPATH="${MODPATH:-$MODDIR}"

_mn_state_dir="${MODDIR}/.state"
_mn_runner="${_mn_state_dir}/post-fs-data-service.sh"
mkdir -p "$_mn_state_dir" "${MODDIR}/.log" 2>/dev/null || true
cat >"$_mn_runner" <<'EOF'
#!/system/bin/sh
: "${MODDIR:?}"
MODPATH="${MODPATH:-$MODDIR}"
export MODDIR MODPATH
_mn_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || date +%s)"
_mn_state_dir="${MODDIR}/.state"
_mn_stamp="${_mn_state_dir}/post-fs-data-service.boot"
mkdir -p "$_mn_state_dir" "${MODDIR}/.log" 2>/dev/null || true
if [ -f "$_mn_stamp" ] && [ "$(sed -n '1p' "$_mn_stamp" 2>/dev/null)" = "$_mn_boot_id" ]; then
    exit 0
fi
printf '%s\n' "$_mn_boot_id" >"$_mn_stamp" 2>/dev/null || true
_mn_wait=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_mn_wait" -lt 120 ]; do
    sleep 2
    _mn_wait=$((_mn_wait + 2))
done
sh "${MODDIR}/service.sh" >>"${MODDIR}/.log/service.log" 2>&1 || true
EOF
chmod 0755 "$_mn_runner" 2>/dev/null || true
if command -v nohup >/dev/null 2>&1; then
    MODDIR="$MODDIR" MODPATH="$MODPATH" nohup sh "$_mn_runner" >/dev/null 2>&1 &
else
    MODDIR="$MODDIR" MODPATH="$MODPATH" sh "$_mn_runner" >/dev/null 2>&1 &
fi
unset _mn_state_dir _mn_runner

exit 0
