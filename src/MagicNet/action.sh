# shellcheck shell=ash

MODDIR=${0%/*}
[ -f "${MODDIR}/lib/kamfw/.kamfwrc" ] && . "$MODDIR/lib/kamfw/.kamfwrc" || abort '! File ".kamfwrc" does not exist!'

import __runtime__

kamfw_init_home
kamfw_init_paths

if has_command "sing-box"; then
    import __singbox__
    singbox_ask_webui
    ask_toggle_singbox
elif has_command "mihomo"; then
    import __mihomo__
    ask_webui
    ask_toggle_mihomo
else
    abort "No supported kernel found!"
fi
