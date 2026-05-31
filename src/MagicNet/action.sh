# shellcheck shell=ash

MODDIR=${0%/*}
if [ -f "${MODDIR}/lib/kamfw/.kamfwrc" ]; then
    . "$MODDIR/lib/kamfw/.kamfwrc"
else
    abort '! File ".kamfwrc" does not exist!'
fi

import __runtime__

kamfw_init_home
kamfw_init_paths

if has_command "sing-box"; then
    import __singbox__
    singbox_ask_webui
    ask_toggle_singbox
    [ -f "${MODDIR}/hotspot-forward.sh" ] && . "${MODDIR}/hotspot-forward.sh" && magicnet_enable_hotspot_forward
    [ -f "${MODDIR}/vpn-coexist.sh" ] && . "${MODDIR}/vpn-coexist.sh" && magicnet_enable_vpn_coexist
elif has_command "mihomo"; then
    import __mihomo__
    ask_webui
    ask_toggle_mihomo
    [ -f "${MODDIR}/hotspot-forward.sh" ] && . "${MODDIR}/hotspot-forward.sh" && magicnet_enable_hotspot_forward
    [ -f "${MODDIR}/vpn-coexist.sh" ] && . "${MODDIR}/vpn-coexist.sh" && magicnet_enable_vpn_coexist
else
    abort "No supported kernel found!"
fi
