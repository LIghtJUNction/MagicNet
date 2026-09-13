#!/usr/bin/env bash
# Componentization changes the ZIP bytes. Sign ALL final assets only afterwards.
set -euo pipefail
output="${1:?Usage: sign-release-assets.sh OUTPUT_DIRECTORY}"
: "${SIGNING_KEY_PEM:?Signing key is required}"
key_dir="$(mktemp -d)"
trap 'rm -rf "$key_dir"' EXIT
chmod 0700 "$key_dir"
(umask 077; printf '%s' "$SIGNING_KEY_PEM" >"$key_dir/private.pem")
unset SIGNING_KEY_PEM
openssl pkey -in "$key_dir/private.pem" -pubout -out "$key_dir/public.pem" >/dev/null
(
    cd "$output"
    # Public checksums contain only the exact release deliverables, not signatures
    # or intermediate unsigned archives. GNU sort makes the list deterministic.
    # Generate outside the asset directory before replacing the previous list.
    find . -maxdepth 1 -type f ! -name '*.sig' ! -name SHA256SUMS -printf '%f\n' |
        LC_ALL=C sort | while IFS= read -r asset; do sha256sum "$asset"; done >"$key_dir/checksums"
    mv "$key_dir/checksums" SHA256SUMS
)
for asset in "$output"/*; do
    [[ -f "$asset" && "$asset" != *.sig ]] || continue
    openssl dgst -sha256 -sign "$key_dir/private.pem" "$asset" |
        openssl base64 -A >"${asset}.sig"
    openssl base64 -d -A -in "${asset}.sig" -out "$key_dir/signature"
    openssl dgst -sha256 -verify "$key_dir/public.pem" \
        -signature "$key_dir/signature" "$asset" >/dev/null
done
