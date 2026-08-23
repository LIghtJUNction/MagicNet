#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/src/MagicNet/lib/kamfw/rich_rendering/layout.sh"

width=78
expected=
for ((index = 0; index < width; index++)); do
    expected+='━'
done

# C locale reproduces Android awk implementations that count UTF-8 bytes.
actual="$(LC_ALL=C __rich_repeat '━' "$width")"
if [[ "$actual" != "$expected" ]]; then
    echo 'rich Unicode repeat was truncated or produced the wrong width' >&2
    exit 1
fi
printf '%s' "$actual" | python3 -c 'import sys; data = sys.stdin.buffer.read(); data.decode("utf-8"); assert len(data) == 78 * len("━".encode())'

# The no-awk fallback must preserve the same byte-safe behavior.
empty_path="$(mktemp -d)"
trap 'rm -rf "$empty_path"' EXIT
fallback="$(PATH="$empty_path" __rich_repeat '━' 7)"
[[ "$fallback" == '━━━━━━━' ]]

echo 'kamfw rich output tests passed'
