#!/usr/bin/env bash
set -euo pipefail
: "${KAM_PROJECT_ROOT:?}" "${KAM_MODULE_ROOT:?}"
mkdir -p "$KAM_MODULE_ROOT/bin"
cd "$KAM_PROJECT_ROOT/tools/components"
CGO_ENABLED=0 GOOS=android GOARCH=arm64 GOTOOLCHAIN=local \
  go build -mod=readonly -trimpath -ldflags='-s -w -buildid=' \
  -o "$KAM_MODULE_ROOT/bin/magicnet-components" .
chmod 0755 "$KAM_MODULE_ROOT/bin/magicnet-components"
