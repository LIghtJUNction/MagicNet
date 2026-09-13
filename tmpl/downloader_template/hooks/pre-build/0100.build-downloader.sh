#!/bin/sh
set -eu
command -v go >/dev/null || { echo 'Go is required to build the downloader' >&2; exit 1; }
mkdir -p "$KAM_MODULE_ROOT/bin"
if grep -Eq '"module_id"[[:space:]]*:[[:space:]]*"MagicNet"' "$KAM_MODULE_ROOT/download.json"; then
    [ -f "$KAM_PROJECT_ROOT/smart/update.go" ] || { echo 'Shared smart updater source missing; regenerate the template' >&2; exit 1; }
    cd "$KAM_PROJECT_ROOT/smart"
    GO111MODULE=off go test ./...
    GO111MODULE=off CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build -trimpath -ldflags='-s -w -buildid=' -o "$KAM_MODULE_ROOT/bin/module-downloader" .
else
    cd "$KAM_PROJECT_ROOT/downloader"
    go test ./...
    CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build -buildvcs=false -trimpath -ldflags='-s -w' -o "$KAM_MODULE_ROOT/bin/module-downloader" .
fi
