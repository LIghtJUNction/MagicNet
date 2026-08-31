#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

. "$KAM_HOOKS_ROOT/lib/utils.sh"

require_command curl "curl not found!"
require_command git "git not found!"
require_command jq "jq not found!"

CONFIG_FILE="$KAM_MODULE_ROOT/.config/sing-box/config.json"
RULE_DIR="$KAM_MODULE_ROOT/.config/sing-box/rules"
STATE_DIR="$KAM_MODULE_ROOT/.local/state/sing-box-rules"

mkdir -p "$RULE_DIR" "$STATE_DIR"
declare -A SOURCE_REFS=()
SOURCE_REF_RESULT=""

branch_hash() {
    local repo="$1"
    local branch="$2"
    local attempt
    local output
    local ref
    local slug

    for attempt in 1 2 3; do
        output=""
        if output=$(git ls-remote "$repo" "refs/heads/$branch"); then
            ref=$(printf '%s\n' "$output" | awk 'NR == 1 { print $1; exit }')
            if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
                printf '%s\n' "$ref"
                return 0
            fi
        fi
        [ "$attempt" -eq 3 ] || sleep 1
    done

    # Some Android build hosts can reach GitHub HTTPS while git's TLS
    # transport is broken.  All repositories and branch names come from the
    # closed rule_source table above, so resolve the same ref through GitHub's
    # API and still require an immutable 40-hex object ID.
    case "$repo" in
    https://github.com/*.git)
        slug=${repo#https://github.com/}
        slug=${slug%.git}
        output=$(curl -fsSL --retry 3 --retry-delay 1 \
            "https://api.github.com/repos/${slug}/git/ref/heads/${branch}") || return 1
        ref=$(printf '%s\n' "$output" | jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))') || return 1
        log_warn "git ls-remote failed for $slug; resolved $branch through the GitHub API" >&2
        printf '%s\n' "$ref"
        return 0
        ;;
    esac

    return 1
}

state_key() {
    printf '%s\n' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

raw_url() {
    local repo="$1"
    local ref="$2"
    local path="$3"
    local slug="${repo#https://github.com/}"

    slug="${slug%.git}"
    printf 'https://raw.githubusercontent.com/%s/%s/%s\n' "$slug" "$ref" "$path"
}

rule_source() {
    local file="$1"

    case "$file" in
    metacubex-geosite-cn.srs) printf '%s|%s|%s\n' "https://github.com/MetaCubeX/meta-rules-dat.git" "sing" "geo/geosite/cn.srs" ;;
    metacubex-geoip-cn.srs) printf '%s|%s|%s\n' "https://github.com/MetaCubeX/meta-rules-dat.git" "sing" "geo/geoip/cn.srs" ;;
    metacubex-geosite-geolocation-not-cn.srs) printf '%s|%s|%s\n' "https://github.com/MetaCubeX/meta-rules-dat.git" "sing" "geo/geosite/geolocation-!cn.srs" ;;
    yuu-geosite-pcdn-cn.srs) printf '%s|%s|%s\n' "https://github.com/Yuu518/sing-box-rules.git" "rule_set" "rule_set_site/pcdn-cn.srs" ;;
    yuu-geosite-stream-global.srs) printf '%s|%s|%s\n' "https://github.com/Yuu518/sing-box-rules.git" "rule_set" "rule_set_site/stream-global.srs" ;;
    yuu-geosite-ai.srs) printf '%s|%s|%s\n' "https://github.com/Yuu518/sing-box-rules.git" "rule_set" "rule_set_site/category-ai-!cn.srs" ;;
    ddch-direct.srs) printf '%s|%s|%s\n' "https://github.com/DDCHlsq/sing-ruleset.git" "ruleset" "direct.srs" ;;
    ddch-proxy.srs) printf '%s|%s|%s\n' "https://github.com/DDCHlsq/sing-ruleset.git" "ruleset" "proxy.srs" ;;
    ddch-gfw.srs) printf '%s|%s|%s\n' "https://github.com/DDCHlsq/sing-ruleset.git" "ruleset" "gfw.srs" ;;
    hagezi-light.srs) printf '%s|%s|%s\n' "https://github.com/razaxq/dns-blocklists-sing-box.git" "rule-set" "hagezi-light.srs" ;;
    hagezi-normal.srs) printf '%s|%s|%s\n' "https://github.com/razaxq/dns-blocklists-sing-box.git" "rule-set" "hagezi-normal.srs" ;;
    hagezi-anti-piracy.srs) printf '%s|%s|%s\n' "https://github.com/razaxq/dns-blocklists-sing-box.git" "rule-set" "hagezi-anti-piracy.srs" ;;
    karing-acl4ssr-ai.srs) printf '%s|%s|%s\n' "https://github.com/KaringX/karing-ruleset.git" "sing" "ACL4SSR/AI.srs" ;;
    karing-acl4ssr-wechat.srs) printf '%s|%s|%s\n' "https://github.com/KaringX/karing-ruleset.git" "sing" "ACL4SSR/Wechat.srs" ;;
    karing-acl4ssr-proxy-lite.srs) printf '%s|%s|%s\n' "https://github.com/KaringX/karing-ruleset.git" "sing" "ACL4SSR/ProxyLite.srs" ;;
    karing-acl4ssr-proxy-gfwlist.srs) printf '%s|%s|%s\n' "https://github.com/KaringX/karing-ruleset.git" "sing" "ACL4SSR/ProxyGFWlist.srs" ;;
    karing-acl4ssr-banad.srs) printf '%s|%s|%s\n' "https://github.com/KaringX/karing-ruleset.git" "sing" "ACL4SSR/BanAD.srs" ;;
    karing-acl4ssr-china-domain.srs) printf '%s|%s|%s\n' "https://github.com/KaringX/karing-ruleset.git" "sing" "ACL4SSR/ChinaDomain.srs" ;;
    karing-acl4ssr-china-ip.srs) printf '%s|%s|%s\n' "https://github.com/KaringX/karing-ruleset.git" "sing" "ACL4SSR/ChinaIp.srs" ;;
    karing-acl4ssr-proxy-media.srs) printf '%s|%s|%s\n' "https://github.com/KaringX/karing-ruleset.git" "sing" "ACL4SSR/ProxyMedia.srs" ;;
    geoip-*.srs) printf '%s|%s|%s\n' "https://github.com/lyc8503/sing-box-rules.git" "rule-set-geoip" "$file" ;;
    geosite-*.srs) printf '%s|%s|%s\n' "https://github.com/lyc8503/sing-box-rules.git" "rule-set-geosite" "$file" ;;
    *)
        log_error "Unsupported sing-box rule-set file: $file"
        return 1
        ;;
    esac
}

