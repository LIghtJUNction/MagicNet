#!/bin/sh
set -eu
command -v go >/dev/null || { echo 'Go 1.24+ is required to build the downloader' >&2; exit 1; }
mkdir -p "$KAM_MODULE_ROOT/bin"
cd "$KAM_PROJECT_ROOT/downloader"
go test ./...
CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build -buildvcs=false -trimpath -ldflags='-s -w' -o "$KAM_MODULE_ROOT/bin/module-downloader" .
