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
        cached rust rust-clippy cargo clippy --workspace --all-targets --all-features --locked -- \
            -D warnings \
            -D clippy::dbg_macro \
            -D clippy::todo \
            -D clippy::unimplemented
        cached rust rust-test cargo test --workspace --all-targets --all-features --locked
        ;;
    shell)
        # These cheap checks scan the whole repository, not only the host scope.
        # In particular, WebUI/Rust/docs edits and root kam.sh must never hide
        # behind a cached host success.
        python3 scripts/test-lint-source.py
        python3 scripts/lint-source.py
        bash scripts/lint-shell.sh
        bash scripts/test-host.sh
        ;;
    components)
        cached components go-format bash -o pipefail -c 'gofmt -l installer/components/*.go | (! grep -q .)'
        cached components go-vet env GO111MODULE=off go vet ./installer/components
        cached components go-test env GO111MODULE=off go test -race ./installer/components
        cached components components python3 scripts/test-components.py
        cached components installer-identity python3 scripts/test-installer-identity.py
        cached components kernelsu-installer-lifecycle python3 scripts/test-kernelsu-installer-lifecycle.py
        cached components core-size python3 scripts/test-core-size.py
        cached components release-gates python3 scripts/test-release-gates.py
        cached components component-archive-safety python3 scripts/test-component-archive-safety.py
        # The cache must never attest to its own correctness.
        python3 scripts/test-ci-test-cache.py
        python3 scripts/test-ci-quality.py
        ;;
    webui-check)
        # Quality only consumes the pass/fail result. Release/build workflows
        # rebuild their own artifacts, so tying this result to webui/dist makes
        # every fresh runner miss even when the exact validation already passed.
        cached webui webui-check bash -c 'cd webui && npm run check'
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
