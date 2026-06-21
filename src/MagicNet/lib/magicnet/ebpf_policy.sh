magicnet_ebpf_tcp6_mode() {
    _metm_mode="${MAGICNET_EBPF_TCP6_MODE:-bridge}"
    case "$_metm_mode" in
        bridge|block)
            printf '%s\n' "$_metm_mode"
            unset _metm_mode
            return 0
            ;;
    esac
    unset _metm_mode
    printf '%s\n' "bridge"
}
