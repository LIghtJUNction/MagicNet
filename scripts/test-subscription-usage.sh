#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MODDIR="$tmp/module"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/common.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/fetch.sh"
. "$ROOT/src/MagicNet/lib/magicnet/singbox_subscribe/update.sh"
warn() { :; }
error() { :; }
mkdir -p "$MODDIR/.config/sing-box" "$MODDIR/.state/sing-box/subscription-work/sources" "$tmp/bin"

parse() { printf '%b' "$1" | magicnet_singbox_parse_subscription_usage; }
assert_private_fields_absent() {
  if grep -Eq 'SECRET|token|https://' "$1"; then
    printf '%s\n' 'private response fields leaked into usage output' >&2
    exit 1
  fi
}
parse 'HTTP/2 200\r\nSuBsCrIpTiOn-UsErInFo: upload=10; download=20; total=100; expire=1900000000\r\nSet-Cookie: SECRET\r\n\r\n' >"$tmp/usage.json"
jq -e '.state == "fresh" and .upload_bytes == 10 and .download_bytes == 20 and .total_bytes == 100 and .expire_epoch == 1900000000 and .updated_epoch > 0' "$tmp/usage.json" >/dev/null
assert_private_fields_absent "$tmp/usage.json"
parse 'HTTP/1.1 200 OK\r\nSubscription-Userinfo: upload=0; download=0; total=0; expire=0\r\n\r\n' |
  jq -e '.upload_bytes == 0 and .download_bytes == 0 and .total_bytes == 0 and .expire_epoch == null' >/dev/null
parse 'HTTP/2 200\r\nSubscription-Userinfo: upload=-1; download=NaN; total=9007199254740992; expire=1e9\r\n\r\n' |
  jq -e '.upload_bytes == null and .download_bytes == null and .total_bytes == null and .expire_epoch == null' >/dev/null
parse 'HTTP/2 200\r\nSubscription-Userinfo: upload=10; upload=20; download=30\r\n\r\n' |
  jq -e '.upload_bytes == null and .download_bytes == 30 and .total_bytes == null' >/dev/null
# Interim responses and redirect headers must never supply the final quota.
parse 'HTTP/1.1 103 Early Hints\r\nSubscription-Userinfo: total=999\r\n\r\nHTTP/2 200\r\n\r\n' |
  jq -e '.total_bytes == null' >/dev/null
parse 'HTTP/2 302\r\nSubscription-Userinfo: total=999\r\n\r\n' |
  jq -e '.total_bytes == null' >/dev/null
parse 'HTTP/2 200\r\nSubscription-Userinfo: total=999' |
  jq -e '.total_bytes == null' >/dev/null
{
  printf 'HTTP/2 200\r\nSubscription-Userinfo: total=999\r\nX-Padding: '
  head -c 65536 /dev/zero | tr '\0' x
  printf '\r\n\r\n'
} | magicnet_singbox_parse_subscription_usage | jq -e '.total_bytes == null' >/dev/null

url='https://alpha.example.invalid/sub?token=SECRET'
other='https://beta.example.invalid/sub?token=OTHER_SECRET'
fingerprint=$(magicnet_singbox_subscription_fingerprint "$url")
source="$MODDIR/.state/sing-box/subscription-work/sources/$fingerprint.yaml"
printf '%s\n' old-source >"$tmp/cache.yaml"
cp "$tmp/usage.json" "$tmp/cache.yaml.usage.json"
printf '%s\n' "$fingerprint" >"$tmp/cache.yaml.identity"
magicnet_singbox_use_cached_subscription "$source" "$tmp/cache.yaml" "$tmp/cache.yaml.identity" "$fingerprint"
jq -e --slurpfile original "$tmp/usage.json" '.state == "cached" and .updated_epoch == $original[0].updated_epoch and .total_bytes == 100' "$source.usage.json" >/dev/null
if magicnet_singbox_use_cached_subscription "$tmp/wrong.yaml" "$tmp/cache.yaml" "$tmp/cache.yaml.identity" wrong-identity; then
  printf '%s\n' 'wrong-identity usage cache was accepted' >&2; exit 1
fi
test ! -e "$tmp/wrong.yaml.usage.json"

