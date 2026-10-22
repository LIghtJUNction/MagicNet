#!/usr/bin/env bash
# Hash the final archives and metadata after all package transformations.
set -euo pipefail
output="${1:?Usage: checksum-release-assets.sh OUTPUT_DIRECTORY}"
checksums="$(mktemp)"
trap 'rm -f "$checksums"' EXIT
(
    cd "$output"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' |
        LC_ALL=C sort | while IFS= read -r asset; do sha256sum -- "$asset"; done >"$checksums"
    test -s "$checksums"
    mv "$checksums" SHA256SUMS
    sha256sum -c SHA256SUMS
)
