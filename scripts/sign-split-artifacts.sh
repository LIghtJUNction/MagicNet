#!/usr/bin/env bash
# Match KAM's base64-encoded OpenSSL SHA-256 detached signature format.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/dist"
sha256sum ./*.zip components-manifest.json update-core.json build-submodules.txt > SHA256SUMS
if [ "${MAGICNET_SIGN_ENABLED:-0}" != 1 ]; then
  [ "${MAGICNET_SIGN_REQUIRED:-0}" != 1 ] || {
    printf 'Release signing key is required\n' >&2
    exit 1
  }
  exit 0
fi
: "${SIGNING_KEY_PEM:?Release signing key is missing}"
umask 077
key_dir="$(mktemp -d)"
trap 'rm -rf "$key_dir"' EXIT
printf '%s' "$SIGNING_KEY_PEM" > "$key_dir/private.pem"
openssl pkey -in "$key_dir/private.pem" -pubout -out "$key_dir/public.pem"
for artifact in ./*.zip components-manifest.json update-core.json SHA256SUMS; do
  openssl dgst -sha256 -sign "$key_dir/private.pem" -out "$key_dir/signature" "$artifact"
  openssl base64 -A -in "$key_dir/signature" -out "${artifact}.sig"
  bash "$ROOT/scripts/verify-artifact-signature.sh" "$artifact" "$key_dir/public.pem"
done
sha256sum -c SHA256SUMS