source_ref() {
    local repo="$1"
    local branch="$2"
    local key
    local ref

    SOURCE_REF_RESULT=""
    key=$(state_key "${repo}|${branch}")
    if [ -n "${SOURCE_REFS[$key]:-}" ]; then
        SOURCE_REF_RESULT="${SOURCE_REFS[$key]}"
        return 0
    fi

    ref=$(branch_hash "$repo" "$branch")
    [ -n "$ref" ] || return 1
    SOURCE_REFS[$key]="$ref"
    SOURCE_REF_RESULT="$ref"
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
    local repo="$1"
    local branch="$2"
    local ref="$3"
    local source_path="$4"
    local file="$5"
    local output="$RULE_DIR/$file"
    local tmp="$output.tmp"

    log_info "$file: downloading from $branch@$ref"
    curl -fsSL --retry 3 --retry-delay 1 \
        "$(raw_url "$repo" "$ref" "$source_path")" \
        -o "$tmp" || {
        rm -f "$tmp"
        log_error "$file: download failed"
        return 1
    }

    mv "$tmp" "$output"
}

update_rule() {
    local repo="$1"
    local branch="$2"
    local ref="$3"
    local source_path="$4"
    local file="$5"
    local key
    local hash_file
    local old_ref=""
    local changed=0

    key=$(state_key "${repo}|${branch}|${source_path}|${file}")
    hash_file="$STATE_DIR/$key.hash"
    [ -f "$hash_file" ] && old_ref=$(cat "$hash_file")
    [ "$old_ref" != "$ref" ] && changed=1

    if [ "$changed" -eq 0 ] && [ -s "$RULE_DIR/$file" ]; then
        log_info "$file: up to date ($ref)"
        return 0
    fi

    download_rule "$repo" "$branch" "$ref" "$source_path" "$file" || return 1
    printf '%s\n' "$ref" >"$hash_file"
}

main() {
    local file
    local source
    local repo
    local branch
    local source_path
    local ref

    [ -f "$CONFIG_FILE" ] || {
        log_warn "sing-box config not found; rule-set update skipped"
        return 0
    }

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        source=$(rule_source "$file") || return 1
        repo=${source%%|*}
        source=${source#*|}
        branch=${source%%|*}
        source_path=${source#*|}
        source_ref "$repo" "$branch" || {
            log_error "Failed to resolve $repo $branch hash"
            return 1
        }
        ref="$SOURCE_REF_RESULT"
        update_rule "$repo" "$branch" "$ref" "$source_path" "$file" || return 1
    done < <(rule_files)

    log_success "sing-box rule sets are ready"
}

main "$@"
