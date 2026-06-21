magicnet_ebpf_allow_multi_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/ebpf-allow-multi.conf"
}

magicnet_ebpf_profile_conf() {
    printf '%s\n' "${MODDIR}/.config/magicnet/ebpf-profile.conf"
}

magicnet_ebpf_allow_multi_enabled() {
    _ebpf_allow_conf="$(magicnet_ebpf_allow_multi_conf)"
    if [ -f "$_ebpf_allow_conf" ]; then
        . "$_ebpf_allow_conf"
    fi
    case "${MAGICNET_EBPF_ALLOW_MULTI:-0}" in
        1|true|yes|on) _ebpf_allow_rc=0 ;;
        *) _ebpf_allow_rc=1 ;;
    esac
    unset _ebpf_allow_conf
    return "$_ebpf_allow_rc"
}

magicnet_ebpf_profile() {
    _ebpf_profile_conf="$(magicnet_ebpf_profile_conf)"
    if [ -f "$_ebpf_profile_conf" ]; then
        . "$_ebpf_profile_conf"
    fi
    case "${MAGICNET_EBPF_PROFILE:-tcp}" in
        tcp|tcp-bridge|"") printf '%s\n' "tcp" ;;
        *) printf '%s\n' "tcp" ;;
    esac
    unset _ebpf_profile_conf
}
