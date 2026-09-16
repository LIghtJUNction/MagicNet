#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
set -euo pipefail
. "$KAM_HOOKS_ROOT/lib/utils.sh"
require_command jq
require_command sha256sum
require_command mktemp
require_command cmp

CONFIG_FILE="$KAM_MODULE_ROOT/.config/sing-box/config.json"
RULE_DIR="$KAM_MODULE_ROOT/.config/sing-box/rules"
STATE_DIR="$KAM_MODULE_ROOT/.local/state/sing-box-rules"

verify_bundled_rule() {
    local file="$1" bundle="$2" manifest="$2/manifest.json"
    local source="$bundle/$file" digest size actual
    [[ "$file" =~ ^[A-Za-z0-9_@!.-]+\.srs$ ]] || {
        log_error "Unsafe rule-set filename: $file"
        return 1
    }
    [ -f "$source" ] && [ ! -L "$source" ] || {
        log_error "Release is missing required rule: $file"
        return 1
    }
    digest=$(jq -er --arg name "${file%.srs}" '
        select(.version == 1) | .rulesets[$name].sha256_srs
        | select(type == "string" and test("^[0-9a-f]{64}$"))
    ' "$manifest") || return 1
    size=$(jq -er --arg name "${file%.srs}" '
        .rulesets[$name].srs_size | select(type == "number" and . >= 4 and . == floor)
    ' "$manifest") || return 1
    actual=$(sha256sum "$source") || return 1
    if [ "${actual%% *}" != "$digest" ] || [ "$(wc -c <"$source")" -ne "$size" ] || [ "$(head -c 3 "$source")" != SRS ]; then
        log_error "$file: invalid Release rule; previous files preserved"
        return 1
    fi
}

update_bundled_rule() (
    local file="$1" bundle="$2"
    local hash_file="$STATE_DIR/$file.hash"
    local digest staged state_tmp="" actual identity old_ref=""
    digest=$(jq -er --arg name "${file%.srs}" '.rulesets[$name].sha256_srs' "$bundle/manifest.json") || return 1
    staged=$(mktemp "$RULE_DIR/.${file}.XXXXXX") || return 1
    trap 'rm -f -- "$staged" "$state_tmp"' EXIT
    cp -- "$bundle/$file" "$staged" || return 1
    actual=$(sha256sum "$staged") || return 1
    if [ "${actual%% *}" != "$digest" ]; then
        log_error "$file: copy checksum mismatch; previous rule preserved"
        return 1
    fi
    identity="bundled:sha256:$digest"
    [ ! -f "$hash_file" ] || old_ref=$(cat "$hash_file") || return 1
    if [ "$old_ref" = "$identity" ] && cmp -s -- "$staged" "$RULE_DIR/$file"; then
        return 0
    fi
    if ! cmp -s -- "$staged" "$RULE_DIR/$file"; then
        chmod 0644 "$staged" || return 1
        mv -f -- "$staged" "$RULE_DIR/$file" || return 1
    fi
    state_tmp=$(mktemp "${hash_file}.XXXXXX") || return 1
    printf '%s\n' "$identity" >"$state_tmp" || return 1
    mv -f -- "$state_tmp" "$hash_file" || return 1
    log_success "$file: verified Release rule ($digest)"
)

main() {
    local project_root="${KAM_PROJECT_ROOT:-$(cd "$KAM_HOOKS_ROOT/.." && pwd)}"
    local bundle_dir="${MAGICNET_RULES_DIR:-$project_root/rules/dist}"
    local downloader="$project_root/rules/scripts/download_release.py"
    local files file

    [ -f "$CONFIG_FILE" ] || {
        log_warn "sing-box config not found; rule-set update skipped"
        return 0
    }
    # Capture jq status rather than losing parser errors in process substitution.
    files=$(jq -r '
        .route.rule_set[]?
        | select(.type == "local") | .path
        | select(startswith("rules/") and endswith(".srs"))
        | sub("^rules/"; "")
    ' "$CONFIG_FILE" | sort -u) || return 1
    [ -n "$files" ] || return 0
    if [ -z "${MAGICNET_RULES_DIR:-}" ]; then
        [ -f "$downloader" ] || {
            log_error "MagicNetRules submodule is missing; initialize the rules submodule"
            return 1
        }
        require_command python3
        # Resolves latest once or uses MAGICNET_RULES_TAG; no upstream fallback.
        python3 "$downloader" --output "$bundle_dir" || return 1
    fi
    [ -d "$bundle_dir" ] && [ ! -L "$bundle_dir" ] &&
        [ -f "$bundle_dir/manifest.json" ] && [ ! -L "$bundle_dir/manifest.json" ] || {
        log_error "Missing or unsafe Release bundle manifest"
        return 1
    }
    # Validate the entire selected inventory before replacing any module file.
    while IFS= read -r file; do
        verify_bundled_rule "$file" "$bundle_dir" || return 1
    done <<<"$files"
    mkdir -p "$RULE_DIR" "$STATE_DIR"
    while IFS= read -r file; do
        update_bundled_rule "$file" "$bundle_dir" || return 1
    done <<<"$files"
    log_success "sing-box rules installed from a verified MagicNetRules Release"
}

main "$@"
