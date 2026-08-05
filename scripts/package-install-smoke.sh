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
MANAGER_MODPATH="$TMP/manager-module"
PREV_MOD="$TMP/prev-module"
MOCK_BIN="$TMP/bin"
POISONED_CALLER_PATH="$TMP/poisoned-caller-path"
LOG="$TMP/install.log"
MANAGER_LOG="$TMP/manager-install.log"

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
    if [[ -f "$MANAGER_LOG" ]]; then
        printf '%s\n' '--- manager customize log ---' >&2
        tail -n 120 "$MANAGER_LOG" >&2 || true
        printf '%s\n' '--- end manager customize log ---' >&2
    fi
    exit 1
}

for tool in bash cargo chmod cp env find grep ln mkdir python3 readlink rm sed sh timeout unzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done
HOST_ENV="$(command -v env)"

"$ROOT/scripts/package-smoke.sh" "$ZIP_PATH"

mkdir -p "$MODPATH" "$MANAGER_MODPATH" "$MOCK_BIN"
unzip -oq "$ZIP_PATH" -d "$MODPATH"
unzip -oq "$ZIP_PATH" -d "$MANAGER_MODPATH"

mkdir -p \
    "$PREV_MOD/.state/sing-box/subscription-work" \
    "$PREV_MOD/.config/sing-box" \
    "$PREV_MOD/.config/magicnet"
printf '%s\n' 'https://old.example/sing-box' >"$PREV_MOD/.config/sing-box/subscription.url"
: >"$PREV_MOD/.config/sing-box/subscription-filter.list"
printf '%s\n' 'old-sing-box-work' >"$PREV_MOD/.state/sing-box/subscription-work/marker.txt"
printf '%s\n' 'MAGICNET_DEFAULT_CORE=sing-box' >"$PREV_MOD/.config/magicnet/current-core.conf"
printf '%s\n' 'MAGICNET_MCP_ENABLED=1' 'MAGICNET_MCP_BIND=127.0.0.1' 'MAGICNET_MCP_PORT=18766' \
    >"$PREV_MOD/.config/magicnet/mcp.conf"
printf '%s\n' 'legacy proxy capture config' >"$PREV_MOD/.config/magicnet/capture.conf"
printf '%s\n' '# legacy app policy' 'com.example.vpn' 'com.example.domestic' \
    >"$PREV_MOD/.config/magicnet/app-bypass.list"

for name in chcon restorecon getevent am cmd settings; do
    cat >"$MOCK_BIN/$name" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2 $3 $4 $5" == "package query-services --brief -a android.net.VpnService" ]]; then
    printf '%s\n' '1 services found:' '  com.example.vpn/com.example.vpn.TunnelService'
    exit 0
fi
exit 0
SH
    chmod +x "$MOCK_BIN/$name"
done

install_host_tool_fixtures() {
    fixture_module="$1"
    for tool in bash chown chmod cp cut date find grep ln mkdir rm sed sh timeout tr unzip; do
        host_tool="$(command -v "$tool")" || fail "missing host tool fixture: $tool"
        [[ -x "$host_tool" ]] || fail "host tool fixture is not executable: $tool"
        [[ ! -e "$fixture_module/bin/$tool" ]] || fail "host tool fixture collides with package binary: $tool"
        ln -s "$host_tool" "$fixture_module/bin/$tool"
    done
    for name in chcon restorecon getevent am cmd settings; do
        [[ ! -e "$fixture_module/bin/$name" ]] || fail "Android mock collides with package binary: $name"
        ln -s "$MOCK_BIN/$name" "$fixture_module/bin/$name"
    done
}

remove_host_tool_fixtures() {
    fixture_module="$1"
    rm -f "$fixture_module/bin"/{bash,chcon,chmod,chown,cmd,cp,cut,date,find,getevent,grep,ln,mkdir,restorecon,rm,sed,settings,sh,timeout,tr,unzip}
}

assert_fixture_path() {
    fixture_module="$1"
    resolved_tool="$("$HOST_ENV" PATH="$fixture_module/bin:$POISONED_CALLER_PATH" "$fixture_module/bin/sh" -c 'command -v unzip')"
    [[ "$resolved_tool" == "$fixture_module/bin/unzip" ]] \
        || fail "customize fixture PATH resolved unzip outside module bin"
}

install_host_tool_fixtures "$MODPATH"
install_host_tool_fixtures "$MANAGER_MODPATH"
assert_fixture_path "$MODPATH"
assert_fixture_path "$MANAGER_MODPATH"

