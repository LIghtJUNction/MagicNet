#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'release integrity test failed: %s\n' "$*" >&2
    exit 1
}

assert_failure() {
    if "$@"; then
        fail "unexpected success: $*"
    fi
}

make_fake_download_commands() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat >"$bin_dir/curl" <<'SH'
#!/bin/sh
set -eu

output_path=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output_path="$2"
            shift 2
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        *) shift ;;
    esac
done
[ -n "$output_path" ] || exit 64
[ -n "$url" ] || exit 64
[ ! -e "$output_path" ] || {
    printf 'curl invoked with a stale output asset\n' >&2
    exit 65
}

case "$url" in
    https://api.github.com/repos/*/releases/tags/*)
        [ -n "${FAKE_API_METADATA_ATTEMPT_FILE:-}" ] || exit 64
        attempt=0
        if [ -f "$FAKE_API_METADATA_ATTEMPT_FILE" ]; then
            attempt=$(cat "$FAKE_API_METADATA_ATTEMPT_FILE")
        fi
        attempt=$((attempt + 1))
        printf '%s\n' "$attempt" >"$FAKE_API_METADATA_ATTEMPT_FILE"
        if [ "${FAKE_API_METADATA_SUCCEED:-0}" = 1 ]; then
            cat >"$output_path" <<'JSON'
{
  "assets": [
    {
      "url": "https://api.github.com/repos/example/release/releases/assets/123",
      "name": "asset.tar.gz"
    }
  ]
}
JSON
            exit 0
        fi
        printf 'partial metadata\n' >"$output_path"
        exit 56
        ;;
    https://api.github.com/repos/*/releases/assets/*)
        [ -n "${FAKE_API_ASSET_ATTEMPT_FILE:-}" ] || exit 64
        attempt=0
        if [ -f "$FAKE_API_ASSET_ATTEMPT_FILE" ]; then
            attempt=$(cat "$FAKE_API_ASSET_ATTEMPT_FILE")
        fi
        attempt=$((attempt + 1))
        printf '%s\n' "$attempt" >"$FAKE_API_ASSET_ATTEMPT_FILE"
        printf 'partial asset\n' >"$output_path"
        if [ "${FAKE_API_ASSET_SUCCEED:-0}" = 1 ]; then
            printf 'complete asset\n' >"$output_path"
            exit 0
        fi
        exit 56
        ;;
esac

attempt=0
if [ -f "$FAKE_CURL_ATTEMPT_FILE" ]; then
    attempt=$(cat "$FAKE_CURL_ATTEMPT_FILE")
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$FAKE_CURL_ATTEMPT_FILE"

if [ "$attempt" -ge "$FAKE_CURL_SUCCEED_ON" ]; then
    printf 'complete asset\n' >"$output_path"
    exit 0
fi

printf 'partial asset\n' >"$output_path"
printf 'curl: (56) TLS unexpected EOF\n' >&2
exit 56
SH
    cat >"$bin_dir/gh" <<'SH'
#!/bin/sh
set -eu

output_dir=""
asset=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)
            output_dir="$2"
            shift 2
            ;;
        --pattern)
            asset="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done
[ -n "$output_dir" ] || exit 64
[ -n "$asset" ] || exit 64
[ -n "${FAKE_GH_ATTEMPT_FILE:-}" ] || exit 64

attempt=0
if [ -f "$FAKE_GH_ATTEMPT_FILE" ]; then
    attempt=$(cat "$FAKE_GH_ATTEMPT_FILE")
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$FAKE_GH_ATTEMPT_FILE"

output_path="$output_dir/$asset"
printf 'partial asset\n' >"$output_path"
if [ "${FAKE_GH_SUCCEED:-0}" = 1 ]; then
    printf 'complete asset\n' >"$output_path"
    exit 0
fi
exit 1
SH
    cat >"$bin_dir/sleep" <<'SH'
#!/bin/sh
set -eu

count=0
if [ -f "$FAKE_SLEEP_COUNT_FILE" ]; then
    count=$(cat "$FAKE_SLEEP_COUNT_FILE")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_SLEEP_COUNT_FILE"
exit 0
SH
    chmod +x "$bin_dir/curl" "$bin_dir/gh" "$bin_dir/sleep"
}