# Changing order retains source identity; absent metadata stays unknown.
printf '%s\n' "$other" "$url" >"$MODDIR/.config/sing-box/subscription.url"
magicnet_singbox_source_usage_report >"$tmp/status"
sed -n 's/^source_usage_json=//p' "$tmp/status" | jq -e --arg id "$fingerprint" '
  length == 2 and .[0].hostname == "beta.example.invalid" and .[0].state == "unknown" and .[0].total_bytes == null and
  .[1].index == 2 and .[1].id == $id and .[1].hostname == "alpha.example.invalid" and .[1].state == "cached" and .[1].total_bytes == 100' >/dev/null
assert_private_fields_absent "$tmp/status"
# Fresh metadata from an uncommitted generation remains hidden.
mkdir -p "$MODDIR/.state/sing-box/subscription-transaction"
magicnet_singbox_source_usage_report | sed -n 's/^source_usage_json=//p' |
  jq -e 'all(.[]; .state == "unknown" and .total_bytes == null)' >/dev/null
rmdir "$MODDIR/.state/sing-box/subscription-transaction"
# A failed new attempt preserves the timestamp but reports old data as cached.
cp "$tmp/usage.json" "$source.usage.json"
printf 'result=failed\n' >"$MODDIR/.state/sing-box/subscription-status"
magicnet_singbox_source_usage_report | sed -n 's/^source_usage_json=//p' |
  jq -e '.[1].state == "cached" and .[1].total_bytes == 100' >/dev/null
printf '%s\n' '{"state":"fresh","total_bytes":-1,"upload_bytes":"10","cookie":"SECRET"}' >"$source.usage.json"
magicnet_singbox_source_usage_report >"$tmp/status"
sed -n 's/^source_usage_json=//p' "$tmp/status" | jq -e '.[1].total_bytes == null and .[1].upload_bytes == null' >/dev/null
assert_private_fields_absent "$tmp/status"

# Body/identity and optional metadata can never cross download generations.
new_source="$tmp/new-cache-source.yaml"
persisted="$tmp/persisted.yaml"
printf '%s\n' new-body >"$new_source"
printf '%s\n' '{"state":"fresh","total_bytes":200,"updated_epoch":888}' >"$new_source.usage.json"
for fault in body-copy body-publish identity-publish usage-copy usage-publish; do
  printf '%s\n' old-body >"$persisted"
  printf '%s\n' "$fingerprint" >"$persisted.identity"
  cp "$tmp/usage.json" "$persisted.usage.json"
  if (
    cp() {
      case "$fault:$2" in
        "body-copy:$new_source"|"usage-copy:$new_source.usage.json") return 1 ;;
      esac
      command cp "$@"
    }
    mv() {
      case "$fault:$3" in
        "body-publish:$persisted"|"identity-publish:$persisted.identity"|"usage-publish:$persisted.usage.json") return 1 ;;
      esac
      # At every publish boundary (including an interruption here), old quota
      # has already been withdrawn and new quota has not yet been published.
      test ! -e "$persisted.usage.json" || exit 2
      command mv "$@"
    }
    magicnet_singbox_persist_subscription_cache "$new_source" "$persisted" "$persisted.identity" "$fingerprint"
  ); then
    printf 'cache persistence unexpectedly succeeded at %s\n' "$fault" >&2; exit 1
  fi
  test ! -e "$persisted.usage.json"
  case "$fault" in
    body-copy|body-publish) test "$(cat "$persisted")" = old-body ;;
    *) test "$(cat "$persisted")" = new-body ;;
  esac
done
# Failing to withdraw old usage must prevent all body replacements.
printf '%s\n' old-body >"$persisted"
cp "$tmp/usage.json" "$persisted.usage.json"
if (
  rm() { test "$2" != "$persisted.usage.json" || return 1; command rm "$@"; }
  magicnet_singbox_persist_subscription_cache "$new_source" "$persisted" "$persisted.identity" "$fingerprint"
); then
  printf '%s\n' 'cache changed despite failing to withdraw old metadata' >&2; exit 1
fi
test "$(cat "$persisted")" = old-body
magicnet_singbox_persist_subscription_cache "$new_source" "$persisted" "$persisted.identity" "$fingerprint"
test "$(cat "$persisted")" = new-body
jq -e '.total_bytes == 200 and .updated_epoch == 888' "$persisted.usage.json" >/dev/null

