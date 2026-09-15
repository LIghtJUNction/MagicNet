#!/bin/bash
# Complete archive changes before the base 8000 signing hook runs.
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

module_id="$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$KAM_PROJECT_ROOT/kam.toml" | head -n1)"
zip_path="${KAM_PROJECT_ROOT}/dist/${module_id}.zip"

[ -f "$zip_path" ] || exit 0
require_command zip "zip not found!"
require_command unzip "unzip not found!"

remove_zip_entries() {
    local pattern="$1"
    local message="$2"
    local entries
    entries="$(unzip -Z1 "$zip_path" | grep -E "$pattern" || true)"
    [ -n "$entries" ] || return 0

    log_info "$message"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if ! zip -q -d "$zip_path" "$entry" >/dev/null 2>&1; then
            printf 'Failed to remove archive entry: %s\n' "$entry" >&2
            exit 1
        fi
    done <<EOF
$entries
EOF
}

remove_zip_entries '(^|/)\.git($|/)' "Removing git metadata from module artifact"
# These can enter the archive through module sources and submodules. Do not
# strip dotfiles wholesale: .envrc and .kamfwrc are runtime configuration.
remove_zip_entries '(^|/)(\.github|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache)(/|$)|(^|/)(\.gitignore|\.gitattributes|\.gitmodules|\.DS_Store|Thumbs\.db)$|\.py[co]$' "Removing development metadata and caches from module artifact"
remove_zip_entries '^\.local/subscriptions\.env$' "Removing local subscription memory from module artifact"
remove_zip_entries '(^|/)(mihomo|__mihomo__)(\.sh)?($|/)' "Removing legacy mihomo helpers from module artifact"
remove_zip_entries '^bin/magicnet-ebpf$' "Removing the retired eBPF runtime binary from module artifact"
remove_zip_entries '^\.config/sing-box/\.dns-.*\.json$' "Removing routing test fixtures from module artifact"

"${KAM_PROJECT_ROOT}/scripts/package-smoke.sh" "$zip_path"