assert_download_retries() {
    local case_dir="$1"
    local succeed_on="$2"
    local output_dir="$case_dir/download"
    local output_path="$output_dir/asset.tar.gz"
    local attempt_file="$case_dir/attempts"
    local api_metadata_attempt_file="$case_dir/api-metadata-attempts"
    local api_asset_attempt_file="$case_dir/api-asset-attempts"
    local gh_attempt_file="$case_dir/gh-attempts"
    local sleep_count_file="$case_dir/sleeps"
    local stdout_file="$case_dir/stdout"
    local fake_bin="$TEST_ROOT/fake-download-bin"

    mkdir -p "$case_dir"
    if PATH="$fake_bin:$PATH" \
        GH_TOKEN=test-token \
        FAKE_CURL_ATTEMPT_FILE="$attempt_file" \
        FAKE_SLEEP_COUNT_FILE="$sleep_count_file" \
        FAKE_CURL_SUCCEED_ON="$succeed_on" \
        FAKE_API_METADATA_ATTEMPT_FILE="$api_metadata_attempt_file" \
        FAKE_API_ASSET_ATTEMPT_FILE="$api_asset_attempt_file" \
        FAKE_API_METADATA_SUCCEED=0 \
        FAKE_API_ASSET_SUCCEED=0 \
        FAKE_GH_ATTEMPT_FILE="$gh_attempt_file" \
        FAKE_GH_SUCCEED=0 \
        hook_download_locked_asset example/release v1.0.0 asset.tar.gz "$output_dir" >"$stdout_file" 2>/dev/null; then
        [ "$succeed_on" -le 3 ] || fail "download unexpectedly succeeded after persistent failures"
        [ "$(cat "$stdout_file")" = "$output_path" ] || fail "download returned the wrong output path"
        [ "$(cat "$output_path")" = "complete asset" ] || fail "download did not replace partial content"
        [ ! -e "$api_metadata_attempt_file" ] || fail "REST fallback ran before direct retries succeeded"
        [ ! -e "$gh_attempt_file" ] || fail "authenticated fallback ran before direct retries succeeded"
    else
        [ "$succeed_on" -gt 3 ] || fail "download unexpectedly failed before retry ceiling"
        [ ! -e "$output_path" ] || fail "persistent download failure left a partial asset"
        [ ! -s "$stdout_file" ] || fail "failed download returned an output path"
        [ "$(cat "$api_metadata_attempt_file")" = 1 ] || fail "persistent failure did not try REST fallback exactly once"
        [ ! -e "$api_asset_attempt_file" ] || fail "REST asset download ran after metadata lookup failed"
        [ "$(cat "$gh_attempt_file")" = 1 ] || fail "persistent failure did not try authenticated fallback exactly once"
    fi
    [ "$(cat "$attempt_file")" = 3 ] || fail "download did not stop after exactly three attempts"
    [ "$(cat "$sleep_count_file")" = 2 ] || fail "download did not wait only between attempts"
}

assert_public_api_download_fallback() {
    local case_dir="$1"
    local output_dir="$case_dir/download"
    local output_path="$output_dir/asset.tar.gz"
    local curl_attempt_file="$case_dir/curl-attempts"
    local api_metadata_attempt_file="$case_dir/api-metadata-attempts"
    local api_asset_attempt_file="$case_dir/api-asset-attempts"
    local gh_attempt_file="$case_dir/gh-attempts"
    local sleep_count_file="$case_dir/sleeps"
    local stdout_file="$case_dir/stdout"
    local fake_bin="$TEST_ROOT/fake-download-bin"

    mkdir -p "$case_dir"
    PATH="$fake_bin:$PATH" \
        GH_TOKEN=test-token \
        FAKE_CURL_ATTEMPT_FILE="$curl_attempt_file" \
        FAKE_SLEEP_COUNT_FILE="$sleep_count_file" \
        FAKE_CURL_SUCCEED_ON=4 \
        FAKE_API_METADATA_ATTEMPT_FILE="$api_metadata_attempt_file" \
        FAKE_API_ASSET_ATTEMPT_FILE="$api_asset_attempt_file" \
        FAKE_API_METADATA_SUCCEED=1 \
        FAKE_API_ASSET_SUCCEED=1 \
        FAKE_GH_ATTEMPT_FILE="$gh_attempt_file" \
        FAKE_GH_SUCCEED=0 \
        hook_download_locked_asset example/release v1.0.0 asset.tar.gz "$output_dir" >"$stdout_file" 2>/dev/null ||
        fail "public GitHub REST fallback did not recover the download"

    [ "$(cat "$curl_attempt_file")" = 3 ] || fail "REST fallback did not wait for all direct retries"
    [ "$(cat "$sleep_count_file")" = 2 ] || fail "REST fallback changed direct retry backoff semantics"
    [ "$(cat "$api_metadata_attempt_file")" = 1 ] || fail "REST fallback did not resolve release metadata exactly once"
    [ "$(cat "$api_asset_attempt_file")" = 1 ] || fail "REST fallback did not download the resolved asset exactly once"
    [ ! -e "$gh_attempt_file" ] || fail "authenticated fallback ran after REST fallback succeeded"
    [ "$(cat "$stdout_file")" = "$output_path" ] || fail "REST fallback returned the wrong output path"
    [ "$(cat "$output_path")" = "complete asset" ] || fail "REST fallback did not replace the failed partial asset"
}

