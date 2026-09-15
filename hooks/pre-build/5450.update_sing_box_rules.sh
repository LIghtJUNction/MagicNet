#!/bin/bash
# shellcheck source=hooks/lib/utils.sh

. "$KAM_HOOKS_ROOT/lib/utils.sh"

require_commands curl git jq

CONFIG_FILE="$KAM_MODULE_ROOT/.config/sing-box/config.json"
RULE_DIR="$KAM_MODULE_ROOT/.config/sing-box/rules"
STATE_DIR="$KAM_MODULE_ROOT/.local/state/sing-box-rules"

mkdir -p "$RULE_DIR" "$STATE_DIR"
declare -A SOURCE_REFS=()
SOURCE_REF_RESULT=""

branch_hash() {
    local repo="$1" branch="$2"
    local attempt output ref slug

    for attempt in 1 2 3; do
        if output=$(git ls-remote "$repo" "refs/heads/$branch"); then
            ref=$(awk 'NR == 1 { print $1; exit }' <<<"$output")
            [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && {
                printf '%s\n' "$ref"
                return 0
            }
        fi
        [ "$attempt" -eq 3 ] || sleep 1
    done

    case "$repo" in
    https://github.com/*.git)
        slug=${repo#https://github.com/}
        slug=${slug%.git}
        output=$(curl -fsSL --retry 3 --retry-delay 1 \
            "https://api.github.com/repos/${slug}/git/ref/heads/${branch}") || return 1
        ref=$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' <<<"$output") || return 1
        log_warn "git ls-remote failed for $slug; resolved $branch through the GitHub API" >&2
        printf '%s\n' "$ref"
        return 0
        ;;
    esac
    return 1
}

state_key() {
    sed 's/[^A-Za-z0-9_.-]/_/g' <<<"$1"
}

raw_url() {
    local repo="$1" ref="$2" path="$3"
    local slug=${repo#https://github.com/}
    slug=${slug%.git}
    printf 'https://raw.githubusercontent.com/%s/%s/%s\n' "$slug" "$ref" "$path"
}

rule_source() {
    local file="$1" spec service name repo

    case "$file" in
    metacubex-service-*.srs)
        service=${file#metacubex-service-}
        name=${service%.srs}
        case "$name" in
        ''|*[!a-z0-9_@!-]*)
            log_error "Invalid service rule-set: $file"
            return 1
            ;;
        esac
        spec="MetaCubeX/meta-rules-dat|sing|geo/geosite/$service"
        ;;
    metacubex-geosite-cn.srs) spec='MetaCubeX/meta-rules-dat|sing|geo/geosite/cn.srs' ;;
    metacubex-geoip-cn.srs) spec='MetaCubeX/meta-rules-dat|sing|geo/geoip/cn.srs' ;;
    metacubex-geosite-geolocation-not-cn.srs) spec='MetaCubeX/meta-rules-dat|sing|geo/geosite/geolocation-!cn.srs' ;;
    yuu-geosite-pcdn-cn.srs) spec='Yuu518/sing-box-rules|rule_set|rule_set_site/pcdn-cn.srs' ;;
    yuu-geosite-stream-global.srs) spec='Yuu518/sing-box-rules|rule_set|rule_set_site/stream-global.srs' ;;
    yuu-geosite-ai.srs) spec='Yuu518/sing-box-rules|rule_set|rule_set_site/category-ai-!cn.srs' ;;
    ddch-direct.srs) spec='DDCHlsq/sing-ruleset|ruleset|direct.srs' ;;
    ddch-proxy.srs) spec='DDCHlsq/sing-ruleset|ruleset|proxy.srs' ;;
    ddch-gfw.srs) spec='DDCHlsq/sing-ruleset|ruleset|gfw.srs' ;;
    hagezi-light.srs) spec='razaxq/dns-blocklists-sing-box|rule-set|hagezi-light.srs' ;;
    hagezi-normal.srs) spec='razaxq/dns-blocklists-sing-box|rule-set|hagezi-normal.srs' ;;
    hagezi-anti-piracy.srs) spec='razaxq/dns-blocklists-sing-box|rule-set|hagezi-anti-piracy.srs' ;;
    karing-acl4ssr-ai.srs) spec='KaringX/karing-ruleset|sing|ACL4SSR/AI.srs' ;;
    karing-acl4ssr-wechat.srs) spec='KaringX/karing-ruleset|sing|ACL4SSR/Wechat.srs' ;;
    karing-acl4ssr-proxy-lite.srs) spec='KaringX/karing-ruleset|sing|ACL4SSR/ProxyLite.srs' ;;
    karing-acl4ssr-proxy-gfwlist.srs) spec='KaringX/karing-ruleset|sing|ACL4SSR/ProxyGFWlist.srs' ;;
    karing-acl4ssr-banad.srs) spec='KaringX/karing-ruleset|sing|ACL4SSR/BanAD.srs' ;;
    karing-acl4ssr-china-domain.srs) spec='KaringX/karing-ruleset|sing|ACL4SSR/ChinaDomain.srs' ;;
    karing-acl4ssr-china-ip.srs) spec='KaringX/karing-ruleset|sing|ACL4SSR/ChinaIp.srs' ;;
    karing-acl4ssr-proxy-media.srs) spec='KaringX/karing-ruleset|sing|ACL4SSR/ProxyMedia.srs' ;;
    geoip-*.srs) spec="lyc8503/sing-box-rules|rule-set-geoip|$file" ;;
    geosite-*.srs) spec="lyc8503/sing-box-rules|rule-set-geosite|$file" ;;
    *)
        log_error "Unsupported sing-box rule-set file: $file"
        return 1
        ;;
    esac

    repo=${spec%%|*}
    printf 'https://github.com/%s.git|%s\n' "$repo" "${spec#*|}"
}

source_ref() {
    local repo="$1" branch="$2" key ref

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
    local repo="$1" branch="$2" ref="$3" source_path="$4" file="$5"
    local output="$RULE_DIR/$file" tmp
    tmp="$output.tmp"

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
    local repo="$1" branch="$2" ref="$3" source_path="$4" file="$5"
    local key hash_file old_ref=""

    key=$(state_key "${repo}|${branch}|${source_path}|${file}")
    hash_file="$STATE_DIR/$key.hash"
    [ -f "$hash_file" ] && old_ref=$(cat "$hash_file")

    if [ "$old_ref" = "$ref" ] && [ -s "$RULE_DIR/$file" ]; then
        log_info "$file: up to date ($ref)"
        return 0
    fi

    download_rule "$repo" "$branch" "$ref" "$source_path" "$file" || return 1
    printf '%s\n' "$ref" >"$hash_file"
}

main() {
    local file source repo branch source_path ref

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
