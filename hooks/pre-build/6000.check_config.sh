#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

. "$KAM_HOOKS_ROOT/lib/utils.sh"

KAM_MODULE_ROOT=$(cd "$KAM_MODULE_ROOT" && pwd)
export HOME=$KAM_MODULE_ROOT

MAGIC_MIHOMO=${MAGIC_MIHOMO:-1}
MAGIC_SINGBOX=${MAGIC_SINGBOX:-1}
MAGIC_CONFIG_CHECK_STRICT=${MAGIC_CONFIG_CHECK_STRICT:-0}

check_yaml_syntax() {
    local file="$1"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$file" <<'PY'
import pathlib
import sys
import yaml

yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
PY
        return $?
    fi

    log_warn "python3 not found; YAML syntax check skipped for $file"
    return 0
}

check_singbox_json_policy() {
    local file="$1"

    require_command jq "jq not found!"
    jq empty "$file"

    if jq -e '
        [
          .. | strings | select(startswith("geosite:") or startswith("geoip:"))
        ] | length > 0
    ' "$file" >/dev/null; then
        log_error "sing-box config uses legacy geosite:/geoip: strings; sing-box 1.13+ no longer ships those databases"
        return 1
    fi

    if jq -e '
        [
          .. | objects | keys[]? | select(. == "geosite" or . == "geoip" or . == "source_geoip")
        ] | length > 0
    ' "$file" >/dev/null; then
        log_error "sing-box config uses deprecated geosite/geoip rule fields; migrate to rule-set or explicit rules"
        return 1
    fi
}

can_run_kernel_check() {
    local command_name="$1"

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    if [ "$MAGIC_CONFIG_CHECK_STRICT" = "1" ]; then
        require_command "$command_name" "$command_name not found!"
    fi

    log_warn "$command_name not found; runtime config check skipped"
    return 1
}

if [ "$MAGIC_MIHOMO" -ne 0 ] && [ -f "$HOME/.config/mihomo/config.yaml" ]; then
    log_info "Checking mihomo YAML syntax..."
    check_yaml_syntax "$HOME/.config/mihomo/config.yaml" || exit 1

    if can_run_kernel_check mihomo; then
        log_info "Checking mihomo config..."
        mihomo -v || true
        mihomo -t -f "$HOME/.config/mihomo/config.yaml" -d "$HOME/.config/mihomo" || exit 1
    fi
fi

if [ "$MAGIC_SINGBOX" -ne 0 ] && [ -f "$HOME/.config/sing-box/config.json" ]; then
    log_info "Checking sing-box JSON and 2026 policy..."
    check_singbox_json_policy "$HOME/.config/sing-box/config.json" || exit 1

    if can_run_kernel_check sing-box; then
        log_info "Checking sing-box config..."
        sing-box version || true
        sing-box check -c "$HOME/.config/sing-box/config.json" -D "$HOME/.config/sing-box" || exit 1
    fi
fi