assert_authenticated_download_fallback() {
    local case_dir="$1"
    local output_dir="$case_dir/download"
    local output_path="$output_dir/asset.tar.gz"
    local curl_attempt_file="$case_dir/curl-attempts"
    local api_metadata_attempt_file="$case_dir/api-metadata-attempts"
    local api_asset_attempt_file="$case_dir/api-asset-attempts"
    local gh_attempt_file="$case_dir/gh-attempts"
    local sleep_count_file="$case_dir/sleeps"
    local stdout_file="$case_dir/stdout"
    local fake_bin="$TEST_ROOT/fake-download-bin"

    mkdir -p "$case_dir"
    PATH="$fake_bin:$PATH" \
        GH_TOKEN=test-token \
        FAKE_CURL_ATTEMPT_FILE="$curl_attempt_file" \
        FAKE_SLEEP_COUNT_FILE="$sleep_count_file" \
        FAKE_CURL_SUCCEED_ON=4 \
        FAKE_API_METADATA_ATTEMPT_FILE="$api_metadata_attempt_file" \
        FAKE_API_ASSET_ATTEMPT_FILE="$api_asset_attempt_file" \
        FAKE_API_METADATA_SUCCEED=0 \
        FAKE_API_ASSET_SUCCEED=0 \
        FAKE_GH_ATTEMPT_FILE="$gh_attempt_file" \
        FAKE_GH_SUCCEED=1 \
        hook_download_locked_asset example/release v1.0.0 asset.tar.gz "$output_dir" >"$stdout_file" 2>/dev/null ||
        fail "authenticated GitHub fallback did not recover the download"

    [ "$(cat "$curl_attempt_file")" = 3 ] || fail "authenticated fallback did not wait for all direct retries"
    [ "$(cat "$sleep_count_file")" = 2 ] || fail "authenticated fallback changed direct retry backoff semantics"
    [ "$(cat "$api_metadata_attempt_file")" = 1 ] || fail "authenticated fallback did not wait for the REST fallback"
    [ ! -e "$api_asset_attempt_file" ] || fail "REST asset download ran after metadata lookup failed"
    [ "$(cat "$gh_attempt_file")" = 1 ] || fail "authenticated fallback did not run exactly once"
    [ "$(cat "$stdout_file")" = "$output_path" ] || fail "authenticated fallback returned the wrong output path"
    [ "$(cat "$output_path")" = "complete asset" ] || fail "authenticated fallback did not replace the failed partial asset"
}

# shellcheck source=hooks/lib/utils.sh
. "$ROOT/hooks/lib/utils.sh"
# shellcheck source=hooks/lib/release_locks.sh
. "$ROOT/hooks/lib/release_locks.sh"
# shellcheck source=hooks/lib/release_utils.sh
. "$ROOT/hooks/lib/release_utils.sh"

make_fake_download_commands "$TEST_ROOT/fake-download-bin"
assert_download_retries "$TEST_ROOT/download-eventual-success" 3
assert_download_retries "$TEST_ROOT/download-persistent-failure" 4
assert_public_api_download_fallback "$TEST_ROOT/download-rest-fallback"
assert_authenticated_download_fallback "$TEST_ROOT/download-gh-fallback"

assert_lock() {
    local component="$1"
    local tag="$2"
    local asset="$3"
    local sha256="$4"

    release_lock_lookup "$component" || fail "missing $component lock"
    release_lock_is_valid || fail "invalid $component lock"
    [ "$RELEASE_LOCK_TAG" = "$tag" ] || fail "wrong $component tag"
    [ "$RELEASE_LOCK_ASSET" = "$asset" ] || fail "wrong $component asset"
    [ "$RELEASE_LOCK_SHA256" = "$sha256" ] || fail "wrong $component sha256"
}

assert_lock yq v4.53.3 yq_linux_arm64 578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea
assert_lock jq jq-1.8.2 jq-linux-arm64 8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309
assert_lock ecapture v2.5.2 ecapture-v2.5.2-android-arm64.tar.gz 3531f47f60a45c02662188fb151fa8bbf9c40e5c245ff293e5a50477b99df2d1
assert_lock zashboard v3.16.0 dist-no-fonts.zip 1d8c7aca69e6ddead5e4fe6e92ceda23a499105f675d053362f7c9b53a9730f9

singbox_url="$(git -C "$ROOT" config --file .gitmodules --get submodule.sing-box.url)"
singbox_branch="$(git -C "$ROOT" config --file .gitmodules --get submodule.sing-box.branch)"
[[ "$singbox_url" = "https://github.com/LIghtJUNction/sing-box.git" ]] ||
    fail "sing-box source submodule does not use the LIghtJUNction fork"
