#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="${1:-}"

if [[ -z "$ZIP_PATH" ]]; then
    module_id="$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$ROOT/kam.toml" | head -n1)"
    ZIP_PATH="$ROOT/dist/${module_id}.zip"
elif [[ "$ZIP_PATH" != /* ]]; then
    ZIP_PATH="$ROOT/$ZIP_PATH"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-install-smoke.XXXXXX")"
MODPATH="$TMP/module"
PREV_MOD="$TMP/prev-module"
MOCK_BIN="$TMP/bin"
LOG="$TMP/install.log"

cleanup() {
    if [[ "${MAGICNET_INSTALL_SMOKE_KEEP:-0}" == "1" ]]; then
        echo "keeping package install smoke directory: $TMP" >&2
        return
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
    printf 'package install smoke failed: %s\n' "$*" >&2
    if [[ -f "$LOG" ]]; then
        printf '%s\n' '--- customize log ---' >&2
        tail -n 120 "$LOG" >&2 || true
        printf '%s\n' '--- end customize log ---' >&2
    fi
    exit 1
}

for tool in bash cargo chmod cp find grep ln mkdir python3 readlink rm sed sh unzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

"$ROOT/scripts/package-smoke.sh" "$ZIP_PATH"

mkdir -p "$MODPATH" "$MOCK_BIN"
unzip -oq "$ZIP_PATH" -d "$MODPATH"

mkdir -p \
    "$PREV_MOD/.config/sing-box/.subscription-work" \
    "$PREV_MOD/.config/magicnet"
printf '%s\n' 'https://old.example/sing-box' >"$PREV_MOD/.config/sing-box/subscription.url"
printf '%s\n' 'old-sing-box-work' >"$PREV_MOD/.config/sing-box/.subscription-work/marker.txt"
printf '%s\n' 'MAGICNET_DEFAULT_CORE=sing-box' >"$PREV_MOD/.config/magicnet/current-core.conf"
printf '%s\n' 'MAGICNET_MCP_ENABLED=1' 'MAGICNET_MCP_BIND=127.0.0.1' 'MAGICNET_MCP_PORT=18766' \
    >"$PREV_MOD/.config/magicnet/mcp.conf"
printf '%s\n' 'legacy proxy capture config' >"$PREV_MOD/.config/magicnet/capture.conf"

for name in chcon restorecon getevent am cmd settings; do
    cat >"$MOCK_BIN/$name" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$MOCK_BIN/$name"
done

cat >"$MOCK_BIN/unzip" <<SH
#!/usr/bin/env bash
exec "$(command -v unzip)" "\$@"
SH
chmod +x "$MOCK_BIN/unzip"

export ZIPFILE="$ZIP_PATH"
export MODPATH
export MODDIR="$MODPATH"
export BOOTMODE=true
export MAGICNET_NONINTERACTIVE=1
export MAGICNET_PREV_DIR="$PREV_MOD"
export PATH="$MOCK_BIN:$PATH"
export TMPDIR="$TMP/tmp"
mkdir -p "$TMPDIR"

if ! sh "$MODPATH/customize.sh" >"$LOG" 2>&1; then
    fail "customize.sh failed"
fi

[[ -x "$MODPATH/bin/magicnet-mcp-server" ]] || fail "bin/magicnet-mcp-server is not executable"
[[ -x "$MODPATH/bin/ecapture" ]] || fail "bin/ecapture is not executable"
[[ -L "$MODPATH/cli" ]] || fail "cli is not a symlink"
[[ "$(readlink "$MODPATH/cli")" == "bin/magicnet-cli" ]] || fail "cli does not point to bin/magicnet-cli"
[[ -x "$MODPATH/cli" ]] || fail "cli symlink target is not executable"

for entry in action.sh service.sh boot-completed.sh; do
    [[ -x "$MODPATH/$entry" ]] || fail "$entry is not executable"
done

PATH="$MODPATH/bin:$PATH" command -v magicnet-mcp-server >/dev/null \
    || fail "PATH cannot find magicnet-mcp-server through bin"
PATH="$MODPATH/bin:$PATH" command -v ecapture >/dev/null \
    || fail "PATH cannot find ecapture through bin"

grep -qx 'https://old.example/sing-box' "$MODPATH/.config/sing-box/subscription.url" \
    || fail "sing-box subscription was not preserved from previous install"
grep -qx 'old-sing-box-work' "$MODPATH/.config/sing-box/.subscription-work/marker.txt" \
    || fail "sing-box subscription workdir was not preserved from previous install"
legacy_core_dir="$MODPATH/.config/mi""homo"
if [[ -e "$legacy_core_dir" ]]; then
    fail "legacy core config directory should not be restored"
fi
grep -qx 'MAGICNET_DEFAULT_CORE=sing-box' "$MODPATH/.config/magicnet/current-core.conf" \
    || fail "magicnet core config was not preserved from previous install"
grep -qx 'MAGICNET_MCP_PORT=18766' "$MODPATH/.config/magicnet/mcp.conf" \
    || fail "MCP config was not preserved from previous install"
[[ ! -e "$MODPATH/.config/magicnet/capture.conf" ]] \
    || fail "legacy capture config should not be restored"

cargo build -p magicnet-cli -p magicnet-mcp-server >/dev/null
cp "$ROOT/target/debug/magicnet-cli" "$MODPATH/bin/magicnet-cli"
cp "$ROOT/target/debug/magicnet-mcp-server" "$MODPATH/bin/magicnet-mcp-server"
chmod 0755 "$MODPATH/bin/magicnet-cli" "$MODPATH/bin/magicnet-mcp-server"

MODDIR="$MODPATH" "$MODPATH/cli" mcp status >"$TMP/mcp-status.log"
grep -qx 'enabled=1' "$TMP/mcp-status.log" || fail "unexpected MCP preserved enabled state"
grep -qx 'bind=127.0.0.1' "$TMP/mcp-status.log" || fail "unexpected MCP default bind"
grep -qx 'port=18766' "$TMP/mcp-status.log" || fail "unexpected MCP preserved port"
grep -qx 'pid=stopped' "$TMP/mcp-status.log" || fail "MCP should not auto-start during install"

python3 - "$MODPATH/module.prop" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
required = {"id", "name", "version", "versionCode", "author", "description"}
seen = {}
for line in text.splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        seen[key] = value
missing = sorted(required - seen.keys())
if missing:
    raise SystemExit(f"module.prop missing keys: {missing}")
if seen["id"] != "MagicNet":
    raise SystemExit(seen)
PY

printf 'package install smoke passed: %s\n' "$ZIP_PATH"
