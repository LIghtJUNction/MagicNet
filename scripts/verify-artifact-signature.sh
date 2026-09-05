#!/bin/bash
set -euo pipefail

artifact="${1:?Usage: verify-artifact-signature.sh ZIP PUBLIC_KEY}"
public_key="${2:?Usage: verify-artifact-signature.sh ZIP PUBLIC_KEY}"
test -s "$artifact"
test -s "${artifact}.sig"
signature="$(mktemp)"
trap 'rm -f "$signature"' EXIT

# kam sign writes a base64-encoded SHA-256 signature beside the archive.
openssl base64 -d -A -in "${artifact}.sig" -out "$signature"
openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$artifact"
