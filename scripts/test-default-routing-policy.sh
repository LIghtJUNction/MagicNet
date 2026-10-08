#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Package validation always checks the maintained policy and its real assets.
exec python3 "$ROOT/scripts/test-maintained-routing.py" --assets "$@"
