# shellcheck shell=ash
import app

require_termux() {
    require_app "com.termux" "Termux Not Installed!"
}

set_termux_home() {
    # MagicNet lifecycle code runs as root and must retain its module-owned
    # HOME instead of adopting an application-private directory.
    :
}

active_termux_env() {
    # Compatibility no-op. Root module lifecycles must never source
    # application-owned Termux shell files or add app/home-owned binaries.
    :
}

deactivate_termux_env() {
    :
}
