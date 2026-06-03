#!/bin/bash
# shellcheck source=hooks/lib/utils.sh
. "$KAM_HOOKS_ROOT/lib/utils.sh"
# shellcheck source=hooks/lib/build_utils.sh
. "$KAM_HOOKS_ROOT/lib/build_utils.sh"

if [ ! -f "$KAM_PROJECT_ROOT/Cargo.toml" ]; then
    log_info "Cargo.toml not found; skipping Rust crate build"
    exit 0
fi

require_command cargo "cargo not found ."

ensure_rust_target() {
    local target="$1"

    if ! command -v rustup >/dev/null 2>&1; then
        log_warn "rustup not found; cannot verify Rust target $target"
        return 0
    fi

    if rustup target list --installed | grep -Fx "$target" >/dev/null 2>&1; then
        return 0
    fi

    log_info "Installing Rust target: $target"
    rustup target add "$target" || {
        log_error "Missing Rust target: $target. Run: rustup target add $target"
        return 1
    }
}

ensure_rust_target aarch64-linux-android || exit 1

if command -v cargo-ndk >/dev/null 2>&1; then
    cargo ndk build -t arm64-v8a --release
elif command -v cross >/dev/null 2>&1; then
    cross build --release --target aarch64-linux-android
else
    log_error "Neither cargo-ndk nor cross found. Install cargo-ndk with: cargo install cargo-ndk"
    exit 1
fi

TARGET_BIN_DIR="${KAM_MODULE_ROOT}/.local/bin"
TARGET_TRIPLE="aarch64-linux-android"

mkdir -p "$TARGET_BIN_DIR"
for _tool in magicnet-cli magicnet-mcp-server; do
    _built="${KAM_PROJECT_ROOT}/target/${TARGET_TRIPLE}/release/${_tool}"
    if [ ! -f "$_built" ]; then
        log_error "Rust tool was not produced: $_built"
        exit 1
    fi
    install -m 0755 "$_built" "${TARGET_BIN_DIR}/${_tool}"
    log_info "Installed ${_tool} to ${TARGET_BIN_DIR}/${_tool}"
done

ln -sfn ".local/bin/magicnet-cli" "${KAM_MODULE_ROOT}/cli"
chmod 0755 "${TARGET_BIN_DIR}/magicnet-cli" "${TARGET_BIN_DIR}/magicnet-mcp-server"
