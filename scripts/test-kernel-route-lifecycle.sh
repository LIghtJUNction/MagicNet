#!/usr/bin/env sh
# Stateful command tests supersede the old broad table/priority-delete fixture.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
python3 "$ROOT/scripts/test-route-ownership.py"
MAGICNET_TEST_SHELL=bash python3 "$ROOT/scripts/test-route-ownership.py"
if command -v busybox >/dev/null 2>&1; then
    MAGICNET_TEST_SHELL=busybox python3 "$ROOT/scripts/test-route-ownership.py"
fi
# PR and release host gates must also exercise the real Linux deletion API.
# Local unprivileged runs are explicitly only the command-fixture scope.
if [ "${GITHUB_ACTIONS:-false}" = true ]; then
    sudo -n bash "$ROOT/scripts/test-route-ownership-netns.sh"
fi
