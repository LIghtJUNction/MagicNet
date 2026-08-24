#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
phase_file="$repo_root/src/MagicNet/lib/magicnet/phases.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-mcp-phase.XXXXXX")"

cleanup() {
    rm -rf "$fixture"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

module_dir="$fixture/module"
mcp_conf="$module_dir/.config/magicnet/mcp.conf"
call_log="$fixture/cli.calls"
marker="$fixture/should-not-exist"
mkdir -p "$(dirname "$mcp_conf")"

cat > "$module_dir/cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MCP_PHASE_CALL_LOG:?}"
EOF
chmod +x "$module_dir/cli"

set_i18n() { :; }
magicnet_warn() { :; }
i18n() { printf '%s\n' "$1"; }
t() { cat; }

MODDIR="$module_dir"
export MODDIR
MCP_PHASE_CALL_LOG="$call_log"
export MCP_PHASE_CALL_LOG

# phases.sh registers the boot function and its i18n labels at source time.
# The helpers above make that registration self-contained for this regression.
# shellcheck source=../src/MagicNet/lib/magicnet/phases.sh
. "$phase_file"

reset_case() {
    : > "$call_log"
    rm -f "$marker"
}

write_valid_conf() {
    printf '%s\n' \
        "MAGICNET_MCP_ENABLED=$1" \
        'MAGICNET_MCP_BIND=127.0.0.1' \
        'MAGICNET_MCP_PORT=8766' \
        'MAGICNET_MCP_SECRET=safe-secret' > "$mcp_conf"
}

write_valid_conf_without_secret() {
    printf '%s\n' \
        "MAGICNET_MCP_ENABLED=$1" \
        'MAGICNET_MCP_BIND=127.0.0.1' \
        'MAGICNET_MCP_PORT=8766' > "$mcp_conf"
}

write_valid_ipv6_conf() {
    printf '%s\n' \
        'MAGICNET_MCP_ENABLED=1' \
        'MAGICNET_MCP_BIND=::1' \
        'MAGICNET_MCP_PORT=8766' \
        'MAGICNET_MCP_SECRET=safe-secret' > "$mcp_conf"
}

assert_delegated_once() {
    grep -qx 'mcp start-if-enabled' "$call_log" || fail "expected one typed MCP startup delegation"
    [ "$(wc -l < "$call_log")" -eq 1 ] || fail "expected exactly one MCP startup delegation"
}

assert_marker_absent() {
    [ ! -e "$marker" ] || fail "mcp.conf content was executed"
}

reset_case
write_valid_conf 1
magicnet_mcp_start_if_enabled
assert_delegated_once

reset_case
write_valid_conf_without_secret 1
magicnet_mcp_start_if_enabled
assert_delegated_once

reset_case
write_valid_ipv6_conf
magicnet_mcp_start_if_enabled
assert_delegated_once

# Shell owns no configuration parser. Every payload is passed as inert data to
# the Rust CLI, whose schema tests reject unknown, injected, or duplicate keys.
reset_case
write_valid_conf 1
printf '%s\n' "MCP_PHASE_TEST=\$(touch \"$marker\")" >> "$mcp_conf"
magicnet_mcp_start_if_enabled
assert_delegated_once
assert_marker_absent

reset_case
write_valid_conf 1
printf '%s\n' "MAGICNET_MCP_ENABLED=1\$(touch \"$marker\")" >> "$mcp_conf"
magicnet_mcp_start_if_enabled
assert_delegated_once
assert_marker_absent

reset_case
write_valid_conf 1
printf '%s\n' 'MAGICNET_MCP_PORT=8766' >> "$mcp_conf"
magicnet_mcp_start_if_enabled
assert_delegated_once

reset_case
write_valid_conf 1
printf '%s\n' '# comment lines are not canonical configuration' >> "$mcp_conf"
magicnet_mcp_start_if_enabled
assert_delegated_once

reset_case
write_valid_conf 0
magicnet_mcp_start_if_enabled
assert_delegated_once

printf 'MCP phase configuration test passed\n'
