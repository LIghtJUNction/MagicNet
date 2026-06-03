# shellcheck shell=ash

magicnet_ipset_lkm_status() {
    if [ -d /sys/module/ip_set ] || [ -r /proc/net/ip_set ]; then
        printf '%s\n' "kernel"
        return 0
    fi
    if magicnet_cmd_exists ipset && ipset list -name >/dev/null 2>&1; then
        printf '%s\n' "userspace"
        return 0
    fi
    printf '%s\n' "missing"
    return 1
}

magicnet_ipset_lkm_try_load_one() {
    _module="$1"
    for _loader in insmod modprobe; do
        magicnet_cmd_exists "$_loader" || continue
        for _path in \
            "${MODDIR}/.local/lib/modules/${_module}.ko" \
            "/data/adb/netfilter/${_module}.ko" \
            "/data/adb/modules/IPSET_LKM/${_module}.ko"; do
            [ -f "$_path" ] || continue
            "$_loader" "$_path" >/dev/null 2>&1 && return 0
        done
    done
    unset _module _loader _path
    return 1
}

magicnet_ipset_lkm_prepare() {
    case "$(magicnet_ipset_lkm_status)" in
        kernel|userspace) return 0 ;;
    esac

    # Optional integration with TanakaLun/IPSET_LKM. It is device-kernel-specific,
    # so MagicNet only consumes an already installed module instead of bundling one.
    for _module in ip_set ip_set_hash_net xt_set; do
        magicnet_ipset_lkm_try_load_one "$_module" || true
    done

    case "$(magicnet_ipset_lkm_status)" in
        kernel|userspace)
            magicnet_log "IPSET_LKM/ipset is available"
            return 0
            ;;
        *)
            magicnet_warn "ipset unavailable; IPSET_LKM optional acceleration skipped"
            return 0
            ;;
    esac
}
