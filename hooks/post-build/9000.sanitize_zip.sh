#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

module_id="$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$KAM_PROJECT_ROOT/kam.toml" | head -n1)"
zip_path="${KAM_PROJECT_ROOT}/dist/${module_id}.zip"

[ -f "$zip_path" ] || exit 0
require_command zip "zip not found!"
require_command unzip "unzip not found!"

git_entries="$(unzip -Z1 "$zip_path" | grep -E '(^|/)\.git($|/)' || true)"
if [ -n "$git_entries" ]; then
    log_info "Removing git metadata from module artifact"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        zip -q -d "$zip_path" "$entry" >/dev/null 2>&1 || true
    done <<EOF
$git_entries
EOF
fi

local_subscription_entries="$(unzip -Z1 "$zip_path" | grep -E '^\.local/subscriptions\.env$' || true)"
if [ -n "$local_subscription_entries" ]; then
    log_info "Removing local subscription memory from module artifact"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        zip -q -d "$zip_path" "$entry" >/dev/null 2>&1 || true
    done <<EOF
$local_subscription_entries
EOF
fi

"${KAM_PROJECT_ROOT}/scripts/package-smoke.sh" "$zip_path"
