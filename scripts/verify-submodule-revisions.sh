#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT="$ROOT/submodule-revisions.txt"
actual="$(git -C "$ROOT" submodule status --recursive)"

# A revision manifest records build inputs; it is not a trust allowlist.
# Reject incomplete/conflicted checkouts even if a manifest repeats that state.
if [[ -z "$actual" ]] || grep -Eq '^[-U]' <<<"$actual"; then
    printf 'submodule integrity: an initialized, conflict-free checkout is required\n' >&2
    exit 1
fi
if [[ -e "$SNAPSHOT" ]]; then
    if [[ ! -s "$SNAPSHOT" ]] || ! cmp -s "$SNAPSHOT" <(printf '%s\n' "$actual"); then
        printf 'submodule integrity: checkouts differ from the resolved build snapshot\n' >&2
        exit 1
    fi
elif grep -q '^+' <<<"$actual"; then
    printf 'submodule integrity: checkout differs from recorded gitlinks without a build snapshot\n' >&2
    exit 1
fi
printf 'Submodule revision integrity passed\n'
