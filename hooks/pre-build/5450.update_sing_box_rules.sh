#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

. "$KAM_HOOKS_ROOT/lib/utils.sh"

require_command curl "curl not found!"
require_command jq "jq not found!"

REPO_URL="https://github.com/lyc8503/sing-box-rules.git"
RAW_URL="https://raw.githubusercontent.com/lyc8503/sing-box-rules"
CONFIG_FILE="$KAM_MODULE_ROOT/.config/sing-box/config.json"
RULE_DIR="$KAM_MODULE_ROOT/.config/sing-box/rules"
STATE_DIR="$KAM_MODULE_ROOT/.local/state/sing-box-rules"

mkdir -p "$RULE_DIR" "$STATE_DIR"

branch_hash() {
    local branch="$1"

    git ls-remote "$REPO_URL" "refs/heads/$branch" | awk '{print $1}'
}

rule_branch() {
    case "$1" in
        geoip-*.srs) printf '%s\n' "rule-set-geoip" ;;
        geosite-*.srs) printf '%s\n' "rule-set-geosite" ;;
        *)
            log_error "Unsupported sing-box rule-set file: $1"
            return 1
            ;;
    esac
}

rule_files() {
    jq -r '
      .route.rule_set[]?
      | select(.type == "local")
      | .path
      | select(startswith("rules/") and endswith(".srs"))
      | sub("^rules/"; "")
    ' "$CONFIG_FILE" | sort -u
}

download_rule() {
    local branch="$1"
    local ref="$2"
    local file="$3"
    local output="$RULE_DIR/$file"
    local tmp="$output.tmp"

    log_info "$file: downloading from $branch@$ref"
    curl -fsSL --retry 3 --retry-delay 1 \
        "$RAW_URL/$ref/$file" \
        -o "$tmp" || {
        rm -f "$tmp"
        log_error "$file: download failed"
        return 1
    }

    mv "$tmp" "$output"
}

update_branch_rules() {
    local branch="$1"
    local ref="$2"
    local hash_file="$STATE_DIR/$branch.hash"
    local old_ref=""
    local file
    local missing=0
    local changed=0

    [ -f "$hash_file" ] && old_ref=$(cat "$hash_file")
    [ "$old_ref" != "$ref" ] && changed=1

    shift 2
    for file in "$@"; do
        if [ ! -s "$RULE_DIR/$file" ]; then
            missing=1
            break
        fi
    done

    if [ "$changed" -eq 0 ] && [ "$missing" -eq 0 ]; then
        log_info "$branch: up to date ($ref)"
        return 0
    fi

    for file in "$@"; do
        download_rule "$branch" "$ref" "$file" || return 1
    done
    printf '%s\n' "$ref" > "$hash_file"
}

main() {
    local geosite_ref
    local geoip_ref
    local file
    local branch
    local geosite_files=()
    local geoip_files=()

    [ -f "$CONFIG_FILE" ] || {
        log_warn "sing-box config not found; rule-set update skipped"
        return 0
    }

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        branch=$(rule_branch "$file") || return 1
        case "$branch" in
            rule-set-geosite) geosite_files+=("$file") ;;
            rule-set-geoip) geoip_files+=("$file") ;;
        esac
    done < <(rule_files)

    if [ "${#geosite_files[@]}" -gt 0 ]; then
        geosite_ref=$(branch_hash rule-set-geosite)
        [ -n "$geosite_ref" ] || {
            log_error "Failed to resolve rule-set-geosite hash"
            return 1
        }
        update_branch_rules rule-set-geosite "$geosite_ref" "${geosite_files[@]}" || return 1
    fi

    if [ "${#geoip_files[@]}" -gt 0 ]; then
        geoip_ref=$(branch_hash rule-set-geoip)
        [ -n "$geoip_ref" ] || {
            log_error "Failed to resolve rule-set-geoip hash"
            return 1
        }
        update_branch_rules rule-set-geoip "$geoip_ref" "${geoip_files[@]}" || return 1
    fi

    log_success "sing-box rule sets are ready"
}

main "$@"
