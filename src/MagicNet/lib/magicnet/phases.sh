kamfw_phase_boot_completed() {
    wait_boot_if_magisk
    sleep 3
    magicnet_start_kernel
}

kamfw_phase_service() {
    kamfw_phase_boot_completed "$@"
}

kamfw_phase_action() {
    magicnet_action
}
