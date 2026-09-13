#!/usr/bin/env bash
# Shared by the standalone quality workflow and the in-job release gate.
# The release gate uses the already-built checkout/submodule revisions; do not
# refresh dependencies here or test a different commit after a version bump.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cached() {
    local scope="$1" name="$2"
    shift 2
    # Keep the standalone gate usable in isolated command-stub regressions.
    if [[ -f "$ROOT/scripts/ci-test-cache.py" ]]; then
        python3 "$ROOT/scripts/ci-test-cache.py" "$scope" "$name" -- "$@"
    else
        "$@"
    fi
}

check_group() {
    case "$1" in
    rust)
        cached rust rust-fmt cargo fmt --all -- --check
        cached rust rust-clippy cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
        cached rust rust-test cargo test --workspace --all-targets --all-features --locked
        ;;
    shell)
        cached host shell-lint bash scripts/lint-shell.sh
        bash scripts/test-host.sh
        ;;
    components)
        cached components go-format bash -c '[[ -z "$(gofmt -l installer/components/*.go)" ]]'
        cached components go-vet env GO111MODULE=off go vet ./installer/components
        cached components go-test env GO111MODULE=off go test -race ./installer/components
        cached components components python3 scripts/test-components.py
        cached components core-size python3 scripts/test-core-size.py
        cached components release-gates python3 scripts/test-release-gates.py
        cached components component-archive-safety python3 scripts/test-component-archive-safety.py
        cached components cache-engine python3 scripts/test-ci-test-cache.py
        ;;
    webui-check)
        if [[ -f "$ROOT/scripts/ci-test-cache.py" ]]; then
            python3 "$ROOT/scripts/ci-test-cache.py" --output webui/dist webui webui-check -- \
                bash -c 'cd webui && npm run check'
        else
            (cd webui && npm run check)
        fi
        ;;
    webui-browser)
        cached webui webui-browser bash -c 'cd webui && npm run test:ui'
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
