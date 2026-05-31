#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
# shellcheck source=hooks/lib/release_utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
. "$KAM_HOOKS_ROOT/lib/release_utils.sh"

require_command gh "gh not installed!"
require_command curl "curl not found!"

REPO="DustinWin/ruleset_geodata"
TAG="mihomo-geodata"
DATA_DIR="$KAM_MODULE_ROOT/.config/mihomo"
HASH_DIR="$KAM_MODULE_ROOT/.local/state/geodata"

mkdir -p "$DATA_DIR" "$HASH_DIR"

github_download_if_changed \
    "$REPO" \
    "$TAG" \
    "geoip-all.dat" \
    "https://github.com/DustinWin/ruleset_geodata/releases/download/mihomo-geodata/geoip-all.dat" \
    "$DATA_DIR/GeoIP.dat" \
    "$HASH_DIR/geoip.hash"

github_download_if_changed \
    "$REPO" \
    "$TAG" \
    "geosite-all.dat" \
    "https://github.com/DustinWin/ruleset_geodata/releases/download/mihomo-geodata/geosite-all.dat" \
    "$DATA_DIR/GeoSite.dat" \
    "$HASH_DIR/geosite.hash"
