#!/usr/bin/env bash
# Ship one implementation to the core and reusable installer template.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$ROOT/tmpl/downloader_template/smart"
mkdir -p "$dest"
# Generated copies must never retain files removed from the source tree.
find "$dest" -maxdepth 1 -type f -name '*.go' -delete
cp "$ROOT"/installer/components/*.go "$dest/"