[[ "$singbox_branch" = "testing" ]] ||
    fail "sing-box source submodule does not track the testing branch"
singbox_base_version="$(tr -d '\r\n' <"$ROOT/sing-box.version")"
[[ "$singbox_base_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
    fail "sing-box base version lock is invalid"

read -r singbox_mode _ < <(
    git -C "$ROOT" ls-files --stage -- sing-box
)
[[ "$singbox_mode" = "160000" ]] || fail "sing-box source is not recorded as a gitlink"
# Remote-update builds are checked against their recorded recursive snapshot.
# Without a snapshot, the verifier still requires the original pinned gitlinks.
bash "$ROOT/scripts/verify-submodule-revisions.sh" ||
    fail "submodule revision integrity failed"
[[ -x "$ROOT/scripts/build-sing-box.sh" ]] || fail "sing-box source build helper is not executable"
singbox_default_tags="$(tr -d '\r\n' <"$ROOT/sing-box/release/DEFAULT_BUILD_TAGS_OTHERS")"
[[ ",$singbox_default_tags," == *,with_ebpf,* ]] ||
    fail "MagicNet release builds must enable the eBPF inbound"
[[ ! -e "$ROOT/src/MagicNet/bin/magicnet-ebpf" ]] ||
    fail "MagicNet release source still contains the removed standalone eBPF binary"
grep -Fq "\"\$BUILD_SCRIPT\" android arm64" "$ROOT/hooks/pre-build/5100.update_sing_box.sh" ||
    fail "module build hook does not compile the fork for Android arm64"
for file in \
    hooks/pre-build/5100.update_sing_box.sh \
    hooks/lib/release_locks.sh \
    scripts/kam-test.sh \
    .github/workflows/exec.yml; do
    if grep -Fq 'SagerNet/sing-box' "$ROOT/$file"; then
        fail "$file still downloads an upstream sing-box binary"
    fi
done

printf 'test' >"$TEST_ROOT/artifact"
hook_verify_sha256 "$TEST_ROOT/artifact" 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 ||
    fail "known artifact hash was rejected"
assert_failure hook_verify_sha256 "$TEST_ROOT/artifact" 0000000000000000000000000000000000000000000000000000000000000000
assert_failure hook_validate_archive_member_path ../outside
assert_failure hook_validate_archive_member_path '..\\outside'

mkdir -p "$TEST_ROOT/archive"
printf 'safe\n' >"$TEST_ROOT/archive/file"
tar -czf "$TEST_ROOT/safe.tar.gz" -C "$TEST_ROOT/archive" file
hook_preflight_archive "$TEST_ROOT/safe.tar.gz" || fail "safe tar archive was rejected"
mv "$TEST_ROOT/safe.tar.gz" "$TEST_ROOT/safe-tar.archive"
hook_preflight_archive "$TEST_ROOT/safe-tar.archive" || fail "safe tar cache archive was rejected"
hook_extract_archive "$TEST_ROOT/safe-tar.archive" "$TEST_ROOT/extract-tar" || fail "safe tar cache extraction failed"
cmp "$TEST_ROOT/archive/file" "$TEST_ROOT/extract-tar/file" || fail "safe tar cache extraction was altered"

ln -s file "$TEST_ROOT/archive/link"
tar -czf "$TEST_ROOT/link.tar.gz" -C "$TEST_ROOT/archive" link
assert_failure hook_preflight_archive "$TEST_ROOT/link.tar.gz"

(
    cd "$TEST_ROOT/archive"
    zip -q "$TEST_ROOT/safe.zip" file
)
hook_preflight_archive "$TEST_ROOT/safe.zip" || fail "safe zip archive was rejected"
mv "$TEST_ROOT/safe.zip" "$TEST_ROOT/safe-zip.archive"
hook_preflight_archive "$TEST_ROOT/safe-zip.archive" || fail "safe zip cache archive was rejected"
hook_extract_archive "$TEST_ROOT/safe-zip.archive" "$TEST_ROOT/extract-zip" || fail "safe zip cache extraction failed"
cmp "$TEST_ROOT/archive/file" "$TEST_ROOT/extract-zip/file" || fail "safe zip cache extraction was altered"
(
    cd "$TEST_ROOT/archive"
    zip -y -q "$TEST_ROOT/link.zip" link
)
assert_failure hook_preflight_archive "$TEST_ROOT/link.zip"

printf 'not an archive\n' >"$TEST_ROOT/invalid.archive"
assert_failure hook_preflight_archive "$TEST_ROOT/invalid.archive"

bash "$ROOT/scripts/test-artifact-signature.sh"
printf 'release integrity test passed\n'
