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
        zip -q -d "$zip_path" "$entry" >/dev/null 2>&1 || true
    done <<EOF
$entries
EOF
}

remove_zip_entries '(^|/)\.git($|/)' "Removing git metadata from module artifact"
remove_zip_entries '^\.local/subscriptions\.env$' "Removing local subscription memory from module artifact"
remove_zip_entries '(^|/)(mihomo|__mihomo__)(\.sh)?($|/)' "Removing legacy mihomo helpers from module artifact"
remove_zip_entries '^bin/magicnet-ebpf$' "Removing the retired eBPF runtime binary from module artifact"
remove_zip_entries '^\.config/sing-box/\.dns-.*\.json$' "Removing routing test fixtures from module artifact"

# kamfw 97168da's no-jq fallback toggles this field on every outbound,
# including URLTest groups. Keep the fallback aligned with the jq path until
# the dependency ships the selector-only behavior.
kamfw_singbox_path="lib/kamfw/__singbox__.sh"
kamfw_singbox_tmp="$(mktemp -d)"
mkdir -p "$kamfw_singbox_tmp/lib/kamfw"
unzip -p "$zip_path" "$kamfw_singbox_path" >"$kamfw_singbox_tmp/$kamfw_singbox_path"

if grep -Fq 'if (current ~ /^[[:space:]]*"interrupt_exist_connections"[[:space:]]*:/) {' \
    "$kamfw_singbox_tmp/$kamfw_singbox_path"; then
    awk '
        {
            if ($0 == "            if (current ~ /^[[:space:]]*\"interrupt_exist_connections\"[[:space:]]*:/) {") {
                print "            if (current ~ /^[[:space:]]*\"type\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/) {"
                print "                outbound_type = current"
                print "                sub(/^[^:]*:[[:space:]]*\"/, \"\", outbound_type)"
                print "                sub(/\".*$/, \"\", outbound_type)"
                print "            }"
                print "            if (outbound_type == \"selector\" && current ~ /^[[:space:]]*\"interrupt_exist_connections\"[[:space:]]*:/) {"
                next
            }
            print
        }
    ' "$kamfw_singbox_tmp/$kamfw_singbox_path" >"$kamfw_singbox_tmp/$kamfw_singbox_path.new"
    mv "$kamfw_singbox_tmp/$kamfw_singbox_path.new" "$kamfw_singbox_tmp/$kamfw_singbox_path"
    (
        cd "$kamfw_singbox_tmp" || exit 1
        zip -q -u "$zip_path" "$kamfw_singbox_path"
    )
fi

rm -rf "$kamfw_singbox_tmp"

"${KAM_PROJECT_ROOT}/scripts/package-smoke.sh" "$zip_path"
