#!/bin/bash
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
        zip -q -d "$zip_path" "$entry" >/dev/null 2>&1 || true
    done <<EOF
$entries
EOF
}

remove_zip_entries '(^|/)\.git($|/)' "Removing git metadata from module artifact"
remove_zip_entries '^\.local/subscriptions\.env$' "Removing local subscription memory from module artifact"
remove_zip_entries '(^|/)(mihomo|__mihomo__)(\.sh)?($|/)' "Removing legacy mihomo helpers from module artifact"

"${KAM_PROJECT_ROOT}/scripts/package-smoke.sh" "$zip_path"
