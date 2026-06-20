#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"

PROJECT_ROOT="${KAM_PROJECT_ROOT:-$(cd "$KAM_HOOKS_ROOT/.." && pwd)}"
TARGET_DIR="${KAM_MODULE_ROOT}/bin"
TARGET_TRIPLE="aarch64-linux-android"

build_crate() {
    _package="$1"
    _binary="$2"

    if command -v cargo-ndk >/dev/null 2>&1; then
        log_info "Building ${_package} for Android arm64 with cargo-ndk"
        (cd "$PROJECT_ROOT" && cargo ndk -t arm64-v8a build --release -p "$_package")
    elif command -v cross >/dev/null 2>&1; then
        log_info "Building ${_package} for Android arm64 with cross"
        (cd "$PROJECT_ROOT" && cross build --release --target "$TARGET_TRIPLE" -p "$_package")
    else
        log_error "cargo-ndk or cross is required to build ${_package}"
        exit 1
    fi

    _source="${PROJECT_ROOT}/target/${TARGET_TRIPLE}/release/${_binary}"
    if [ ! -x "$_source" ]; then
        log_error "Built binary not found: $_source"
        exit 1
    fi

    mkdir -p "$TARGET_DIR"
    cp -f "$_source" "${TARGET_DIR}/${_binary}"
    chmod 0755 "${TARGET_DIR}/${_binary}"
    log_success "Installed ${_binary} to ${TARGET_DIR}/${_binary}"
    unset _package _binary _source
}

build_crate magicnet-cli magicnet-cli
build_crate magicnet-ebpf magicnet-ebpf
build_crate magicnet-mcp-server magicnet-mcp-server

rm -f "${KAM_MODULE_ROOT}/cli"
ln -s "bin/magicnet-cli" "${KAM_MODULE_ROOT}/cli"

if [ ! -x "${KAM_MODULE_ROOT}/cli" ]; then
    log_error "cli symlink target is not executable"
    exit 1
fi

if [ ! -x "${KAM_MODULE_ROOT}/bin/magicnet-mcp-server" ]; then
    log_error "bin/magicnet-mcp-server is not executable"
    exit 1
fi

if [ ! -x "${KAM_MODULE_ROOT}/bin/magicnet-ebpf" ]; then
    log_error "bin/magicnet-ebpf is not executable"
    exit 1
fi

log_success "MagicNet Rust tools installed"
