#!/usr/bin/env bash
# Validate every workflow with a checksum-pinned actionlint release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

version=1.7.12
archive="actionlint_${version}_linux_amd64.tar.gz"
# https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_checksums.txt
archive_sha256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
release_url="https://github.com/rhysd/actionlint/releases/download/v${version}"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    printf 'Workflow validation requires the Linux x86_64 CI runner.\n' >&2
    exit 2
fi

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/magicnet-actionlint.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
# A cache changes only where the archive is stored; every use checks the pinned hash.
cache_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/magicnet-actionlint-cache"
mkdir -p "$cache_dir"
cached_archive="$cache_dir/$archive"
if [[ ! -f "$cached_archive" ]] || ! printf '%s  %s\n' "$archive_sha256" "$cached_archive" | sha256sum --check --strict --status; then
    curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
        --connect-timeout 15 --max-time 120 "$release_url/$archive" -o "$work/$archive"
    printf '%s  %s\n' "$archive_sha256" "$work/$archive" | sha256sum --check --strict
    mv "$work/$archive" "$cached_archive"
fi
printf '%s  %s\n' "$archive_sha256" "$cached_archive" | sha256sum --check --strict
# Extract only the verified executable; do not run an upstream install script.
tar -xzf "$cached_archive" -C "$work" actionlint

shopt -s nullglob
workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
if ((${#workflows[@]} == 0)); then
    printf 'No workflow YAML files found.\n' >&2
    exit 2
fi

# Existing code lint owns ShellCheck and Python lint; no Actions rules are ignored.
"$work/actionlint" -shellcheck= -pyflakes= "${workflows[@]}"
