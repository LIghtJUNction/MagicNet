#!/usr/bin/env bash
# The standalone quality workflow and release gate execute this same suite.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "${1:-all}" in
  rust)
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
    cargo test --workspace --all-targets --all-features --locked
    ;;
  shell)
    bash scripts/lint-shell.sh
    bash scripts/test-host.sh
    ;;
  webui)
    cd webui
    npm ci
    npm run check
    npx playwright install --with-deps chromium
    sudo apt-get install -y fonts-noto-cjk
    npm run test:ui
    ;;
  components)
    (
      cd tools/components
      test -z "$(gofmt -l .)"
      go vet ./...
      go test -race -count=1 ./...
    )
    python3 scripts/test-components.py
    python3 scripts/test-component-archive-safety.py
    python3 scripts/test-component-release-gate.py
    ;;
  all)
    for suite in rust shell webui components; do
      bash "$0" "$suite"
    done
    ;;
  *) printf 'usage: %s [rust|shell|webui|components|all]\n' "$0" >&2; exit 64 ;;
esac