export ZIPFILE="$ZIP_PATH"
export MODPATH
export MODDIR="$MODPATH"
export BOOTMODE=true
export MAGICNET_NONINTERACTIVE=1
export MAGICNET_PREV_DIR="$PREV_MOD"
export TMPDIR="$TMP/tmp"
mkdir -p "$TMPDIR" "$POISONED_CALLER_PATH"

if ! "$HOST_ENV" -u LD_LIBRARY_PATH -u MAGICNET_NONINTERACTIVE -u MAGICNET_PREV_DIR \
    ZIPFILE="$ZIP_PATH" \
    MODPATH="$MANAGER_MODPATH" \
    MODDIR="$MANAGER_MODPATH" \
    BOOTMODE=true \
    PATH="$MANAGER_MODPATH/bin:$POISONED_CALLER_PATH" \
    TMPDIR="$TMPDIR" \
    "$MANAGER_MODPATH/bin/timeout" 5 "$MANAGER_MODPATH/bin/sh" "$MANAGER_MODPATH/customize.sh" >"$MANAGER_LOG" 2>&1; then
    fail "manager-style customize.sh should not require volume-key interaction"
fi

if ! "$HOST_ENV" -u LD_LIBRARY_PATH \
    ZIPFILE="$ZIP_PATH" \
    MODPATH="$MODPATH" \
    MODDIR="$MODPATH" \
    BOOTMODE=true \
    MAGICNET_NONINTERACTIVE=1 \
    MAGICNET_PREV_DIR="$PREV_MOD" \
    PATH="$MODPATH/bin:$POISONED_CALLER_PATH" \
    TMPDIR="$TMPDIR" \
    "$MODPATH/bin/sh" "$MODPATH/customize.sh" >"$LOG" 2>&1; then
    fail "customize.sh failed"
fi

remove_host_tool_fixtures "$MODPATH"
remove_host_tool_fixtures "$MANAGER_MODPATH"

[[ -x "$MODPATH/bin/magicnet-mcp-server" ]] || fail "bin/magicnet-mcp-server is not executable"
[[ -x "$MODPATH/bin/ecapture" ]] || fail "bin/ecapture is not executable"
[[ -L "$MODPATH/cli" ]] || fail "cli is not a symlink"
[[ "$(readlink "$MODPATH/cli")" == "bin/magicnet-cli" ]] || fail "cli does not point to bin/magicnet-cli"
[[ -x "$MODPATH/cli" ]] || fail "cli symlink target is not executable"

expected_default_filters="$(printf '%s\n' '免费' 'free' 'HK' '香港' 'TW' '台湾')"
actual_default_filters="$(cat "$MANAGER_MODPATH/.config/sing-box/subscription-filter.list")"
[[ "$actual_default_filters" == "$expected_default_filters" ]] \
    || fail "fresh install did not initialize the default subscription filters"
unset expected_default_filters actual_default_filters

for entry in action.sh service.sh boot-completed.sh; do
    [[ -x "$MODPATH/$entry" ]] || fail "$entry is not executable"
done

PATH="$MODPATH/bin:$PATH" command -v magicnet-mcp-server >/dev/null \
    || fail "PATH cannot find magicnet-mcp-server through bin"
PATH="$MODPATH/bin:$PATH" command -v ecapture >/dev/null \
    || fail "PATH cannot find ecapture through bin"

grep -qx 'https://old.example/sing-box' "$MODPATH/.config/sing-box/subscription.url" \
    || fail "sing-box subscription was not preserved from previous install"
[[ -f "$MODPATH/.config/sing-box/subscription-filter.list" ]] \
    && [[ ! -s "$MODPATH/.config/sing-box/subscription-filter.list" ]] \
    || fail "explicit empty subscription filter list was not preserved from previous install"
grep -qx 'old-sing-box-work' "$MODPATH/.state/sing-box/subscription-work/marker.txt" \
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
grep -qx 'com.example.vpn' "$MODPATH/.config/magicnet/app-bypass.list" \
    || fail "VPN app bypass was not preserved during migration"
if grep -qx 'com.example.domestic' "$MODPATH/.config/magicnet/app-bypass.list"; then
    fail "legacy non-VPN app bypass was restored during migration"
fi
[[ -f "$MODPATH/.config/magicnet/app-policy-migration-vpn-only" ]] \
    || fail "app bypass migration marker was not written"

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
