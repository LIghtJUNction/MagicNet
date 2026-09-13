#!/usr/bin/env bash
# Shared by the standalone quality workflow and the in-job release gate.
# The release gate uses the already-built checkout/submodule revisions; do not
# refresh dependencies here or test a different commit after a version bump.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

check_group() {
    case "$1" in
    rust)
        cargo fmt --all -- --check
        cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
        cargo test --workspace --all-targets --all-features --locked
        ;;
    shell)
        bash scripts/lint-shell.sh
        bash scripts/test-host.sh
        ;;
    components)
        [[ -z "$(gofmt -l installer/components/*.go)" ]]
        GO111MODULE=off go vet ./installer/components
        GO111MODULE=off go test -race ./installer/components
        python3 scripts/test-components.py
        python3 scripts/test-core-size.py
        python3 scripts/test-release-gates.py
        ;;
    webui-check)
        (cd webui && npm run check)
        ;;
    webui-browser)
        (cd webui && npm run test:ui)
        ;;
    *)
        printf 'unknown quality group: %s\n' "$1" >&2
        return 64
        ;;
    esac
}

if [[ "${1:-all}" == all ]]; then
    for group in rust shell components webui-check webui-browser; do
        printf '\n=== quality gate: %s ===\n' "$group"
        check_group "$group"
    done
else
    check_group "$1"
fi
