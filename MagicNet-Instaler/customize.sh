# shellcheck shell=ash

SKIPUNZIP=1
if [ -d /data/data/com.termux/files/usr/bin/ ]; then
    export PATH=/data/data/com.termux/files/usr/bin:$PATH
    export HOME=/data/data/com.termux/files/home
fi

config_manager() {
    if [ -x "$KSU" ]; then
        ui_print "KSU";
        kam config set --global root.manager ksu
    elif [ -x "$APATCH" ]; then
        ui_print "AP"
        kam config set --global root.manager ap
    else
        ui_print "fallback to magisk"
        kam config set --global root.manager magisk
    fi
}

install_magicnet() {
    pwd
    kam -Sy MagicNet 2>&1
    echo "Installing MagicNet..."
    config_manager
    ls -la
    kam install MagicNet.zip 2>&1
}

if [ -x "$(command -v kam)" ]; then
    install_magicnet || {kam --version 2>&1 ; abort "Failed to install ! try to update kam! ";}
else
    abort "kam is not installed!"
fi
