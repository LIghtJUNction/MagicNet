# shellcheck shell=ash
#
# Kamfw-free helpers for isolated sing-box subscription loads.

magicnet_singbox_config_file() {
    printf '%s\n' "${MAGICNET_SUB_CONFIG_FILE:-${MODDIR}/.config/sing-box/config.json}"
}

magicnet_singbox_subscription_config_file() {
    magicnet_singbox_config_file
}

magicnet_subscription_schedule_file() {
    printf '%s\n' "${MODDIR}/.config/magicnet/subscription-refresh-hours"
}

magicnet_singbox_config_has_nodes() {
    _config=$(magicnet_singbox_config_file)
    [ -f "$_config" ] || {
        unset _config
        return 1
    }
    type magicnet_singbox_ai_selectors_canonical >/dev/null 2>&1 ||
        . "${MODDIR}/lib/magicnet/singbox_subscribe/common.sh"
    grep -Eq '"type"[[:space:]]*:[[:space:]]*"(vless|hysteria2|trojan|vmess|shadowsocks|wireguard|tuic|anytls|socks)"' "$_config" &&
        magicnet_singbox_ai_selectors_canonical "$_config"
    _rc=$?
    unset _config
    return "$_rc"
}

command -v error >/dev/null 2>&1 || error() { printf '%s\n' "ERROR: $1"; }
command -v warn >/dev/null 2>&1 || warn() { printf '%s\n' "WARN: $1"; }
command -v success >/dev/null 2>&1 || success() { printf '%s\n' "$1"; }

magicnet_jq_ai_tags_lib() {
    if type magicnet_lib_dir >/dev/null 2>&1; then
        printf '%s\n' "$(magicnet_lib_dir)/jq"
    else
        printf '%s\n' "${MODDIR}/lib/magicnet/jq"
    fi
}

magicnet_jq() {
    [ -x "${MODDIR}/bin/jq" ] || return 1
    printf '%s\n' "${MODDIR}/bin/jq"
}

magicnet_require_jq() {
    _jq="$(magicnet_jq)" || {
        if command -v magicnet_warn >/dev/null 2>&1; then
            magicnet_warn "${1:-packaged jq is unavailable; config apply rejected}"
        else
            warn "${1:-packaged jq is unavailable; config apply rejected}"
        fi
        return 1
    }
    printf '%s\n' "$_jq"
}

# jq can exit successfully without producing a document (for example `empty`
# or `halt`). A config is exactly one JSON object, not merely successful output.
magicnet_json_object_valid() (
    [ -s "$1" ] || return 1
    _json_jq="${2:-$(magicnet_jq)}"
    [ -n "$_json_jq" ] || return 1
    "$_json_jq" -s -e 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
)

magicnet_jq_install_config() (
    _config="$1"
    _tmp="$2"
    shift 2
    # Never let a bad caller or leftover symlink truncate the active file.
    [ "$_config" != "$_tmp" ] && [ ! -L "$_tmp" ] || return 1
    _install_jq="$(magicnet_require_jq)" || return 1
    trap 'rm -f "$_tmp"' 0
    trap 'exit 1' 1 2 3 15
    umask 077
    "$@" >"$_tmp" &&
        magicnet_json_object_valid "$_tmp" "$_install_jq" &&
        chmod 600 "$_tmp" && mv -f "$_tmp" "$_config"
)

magicnet_singbox_config_shape_valid() (
    _shape_jq="$(magicnet_jq)" || return 1
    magicnet_json_object_valid "$1" "$_shape_jq" || return 1
    "$_shape_jq" -e '
      (.inbounds | type == "array" and length > 0)
      and (.outbounds | type == "array" and length > 0)
    ' "$1" >/dev/null 2>&1
)

# Recovery is a local, bounded core check. Never fetch a subscription or launch
# another service process from inside this check while holding the config lock.
magicnet_singbox_recovery_config_valid() (
    magicnet_singbox_config_shape_valid "$1" || return 1
    command -v sing-box >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    timeout -k 2 15 sing-box check -c "$1" -D "${MODDIR}/.config/sing-box" >/dev/null 2>&1
)

# Called under the config lock after successful startup/activation. The single
# atomic envelope includes the nodes themselves, so recovery does not depend on
# the disposable subscription-work directory or an available subscription URL.
magicnet_singbox_save_last_good() (
    _good_config="${MODDIR}/.config/sing-box/config.json"
    _good_dir="${MODDIR}/.state/sing-box"
    _good_jq="$(magicnet_jq)" || return 1
    _good_mode="$(magicnet_transparent_mode)" || return 1
    case "$_good_mode" in tun | ebpf) ;; *) return 1 ;; esac
    magicnet_singbox_config_shape_valid "$_good_config" || return 1
    umask 077
    mkdir -p "$_good_dir" && chmod 700 "$_good_dir" || return 1
    _good_tmp="$(mktemp "$_good_dir/.last-good.XXXXXX")" || return 1
    trap 'rm -f "$_good_tmp" "$_good_tmp.envelope"' 0
    trap 'exit 1' 1 2 3 15
    # The one-use Tailscale login key must not survive in a recovery checkpoint.
    "$_good_jq" '
      if (.endpoints | type) == "array" then
        .endpoints |= map(if .type == "tailscale" then del(.auth_key) else . end)
      else . end
    ' "$_good_config" >"$_good_tmp" || return 1
    magicnet_singbox_recovery_config_valid "$_good_tmp" || return 1
    "$_good_jq" -n --arg mode "$_good_mode" --slurpfile config "$_good_tmp" '
      {schema: 1, mode: $mode, config: $config[0]}
    ' >"$_good_tmp.envelope" || return 1
    magicnet_json_object_valid "$_good_tmp.envelope" "$_good_jq" &&
        chmod 600 "$_good_tmp.envelope" &&
        mv -f "$_good_tmp.envelope" "$_good_dir/last-good-config.json"
)

# Restore only structurally broken/missing active configs. A valid user edit,
# mode change or an incompatible checkpoint is never silently overwritten.
magicnet_singbox_restore_last_good() (
    _restore_config="${MODDIR}/.config/sing-box/config.json"
    _restore_good="${MODDIR}/.state/sing-box/last-good-config.json"
    [ -s "$_restore_good" ] || return 1
    magicnet_singbox_config_shape_valid "$_restore_config" && return 1
    _restore_jq="$(magicnet_jq)" || return 1
    _restore_mode="$(magicnet_transparent_mode)" || return 1
    case "$_restore_mode" in tun | ebpf) ;; *) return 1 ;; esac
    magicnet_json_object_valid "$_restore_good" "$_restore_jq" || return 1
    "$_restore_jq" -e --arg mode "$_restore_mode" '
      .schema == 1 and .mode == $mode and (.config | type == "object")
    ' "$_restore_good" >/dev/null 2>&1 || return 1
    umask 077
    mkdir -p "${_restore_config%/*}" || return 1
    _restore_tmp="$(mktemp "${_restore_config}.recover.XXXXXX")" || return 1
    trap 'rm -f "$_restore_tmp"' 0
    trap 'exit 1' 1 2 3 15
    "$_restore_jq" '.config' "$_restore_good" >"$_restore_tmp" || return 1
    magicnet_singbox_recovery_config_valid "$_restore_tmp" &&
        chmod 600 "$_restore_tmp" && mv -f "$_restore_tmp" "$_restore_config"
)

magicnet_list_file_values() {
    _file="$1"
    [ -f "$_file" ] || return 0
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$_file" 2>/dev/null | awk '!seen[$0]++'
}
