#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'release tag retry test failed: %s\n' "$*" >&2
    exit 1
}

make_fake_commands() {
    local fake_bin="$1"

    mkdir -p "$fake_bin"
    cat >"$fake_bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail

count=0
if [ -f "$FAKE_GH_COUNT_FILE" ]; then
    read -r count <"$FAKE_GH_COUNT_FILE"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_GH_COUNT_FILE"

[ "$#" -eq 8 ] || exit 64
[ "$1" = "release" ] || exit 64
[ "$2" = "view" ] || exit 64
[ "$3" = "--repo" ] || exit 64
[ "$5" = "--json" ] || exit 64
[ "$6" = "tagName" ] || exit 64
[ "$7" = "--template" ] || exit 64
[ "$8" = "{{.tagName}}" ] || exit 64

if [ "$count" -le "$FAKE_GH_EMPTY_THROUGH" ]; then
    exit 0
fi
if [ "$count" -ge "$FAKE_GH_SUCCEED_ON" ]; then
    printf '%s\n' "$FAKE_GH_TAG"
    exit 0
fi

printf 'simulated transient gh failure\n' >&2
exit 1
EOF
    cat >"$fake_bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_bin/gh" "$fake_bin/sleep"
}

# shellcheck source=hooks/lib/release_utils.sh
. "$ROOT/hooks/lib/release_utils.sh"

assert_success_after_third_attempt() {
    local count_file="$TEST_ROOT/eventual-success-count"
    local output

    export FAKE_GH_COUNT_FILE="$count_file"
    export FAKE_GH_EMPTY_THROUGH=0
    export FAKE_GH_SUCCEED_ON=3
    export FAKE_GH_TAG="v9.9.9"
    output=$(github_latest_tag "example/project") \
        || fail "tag lookup did not recover on the third attempt"
    [ "$output" = "v9.9.9" ] || fail "eventual success did not return the expected tag"
    [ "$(cat "$count_file")" = "3" ] || fail "eventual success did not make exactly 3 gh calls"
}

assert_persistent_failure_stops_after_third_attempt() {
    local count_file="$TEST_ROOT/persistent-failure-count"
    local output=""

    export FAKE_GH_COUNT_FILE="$count_file"
    export FAKE_GH_EMPTY_THROUGH=0
    export FAKE_GH_SUCCEED_ON=99
    export FAKE_GH_TAG="v9.9.9"
    if output=$(github_latest_tag "example/project"); then
        fail "persistent gh failure returned success"
    fi
    [ -z "$output" ] || fail "persistent gh failure polluted stdout"
    [ "$(cat "$count_file")" = "3" ] || fail "persistent failure did not stop after exactly 3 gh calls"
}

assert_empty_success_is_retried() {
    local count_file="$TEST_ROOT/empty-success-count"
    local output

    export FAKE_GH_COUNT_FILE="$count_file"
    export FAKE_GH_EMPTY_THROUGH=2
    export FAKE_GH_SUCCEED_ON=1
    export FAKE_GH_TAG="v8.8.8"
    output=$(github_latest_tag "example/project") \
        || fail "empty successful responses were not retried"
    [ "$output" = "v8.8.8" ] || fail "retry after empty responses returned the wrong tag"
    [ "$(cat "$count_file")" = "3" ] || fail "empty successful responses did not make exactly 3 gh calls"
}

make_fake_commands "$TEST_ROOT/bin"
export PATH="$TEST_ROOT/bin:$PATH"
assert_success_after_third_attempt
assert_persistent_failure_stops_after_third_attempt
assert_empty_success_is_retried
printf 'release tag retry test passed\n'
