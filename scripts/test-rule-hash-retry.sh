#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/pre-build/5450.update_sing_box_rules.sh"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'rule hash retry test failed: %s\n' "$*" >&2
    exit 1
}

make_fake_commands() {
    local fake_bin="$1"

    mkdir -p "$fake_bin"
    cat >"$fake_bin/git" <<'EOF'
#!/bin/bash
set -euo pipefail

count=0
if [ -f "$FAKE_GIT_COUNT_FILE" ]; then
    read -r count <"$FAKE_GIT_COUNT_FILE"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_GIT_COUNT_FILE"

[ "$#" -eq 3 ] || exit 64
[ "$1" = "ls-remote" ] || exit 64
[ "$3" = "refs/heads/ruleset" ] || exit 64

if [ "$count" -ge "$FAKE_GIT_SUCCEED_ON" ]; then
    printf '%s\t%s\n' '0123456789abcdef0123456789abcdef01234567' "$3"
    exit 0
fi

printf 'fatal: simulated TLS unexpected EOF\n' >&2
exit 128
EOF
    cat >"$fake_bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done
[ -n "$output" ] || exit 64
printf 'fake compiled rule\n' >"$output"
EOF
    cat >"$fake_bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_bin/git" "$fake_bin/curl" "$fake_bin/sleep"
}

write_config() {
    local module_root="$1"

    mkdir -p "$module_root/.config/sing-box"
    cat >"$module_root/.config/sing-box/config.json" <<'JSON'
{"route":{"rule_set":[{"type":"local","path":"rules/ddch-direct.srs"}]}}
JSON
}

write_shared_source_config() {
    local module_root="$1"

    mkdir -p "$module_root/.config/sing-box"
    cat >"$module_root/.config/sing-box/config.json" <<'JSON'
{"route":{"rule_set":[
  {"type":"local","path":"rules/ddch-direct.srs"},
  {"type":"local","path":"rules/ddch-gfw.srs"},
  {"type":"local","path":"rules/ddch-proxy.srs"}
]}}
JSON
}

run_hook() {
    local module_root="$1"
    local count_file="$2"
    local succeed_on="$3"
    local stdout_file="$4"
    local stderr_file="$5"

    env \
        PATH="$TEST_ROOT/bin:$PATH" \
        KAM_HOOKS_ROOT="$ROOT/hooks" \
        KAM_MODULE_ROOT="$module_root" \
        FAKE_GIT_COUNT_FILE="$count_file" \
        FAKE_GIT_SUCCEED_ON="$succeed_on" \
        bash "$HOOK" >"$stdout_file" 2>"$stderr_file"
}

assert_success_after_third_attempt() {
    local case_root="$TEST_ROOT/eventual-success"
    local module_root="$case_root/module"
    local count_file="$case_root/git-count"
    local state_files

    mkdir -p "$case_root"
    write_config "$module_root"
    run_hook "$module_root" "$count_file" 3 "$case_root/stdout" "$case_root/stderr" \
        || fail "hook did not recover on the third git attempt"
    [ "$(cat "$count_file")" = "3" ] || fail "eventual success did not make exactly 3 git calls"
    [ -s "$module_root/.config/sing-box/rules/ddch-direct.srs" ] \
        || fail "eventual success did not persist the rule"
    shopt -s nullglob
    state_files=("$module_root/.local/state/sing-box-rules/"*.hash)
    shopt -u nullglob
    [ "${#state_files[@]}" -eq 1 ] || fail "eventual success did not persist exactly one state file"
    [ "$(cat "${state_files[0]}")" = "0123456789abcdef0123456789abcdef01234567" ] \
        || fail "persisted state did not contain the resolved hash"
}

assert_failure_stops_after_third_attempt() {
    local case_root="$TEST_ROOT/persistent-failure"
    local module_root="$case_root/module"
    local count_file="$case_root/git-count"
    local state_files

    mkdir -p "$case_root"
    write_config "$module_root"
    if run_hook "$module_root" "$count_file" 4 "$case_root/stdout" "$case_root/stderr"; then
        fail "hook succeeded after persistent git failures"
    fi
    [ "$(cat "$count_file")" = "3" ] || fail "persistent failure did not stop after exactly 3 git calls"
    [ ! -e "$module_root/.config/sing-box/rules/ddch-direct.srs" ] \
        || fail "persistent failure generated a rule"
    shopt -s nullglob
    state_files=("$module_root/.local/state/sing-box-rules/"*.hash)
    shopt -u nullglob
    [ "${#state_files[@]}" -eq 0 ] || fail "persistent failure generated state"
}

assert_shared_source_uses_one_git_lookup() {
    local case_root="$TEST_ROOT/shared-source"
    local module_root="$case_root/module"
    local count_file="$case_root/git-count"
    local file
    local state_files

    mkdir -p "$case_root"
    write_shared_source_config "$module_root"
    run_hook "$module_root" "$count_file" 1 "$case_root/stdout" "$case_root/stderr" \
        || fail "shared-source hook run failed"
    [ "$(cat "$count_file")" = "1" ] || fail "shared source did not use exactly one git lookup"
    for file in ddch-direct.srs ddch-gfw.srs ddch-proxy.srs; do
        [ "$(cat "$module_root/.config/sing-box/rules/$file")" = "fake compiled rule" ] \
            || fail "$file was not generated with the expected content"
    done
    shopt -s nullglob
    state_files=("$module_root/.local/state/sing-box-rules/"*.hash)
    shopt -u nullglob
    [ "${#state_files[@]}" -eq 3 ] || fail "shared source did not generate exactly three state files"
    for file in "${state_files[@]}"; do
        [ "$(cat "$file")" = "0123456789abcdef0123456789abcdef01234567" ] \
            || fail "$file did not contain the shared resolved hash"
    done
}

make_fake_commands "$TEST_ROOT/bin"
assert_success_after_third_attempt
assert_failure_stops_after_third_attempt
assert_shared_source_uses_one_git_lookup
printf 'rule hash retry test passed\n'
