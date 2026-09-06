#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'missing required command: shellcheck\n' >&2
    exit 127
fi

# Use tracked files so submodule code is checked by its own project. NUL
# delimiters also keep paths with whitespace intact.
mapfile -d '' -t bash_files < <(git ls-files -z -- 'hooks/*.sh' 'scripts/*.sh' kam.sh)
mapfile -d '' -t device_files < <(git ls-files -z -- 'src/MagicNet/*.sh' 'src/MagicNet/system/bin/*')

# Fixture-heavy host tests contain intentional cross-function state and mocks.
shellcheck -s bash \
    -e SC1091,SC2015,SC2034,SC2059,SC2218,SC2317,SC2329 \
    "${bash_files[@]}"

# Runtime fragments share variables through the loader. jq programs and
# deferred shell commands deliberately retain single-quoted dollar expressions.
shellcheck -s sh \
    -e SC1090,SC1091,SC2015,SC2016,SC2034,SC2059,SC2218,SC2329 \
    "${device_files[@]}"
