#!/usr/bin/env bash
# Host execution and Android compile checks for the exact checked-out fork.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
test_root="$(mktemp -d "$PWD/.sing-box-ebpf-tests.XXXXXX")"
cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT
(
    cd sing-box
    CGO_ENABLED=0 GOTOOLCHAIN=local GOWORK=off \
        go test -count=1 -mod=readonly -tags with_ebpf \
        ./common/ebpf ./protocol/ebpf ./include ./option
    package_index=0
    for package in ./common/ebpf ./protocol/ebpf ./include ./option; do
        package_index=$((package_index + 1))
        CGO_ENABLED=0 GOOS=android GOARCH=arm64 GOTOOLCHAIN=local GOWORK=off \
            go test -c -mod=readonly -tags with_ebpf \
            -o "$test_root/package-${package_index}.test" "$package"
    done
)
