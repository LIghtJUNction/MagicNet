# shellcheck shell=ash
# Rebuild from this ZIP, importing subscription nodes rather than old policy.
# Runs in a subshell so installer paths, traps and runtime helpers stay isolated.
magicnet_refresh_install_config() (
    umask 077
    MODDIR="$MODPATH"
    PATH="${MODDIR}/bin:${MODDIR}/system/bin:${PATH:-}"
    export MODDIR PATH
    _refresh_config="${MODDIR}/.config/sing-box/config.json"
    _refresh_previous="${MAGICNET_BACKUP_DIR}/.config/sing-box/config.json"
    _refresh_backup="${_refresh_config}.pre-upgrade"
    _refresh_candidate="${_refresh_config}.install-new.$$"
    _refresh_work="${MODDIR}/.state/install-config.$$"
    for _refresh_path in "${MODDIR}/.config" "${MODDIR}/.config/sing-box" \
        "${MODDIR}/.state" "$_refresh_config" "$_refresh_backup"; do
        [ ! -L "$_refresh_path" ] || return 1
    done
    for _refresh_path in "$_refresh_config" "$_refresh_backup"; do
        [ ! -e "$_refresh_path" ] || [ -f "$_refresh_path" ] || return 1
    done
    mkdir -p "${MODDIR}/.state" || return 1
    mkdir "$_refresh_work" || return 1
    trap 'rm -rf "$_refresh_work"' 0
    (set -C; : >"$_refresh_candidate") || return 1
    trap 'rm -rf "$_refresh_work"; rm -f "$_refresh_candidate"' 0
    trap 'exit 1' 1 2 3 15

    # Never use the installed config as the template, including in-place flashes.
    unzip -p "$ZIPFILE" '.config/sing-box/config.json' >"$_refresh_candidate" || return 1
    [ -s "$_refresh_candidate" ] || return 1
    _refresh_cached="${MODDIR}/.state/sing-box/subscription-work/outbounds.json"
    _refresh_restored=0
    if [ -s "$_refresh_cached" ] || [ -s "$_refresh_previous" ]; then
        . "${MODDIR}/lib/magicnet_singbox_subscribe.sh" || return 1
        for _refresh_source in "$_refresh_cached" "$_refresh_previous"; do
            [ -f "$_refresh_source" ] && [ ! -L "$_refresh_source" ] || continue
            # Accept array/object caches and the legacy '"outbounds": [...],'
            # fragment. Never import DNS, routes, inbounds or old selectors.
            jq -R -s -e '
                (. as $raw | try fromjson catch ($raw | sub(",[[:space:]]*$"; "") | ("{" + . + "}") | fromjson))
                | if type == "array" then . else .outbounds end
                | select(type == "array")
                | map(select(type == "object" and (.server | type) == "string"))
                | select(length > 0)
            ' "$_refresh_source" >"$_refresh_work/nodes.json" 2>/dev/null || continue
            : >"$_refresh_work/tags.txt" || return 1
            magicnet_singbox_build_outbounds_file_with_jq \
                "$_refresh_work/nodes.json" "$_refresh_work/tags.txt" \
                "$_refresh_work/outbounds.json" || return 1
            jq -e 'any(.[]; (.server | type) == "string")' \
                "$_refresh_work/outbounds.json" >/dev/null || continue
            MAGICNET_SUB_CONFIG_FILE="$_refresh_candidate"
            export MAGICNET_SUB_CONFIG_FILE
            if ! magicnet_singbox_update_config_with_nodes "$_refresh_work/outbounds.json" >/dev/null 2>&1; then
                error "The regenerated sing-box config failed validation; the previous config was not replaced."
                return 1
            fi
            _refresh_restored=1
            break
        done
    fi
    if [ "$_refresh_restored" = 0 ] && [ -f "${MODDIR}/.config/sing-box/standalone-config" ]; then
        error "Cannot migrate standalone nodes to the new template; the previous config was not replaced."
        return 1
    fi

    # Keep one private, recoverable copy, not an ever-growing credential history.
    if [ -f "$_refresh_previous" ]; then
        cp "$_refresh_previous" "$_refresh_work/previous.json" &&
            chmod 600 "$_refresh_work/previous.json" &&
            mv -f "$_refresh_work/previous.json" "$_refresh_backup" || return 1
    fi
    chmod 600 "$_refresh_candidate" &&
        mv -f "$_refresh_candidate" "$_refresh_config" || return 1
    # The full file now belongs to the new managed template, not a stale import.
    rm -f "${MODDIR}/.config/sing-box/standalone-config" \
        "${_refresh_config}.update" || return 1
    if [ "$_refresh_restored" = 1 ]; then
        info "Rebuilt the complete sing-box config from the new template with saved subscription nodes."
    else
        info "Installed the new sing-box template; saved subscriptions will be prepared at startup."
    fi
)