# Cache pruning must never turn incomplete/read-failed keep sets into deletes.
prune_dir=$(magicnet_singbox_subscription_cache_dir)
mkdir -p "$prune_dir"
prune_cache="$prune_dir/$fingerprint.yaml"
prune_map="$tmp/prune-map"
printf '%s|%s|%s|%s\n' "$fingerprint.yaml" "$prune_cache" "$prune_cache.identity" "$fingerprint" >"$prune_map"
for suffix in '' .identity .usage.json; do printf retained >"$prune_cache$suffix"; done
for fault in missing-map map-read keep-write keep-read; do
  if (
    awk() {
      case "$fault" in
        map-read) return 2 ;;
        keep-write) command awk "$@" >/dev/full ;;
        *) command awk "$@" ;;
      esac
    }
    grep() {
      if [ "$fault" = keep-read ] && [ "${1:-}" = -F ]; then return 2; fi
      command grep "$@"
    }
    test_map="$prune_map"
    [ "$fault" != missing-map ] || test_map="$tmp/missing-map"
    magicnet_singbox_prune_subscription_cache "$test_map"
  ) 2>/dev/null; then
    printf 'cache pruning unexpectedly succeeded at %s\n' "$fault" >&2; exit 1
  fi
  for suffix in '' .identity .usage.json; do test "$(cat "$prune_cache$suffix")" = retained; done
  test -z "$(find "$prune_dir" -name '.active-fingerprints.*' -print -quit)"
done
# Valid removals still delete stale bodies, sidecars and orphaned metadata.
removed_id=$(magicnet_singbox_subscription_fingerprint "$other")
removed_cache="$prune_dir/$removed_id.yaml"
for suffix in '' .identity .usage.json; do printf stale >"$removed_cache$suffix"; done
printf orphan >"$prune_dir/orphan.yaml.usage.json"
magicnet_singbox_prune_subscription_cache "$prune_map"
for suffix in '' .identity .usage.json; do
  test -f "$prune_cache$suffix"
  test ! -e "$removed_cache$suffix"
done
test ! -e "$prune_dir/orphan.yaml.usage.json"
# A deliberately empty, successfully read map (local source mode) clears caches.
: >"$prune_map"
magicnet_singbox_prune_subscription_cache "$prune_map"
for suffix in '' .identity .usage.json; do test ! -e "$prune_cache$suffix"; done

# IPv6 host labels remain URL-safe; orphaned metadata never supplies usage.
printf '%s\n' 'https://[2606:4700:4700::1111]/sub?token=SECRET' >"$MODDIR/.config/sing-box/subscription.url"
magicnet_singbox_source_usage_report | sed -n 's/^source_usage_json=//p' |
  jq -e '.[0].hostname == "[2606:4700:4700::1111]"' >/dev/null
printf '%s\n' "$url" >"$MODDIR/.config/sing-box/subscription.url"
rm -f "$source"
magicnet_singbox_source_usage_report | sed -n 's/^source_usage_json=//p' |
  jq -e '.[0].state == "unknown" and .[0].total_bytes == null' >/dev/null

# Exercise the actual curl/body/header FIFO path with a deterministic downloader.
cat >"$tmp/bin/curl" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in --dump-header) shift; headers=$1 ;; esac
  shift
done
[ "${USAGE_TEST_FAIL:-0}" = 1 ] && exit 1
printf 'HTTP/2 200\r\nSubscription-Userinfo: upload=10; download=20; total=100\r\nSet-Cookie: SECRET\r\n\r\n' >"$headers"
printf 'node-data\r\n'
SH
chmod +x "$tmp/bin/curl"
magicnet_singbox_subscription_resolve_public() { printf 'alpha.example.invalid|443|1.1.1.1\n'; }
PATH="$tmp/bin:$PATH" magicnet_singbox_fetch_one_subscription "$url" "$tmp/fetched.yaml" '' '' '' '#1'
test "$(cat "$tmp/fetched.yaml")" = node-data
jq -e '.total_bytes == 100 and .state == "fresh"' "$tmp/fetched.yaml.usage.json" >/dev/null
test ! -e "$tmp/fetched.yaml.download.headers"
assert_private_fields_absent "$tmp/fetched.yaml.usage.json"
# Failing before opening the header FIFO must terminate, with no stale header file.
if USAGE_TEST_FAIL=1 PATH="$tmp/bin:$PATH" magicnet_singbox_try_fetch_subscription "$url" "$tmp/failed" 2 3; then
  printf '%s\n' 'failed download was accepted' >&2; exit 1
fi
test ! -e "$tmp/failed.usage.json"
test ! -e "$tmp/failed.headers"
printf '%s\n' 'subscription usage tests passed'
