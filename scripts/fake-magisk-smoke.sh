#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="${1:-}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-fake-magisk.XXXXXX")"
MODDIR="$TMP/module"
MOCK_BIN="$TMP/bin"
TOYBOX_APPLET_BIN="$TMP/toybox-bin"
MOCK_LOG="$TMP/mock-commands.log"
CLI_BIN="$ROOT/target/debug/magicnet-cli"
MCP_BIN="$ROOT/target/debug/magicnet-mcp-server"

sanitize_host_path() {
    local raw="${1:-}"
    local entry
    local out=""
    local old_ifs="$IFS"
    IFS=:
    for entry in $raw; do
        case "$entry" in
            "" | */.local/"bin")
                continue
                ;;
        esac
        if [[ -z "$out" ]]; then
            out="$entry"
        else
            out="$out:$entry"
        fi
    done
    IFS="$old_ifs"
    printf '%s' "$out"
}

ORIGINAL_PATH="$(sanitize_host_path "${PATH:-}")"

cleanup() {
    if [[ "${MAGICNET_FAKE_KEEP:-0}" == "1" ]]; then
        echo "keeping fake Magisk directory: $TMP" >&2
        return
    fi
    if [[ -n "${MODDIR:-}" && -x "${MODDIR:-}/cli" ]]; then
        env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp stop >/dev/null 2>&1 || true
        env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor stop all >/dev/null 2>&1 || true
        pkill -f "$MODDIR/cli.*service ensure" 2>/dev/null || true
        pkill -f "$MODDIR/cli.*config apply" 2>/dev/null || true
        if [[ -s "$MODDIR/.state/fake-sing-box.pid" ]]; then
            kill "$(cat "$MODDIR/.state/fake-sing-box.pid")" 2>/dev/null || true
        fi
        if [[ -s "$MODDIR/.state/fake-mihomo.pid" ]]; then
            kill "$(cat "$MODDIR/.state/fake-mihomo.pid")" 2>/dev/null || true
        fi
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
on_error() {
    local status=$?
    echo "fake Magisk smoke failed with status $status" >&2
    if [[ -f "$TMP/runtime-path.log" ]]; then
        echo "--- runtime path log ---" >&2
        cat "$TMP/runtime-path.log" >&2
        echo "--- end runtime path log ---" >&2
    fi
    if [[ -f "$TMP/customize.log" ]]; then
        echo "--- customize log ---" >&2
        tail -n 120 "$TMP/customize.log" >&2 || true
        echo "--- end customize log ---" >&2
    fi
    if [[ -d "$MODDIR/.state" ]]; then
        echo "--- module state files ---" >&2
        find "$MODDIR/.state" -maxdepth 4 -type f -print >&2
        echo "--- end module state files ---" >&2
    fi
    if [[ -d "$MODDIR/.log" ]]; then
        echo "--- module logs ---" >&2
        find "$MODDIR/.log" -maxdepth 2 -type f -print -exec tail -n 40 {} \; >&2
        echo "--- end module logs ---" >&2
    fi
    if [[ -f "$TMP/status-refresh.log" ]]; then
        echo "--- status refresh log ---" >&2
        cat "$TMP/status-refresh.log" >&2
        echo "--- end status refresh log ---" >&2
    fi
    if [[ -f "$MOCK_LOG" ]]; then
        echo "--- mock command log ---" >&2
        cat "$MOCK_LOG" >&2
        echo "--- end mock command log ---" >&2
    fi
    exit "$status"
}
trap on_error ERR

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 127
    fi
}

need cargo
need cp
need jq
need python3
need rg
need unzip

HOST_JQ="$(command -v jq)"

if [[ -n "$ZIP_PATH" && "$ZIP_PATH" != /* ]]; then
    ZIP_PATH="$ROOT/$ZIP_PATH"
fi

cargo build -p magicnet-cli -p magicnet-mcp-server >/dev/null

mkdir -p "$MOCK_BIN"
if [[ -n "$ZIP_PATH" ]]; then
    "$ROOT/scripts/package-smoke.sh" "$ZIP_PATH" >/dev/null
    mkdir -p "$MODDIR"
    unzip -oq "$ZIP_PATH" -d "$MODDIR"
    for name in chcon restorecon getevent am cmd settings chown; do
        cat >"$MOCK_BIN/$name" <<'SH'
#!/usr/bin/env bash
exit 0
SH
        chmod +x "$MOCK_BIN/$name"
    done
    export ZIPFILE="$ZIP_PATH"
    export MODPATH="$MODDIR"
    export MODDIR
    export BOOTMODE=true
    export MAGICNET_NONINTERACTIVE=1
    export TMPDIR="$TMP/tmp"
    mkdir -p "$TMPDIR"
    if ! PATH="$MOCK_BIN:$ORIGINAL_PATH" sh "$MODDIR/customize.sh" >"$TMP/customize.log" 2>&1; then
        echo "customize.sh failed during fake Magisk zip smoke" >&2
        exit 1
    fi
    legacy_bin="$MODDIR/.local/"bin
    if [[ -e "$legacy_bin" || -L "$legacy_bin" ]]; then
        echo "legacy runtime bin path still exists after customize.sh" >&2
        exit 1
    fi
    test -L "$MODDIR/cli"
    test "$(readlink "$MODDIR/cli")" = "bin/magicnet-cli"
else
    cp -a "$ROOT/src/MagicNet" "$MODDIR"
fi
mkdir -p "$MODDIR/bin"
cp "$CLI_BIN" "$MODDIR/bin/magicnet-cli"
cp "$MCP_BIN" "$MODDIR/bin/magicnet-mcp-server"
rm -f "$MODDIR/cli"
ln -s "bin/magicnet-cli" "$MODDIR/cli"
chmod +x "$MODDIR/bin/magicnet-cli" "$MODDIR/bin/magicnet-mcp-server"
: >"$MOCK_LOG"

setup_toybox_layer() {
    local toybox_bin="${TOYBOX_BIN:-}"
    local applet
    local installed=0
    local applets=(
        basename cat chmod chown cp cut date dirname false find grep head id
        kill ln ls mkdir mv printf ps pwd readlink realpath rm sed sleep sort
        tail touch tr true uname wc whoami xargs
    )

    if [[ -z "$toybox_bin" ]]; then
        toybox_bin="$(command -v toybox || true)"
    fi

    if [[ -z "$toybox_bin" || ! -x "$toybox_bin" ]]; then
        echo "toybox layer disabled: toybox not found"
        return 0
    fi

    mkdir -p "$TOYBOX_APPLET_BIN"
    for applet in "${applets[@]}"; do
        if "$toybox_bin" | tr ' ' '\n' | grep -qx "$applet"; then
            ln -sf "$toybox_bin" "$TOYBOX_APPLET_BIN/$applet"
            installed=$((installed + 1))
        fi
    done

    if [[ "$installed" -eq 0 ]]; then
        echo "toybox layer disabled: no matching applets from $toybox_bin"
        return 0
    fi

    echo "toybox layer enabled: $toybox_bin ($installed applets)"
}

setup_toybox_layer

write_mock() {
    local name="$1"
    local body="$2"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        # shellcheck disable=SC2016
        printf 'printf '\''%%s\\n'\'' "%s $*" >>"${MAGICNET_FAKE_LOG:?}"\n' "$name"
        printf '%s\n' "$body"
    } >"$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

# shellcheck disable=SC2016
write_mock ip '
case "${1:-}" in
    rule)
        if [[ "${2:-}" == "show" ]]; then exit 0; fi
        exit 0
        ;;
    route)
        if [[ "${2:-}" == "show" ]]; then exit 0; fi
        exit 0
        ;;
    -o)
        if [[ "${2:-}" == "-4" && "${3:-}" == "addr" && "${4:-}" == "show" ]]; then
            dev="${6:-}"
            case "$dev" in
                ap0|wlan0) echo "7: $dev inet 192.168.43.1/24 brd 192.168.43.255 scope global $dev" ;;
                tun0) echo "9: tun0 inet 10.8.0.2/24 scope global tun0" ;;
                magicnet0) echo "8: magicnet0 inet 172.19.0.1/30 scope global magicnet0" ;;
            esac
            exit 0
        fi
        if [[ "${2:-}" == "-6" && "${3:-}" == "addr" && "${4:-}" == "show" ]]; then
            dev="${6:-}"
            [[ "$dev" == "tun0" ]] && echo "9: tun0 inet6 fd00::2/64 scope global"
            exit 0
        fi
        ;;
esac
exit 0
'

# shellcheck disable=SC2016
write_mock iptables '
if [[ "${1:-}" == "-nL" && "${2:-}" == "tetherctrl_FORWARD" ]]; then exit 0; fi
for arg in "$@"; do
    if [[ "$arg" == "-C" ]]; then exit 1; fi
done
exit 0
'
cp "$MOCK_BIN/iptables" "$MOCK_BIN/ip6tables"

# shellcheck disable=SC2016
write_mock getprop '
case "${1:-}" in
    sys.boot_completed) echo 1 ;;
    persist.sys.locale) echo en-US ;;
esac
'

# shellcheck disable=SC2016
write_mock resetprop '
if [[ "${1:-}" == "--delete" ]]; then exit 0; fi
if [[ "${1:-}" == "-Z" ]]; then echo "u:object_r:system_prop:s0"; exit 0; fi
exit 0
'

write_mock setprop 'exit 0'
write_mock cmd 'exit 0'
write_mock su 'shift || true; "$@"'
write_mock am 'exit 0'
# shellcheck disable=SC2016
write_mock pm '
if [[ "${1:-}" == "path" ]]; then echo "package:/data/app/${2:-mock}/base.apk"; fi
'
write_mock ndc 'exit 0'
write_mock svc 'exit 0'
write_mock magiskpolicy 'exit 0'
write_mock ipset 'exit 0'
write_mock pkill 'exit 0'
write_mock pidof 'exit 1'
# shellcheck disable=SC2016
write_mock mihomo '
case "${1:-}" in
    -v) echo "Mihomo Fake 0.0.0"; exit 0 ;;
    -t) exit 0 ;;
    -f)
        mkdir -p "${MODDIR:?}/.state"
        echo "$$" >"$MODDIR/.state/fake-mihomo.pid"
        printf "%s" "mihomo" >/proc/$$/comm 2>/dev/null || true
        while :; do sleep 3600; done
        ;;
esac
exit 0
'
# shellcheck disable=SC2016
write_mock sing-box '
case "${1:-}" in
    version) echo "sing-box fake 0.0.0"; exit 0 ;;
    check) exit 0 ;;
    run)
        mkdir -p "${MODDIR:?}/.state"
        echo "$$" >"$MODDIR/.state/fake-sing-box.pid"
        printf "%s" "sing-box" >/proc/$$/comm 2>/dev/null || true
        while :; do sleep 3600; done
        ;;
esac
exit 0
'
write_mock curl '
out=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            out="${2:-}"
            shift 2
            ;;
        -x|--max-time|--connect-timeout|-H|--data|--data-binary)
            shift 2
            ;;
        --*)
            shift
            ;;
        -*)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
case "$url" in
    http://127.0.0.1:9090/providers/proxies*)
        printf "%s\n" "{\"providers\":{\"premium_a\":{\"proxies\":[{\"name\":\"fake-node\",\"type\":\"VMess\"}]}}}"
        exit 0
        ;;
    http://127.0.0.1:9090/proxies*)
        printf "%s\n" "{\"proxies\":{\"fake-node\":{\"name\":\"fake-node\",\"type\":\"VMess\"}},\"all\":[\"fake-node\"]}"
        exit 0
        ;;
    http://127.0.0.1:7892*|https://www.baidu.com|https://www.google.com|https://chatgpt.com)
        printf "%s\n" "HTTP/1.1 200 OK"
        exit 0
        ;;
esac
if [[ -n "$out" ]]; then
    cat >"$out" <<YAML
proxies:
  - name: fresh-sub-node
    type: vmess
    server: 127.0.0.1
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    alterId: 0
    cipher: auto
YAML
    exit 0
fi
printf "%s\n" "{}"
'
write_mock killall 'exit 0'
cp "$MOCK_BIN/mihomo" "$MODDIR/bin/mihomo"
cp "$MOCK_BIN/sing-box" "$MODDIR/bin/sing-box"

cat >"$MOCK_BIN/pidof" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "pidof $*" >>"${MAGICNET_FAKE_LOG:?}"
case "${1:-}" in
    sing-box)
        pid_file="${MODDIR:?}/.state/fake-sing-box.pid"
        if [[ -s "$pid_file" ]]; then
            pid="$(cat "$pid_file")"
            if kill -0 "$pid" 2>/dev/null; then
                echo "$pid"
                exit 0
            fi
        fi
        ;;
    mihomo)
        pid_file="${MODDIR:?}/.state/fake-mihomo.pid"
        if [[ -s "$pid_file" ]]; then
            pid="$(cat "$pid_file")"
            if kill -0 "$pid" 2>/dev/null; then
                echo "$pid"
                exit 0
            fi
        fi
        ;;
esac
exit 1
SH
chmod +x "$MOCK_BIN/pidof"

"$HOST_JQ" '.outbounds += [{"type":"vmess","tag":"old-cached-node","server":"127.0.0.1","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000","security":"auto"}]' \
    "$MODDIR/.config/sing-box/config.json" >"$TMP/sing-box-config.json"
mv "$TMP/sing-box-config.json" "$MODDIR/.config/sing-box/config.json"

export MODDIR
export MODPATH="$MODDIR"
export BOOTMODE=true
export KAM_LANG=en
export MAGICNET_FAKE_LOG="$MOCK_LOG"
export MAGICNET_NOTIFY_ENABLED=0
export MAGICNET_WATCHDOG_ENABLED=0
export MAGICNET_FSWATCH_ENABLED=0
export MAGICNET_CONFIG_LOCK_TIMEOUT=2
export MAGIC_HOTSPOT_IFACES="ap0"
export MAGIC_VPN_COEXIST_IFACES="tun0"
export MAGIC_TUN_IFACES="magicnet0"
export PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH"

run() {
    echo "+ $*"
    "$@"
}

run sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import self
    config set override.description "fake smoke config"
    test "$(config get override.description)" = "fake smoke config"
    test -f "$MODDIR/.state/kamfw-config/${MODDIR##*/}/persist/override.description"
'

run sh "$MODDIR/service.sh"
run sh "$MODDIR/boot-completed.sh"

env -u MODDIR -u MODPATH \
    KAM_LANG="$KAM_LANG" \
    MAGICNET_FAKE_LOG="$MOCK_LOG" \
    MAGICNET_NOTIFY_ENABLED=0 \
    PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" diagnose >"$TMP/cli-autodetect-diagnose.log" 2>&1
if rg -q '\.kamfwrc|\.kamrc|No such file or directory' "$TMP/cli-autodetect-diagnose.log"; then
    echo "cli autodetect failed to locate module root" >&2
    cat "$TMP/cli-autodetect-diagnose.log" >&2
    exit 1
fi
rg -q 'MagicNet Diagnose' "$TMP/cli-autodetect-diagnose.log"

# shellcheck disable=SC2016
env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$ORIGINAL_PATH" sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    command -v mihomo
    command -v sing-box
' >"$TMP/runtime-path.log"
rg -q "^$MODDIR/bin/mihomo$" "$TMP/runtime-path.log"
rg -q "^$MODDIR/bin/sing-box$" "$TMP/runtime-path.log"
test -x "$MODDIR/bin/magicnet-mcp-server"

MCP_TEST_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp set 127.0.0.1 "$MCP_TEST_PORT"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp enable 127.0.0.1 "$MCP_TEST_PORT"
sleep 1
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp status >"$TMP/mcp-status.log"
rg -q '^enabled=1$' "$TMP/mcp-status.log"
rg -q "^port=$MCP_TEST_PORT$" "$TMP/mcp-status.log"
rg -q '^pid=[0-9]+$' "$TMP/mcp-status.log"
MODDIR="$MODDIR" MCP_TEST_PORT="$MCP_TEST_PORT" python3 - <<'PY'
import json
import os
import socket

def rpc(method, params=None, request_id=1):
    payload = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        payload["params"] = params
    body = json.dumps(payload).encode()
    request = (
        b"POST /mcp HTTP/1.1\r\n"
        b"Host: 127.0.0.1\r\n"
        b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n\r\n".encode()
        + body
    )
    with socket.create_connection(("127.0.0.1", int(os.environ["MCP_TEST_PORT"])), timeout=5) as sock:
        sock.sendall(request)
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk
        header, _, body = response.partition(b"\r\n\r\n")
        content_length = 0
        for line in header.decode(errors="replace").splitlines():
            if line.lower().startswith("content-length:"):
                content_length = int(line.split(":", 1)[1].strip())
        while len(body) < content_length:
            chunk = sock.recv(4096)
            if not chunk:
                break
            body += chunk
    if b"200 OK" not in header:
        raise SystemExit((header + b"\r\n\r\n" + body).decode(errors="replace"))
    parsed = json.loads(body.decode())
    if "error" in parsed:
        raise SystemExit(parsed)
    return parsed["result"]

init = rpc("initialize", request_id=1)
if init["serverInfo"]["name"] != "magicnet":
    raise SystemExit(init)
tools = rpc("tools/list", request_id=2)
names = {item["name"] for item in tools["tools"]}
required = {"magicnet_status", "magicnet_mcp_control", "magicnet_log_read"}
missing = required - names
if missing:
    raise SystemExit(f"missing MCP tools: {sorted(missing)}")
PY
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp stop
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp status >"$TMP/mcp-stopped-enabled.log"
rg -q '^enabled=1$' "$TMP/mcp-stopped-enabled.log"
rg -q '^pid=stopped$' "$TMP/mcp-stopped-enabled.log"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" sh "$MODDIR/post-fs-data.sh"
sleep 6
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp status >"$TMP/mcp-service-start.log"
rg -q '^enabled=1$' "$TMP/mcp-service-start.log"
rg -q "^port=$MCP_TEST_PORT$" "$TMP/mcp-service-start.log"
rg -q '^pid=[0-9]+$' "$TMP/mcp-service-start.log"

run "$MODDIR/cli" service status
run "$MODDIR/cli" core status
run "$MODDIR/cli" core select mihomo
run "$MODDIR/cli" core status
grep -qx 'MAGICNET_DEFAULT_CORE=mihomo' "$MODDIR/.config/magicnet/current-core.conf"
run "$MODDIR/cli" core select sing-box
run "$MODDIR/cli" core status
grep -qx 'MAGICNET_DEFAULT_CORE=sing-box' "$MODDIR/.config/magicnet/current-core.conf"
# shellcheck disable=SC2016
env MAGICNET_DEFAULT_CORE=mihomo MAGICNET_STRICT_CORE=1 MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    magicnet_preferred_core
' >"$TMP/strict-core.log"
grep -qx 'mihomo' "$TMP/strict-core.log"

printf '%s\n' 'https://example.invalid/subscription.yaml' >"$MODDIR/.config/sing-box/subscription.url"
printf '%s\n' 'https://example.invalid/mihomo.yaml' >"$MODDIR/.config/mihomo/subscription.url"
: >"$MOCK_LOG"
run env \
    MAGICNET_WATCHDOG_ENABLED=0 \
    MAGICNET_FSWATCH_ENABLED=0 \
    MAGICNET_NOTIFY_ENABLED=0 \
    MODDIR="$MODDIR" \
    MODPATH="$MODDIR" \
    PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" service restart sing-box
sleep 1
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" service status >"$TMP/singbox-service-status.log"
rg -q '^  sing-box: [0-9]+$' "$TMP/singbox-service-status.log"
"$HOST_JQ" -e '.outbounds[] | select(.tag == "fresh-sub-node")' "$MODDIR/.config/sing-box/config.json" >/dev/null
if "$HOST_JQ" -e '.outbounds[] | select(.tag == "old-cached-node")' "$MODDIR/.config/sing-box/config.json" >/dev/null; then
    echo "sing-box startup used cached nodes instead of fresh subscription" >&2
    exit 1
fi
python3 - "$MOCK_LOG" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
fetch = next((i for i, line in enumerate(lines) if line.startswith("curl ") and "subscription.yaml" in line), None)
run = next((i for i, line in enumerate(lines) if line.startswith("sing-box run")), None)
if fetch is None or run is None or fetch > run:
    raise SystemExit("sing-box was started before fetching the subscription")
PY
if [[ -s "$MODDIR/.state/fake-sing-box.pid" ]]; then
    kill "$(cat "$MODDIR/.state/fake-sing-box.pid")" 2>/dev/null || true
    rm -f "$MODDIR/.state/fake-sing-box.pid"
fi
run env \
    MAGICNET_WATCHDOG_ENABLED=0 \
    MAGICNET_FSWATCH_ENABLED=0 \
    MAGICNET_NOTIFY_ENABLED=0 \
    MODDIR="$MODDIR" \
    MODPATH="$MODDIR" \
    PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" service restart mihomo
sleep 1
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" service status >"$TMP/mihomo-service-status.log"
rg -q '^  mihomo:[[:space:]]+[0-9]+$' "$TMP/mihomo-service-status.log"
if [[ -s "$MODDIR/.state/fake-mihomo.pid" ]]; then
    kill "$(cat "$MODDIR/.state/fake-mihomo.pid")" 2>/dev/null || true
    rm -f "$MODDIR/.state/fake-mihomo.pid"
fi
sleep 3600 &
echo "$!" >"$MODDIR/.state/fake-sing-box.pid"
sleep 1
env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" pidof sing-box >/dev/null
run env \
    MAGICNET_WATCHDOG_ENABLED=1 \
    MAGICNET_FSWATCH_ENABLED=1 \
    MAGICNET_WATCHDOG_INTERVAL=3600 \
    MAGICNET_FSWATCH_INTERVAL=3600 \
    MAGICNET_NOTIFY_ENABLED=0 \
    MODDIR="$MODDIR" \
    MODPATH="$MODDIR" \
    PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" supervisor start all
sleep 1
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor status all >"$TMP/supervisor-status.log"
rg -q '^watchdog=[0-9]+$' "$TMP/supervisor-status.log"
rg -q '^fswatch=[0-9]+$' "$TMP/supervisor-status.log"
test -s "$MODDIR/.state/watchdog/magicnet-kernel.pid"
test -s "$MODDIR/.state/fswatch/magicnet-config.pid"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor stop all
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor status all >"$TMP/supervisor-stopped.log"
rg -q '^watchdog=stopped$' "$TMP/supervisor-stopped.log"
rg -q '^fswatch=stopped$' "$TMP/supervisor-stopped.log"
run env \
    MAGICNET_WATCHDOG_ENABLED=1 \
    MAGICNET_FSWATCH_ENABLED=1 \
    MAGICNET_WATCHDOG_INTERVAL=3600 \
    MAGICNET_FSWATCH_INTERVAL=3600 \
    MAGICNET_NOTIFY_ENABLED=0 \
    MODDIR="$MODDIR" \
    MODPATH="$MODDIR" \
    PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    sh "$MODDIR/service.sh"
sleep 1
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor status all >"$TMP/supervisor-phase-status.log"
rg -q '^watchdog=[0-9]+$' "$TMP/supervisor-phase-status.log"
rg -q '^fswatch=[0-9]+$' "$TMP/supervisor-phase-status.log"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor stop all

run "$MODDIR/cli" transparent status
run "$MODDIR/cli" hotspot status
run "$MODDIR/cli" vpn status
run "$MODDIR/cli" config-editor validate mihomo
run "$MODDIR/cli" config-editor validate sing-box
run "$MODDIR/cli" config apply
run "$MODDIR/cli" hotspot reload
run "$MODDIR/cli" vpn reload
run "$MODDIR/cli" sub list
run "$MODDIR/cli" route list
run "$MODDIR/cli" block list
run "$MODDIR/cli" app list
run "$MODDIR/cli" backup export
run "$MODDIR/cli" diagnose

sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    import __singbox__
    import __mihomo__
    import() {
        :
    }
    config() {
        case "$1" in
            get)
                [ -f "$MODDIR/.state/test-config/$2" ] || return 1
                cat "$MODDIR/.state/test-config/$2"
                ;;
            set)
                mkdir -p "$MODDIR/.state/test-config"
                printf "%s" "$3" >"$MODDIR/.state/test-config/$2"
                ;;
            *) return 1 ;;
        esac
    }
    mihomo_pids() {
        printf "%s\n" 4242
    }
    singbox_pids() {
        return 0
    }
    is_singbox_running() {
        config set override.description "sing-box status: Not running"
        return 1
    }
    is_mihomo_running() {
        config set override.description "MiHoMo status: Running"
        return 0
    }
    magicnet_running_pids() {
        case "$1" in
            mihomo) printf "%s\n" 4242 ;;
            sing-box) return 0 ;;
            *) return 1 ;;
        esac
    }
    magicnet_refresh_status
    desc1="$(config get override.description)"
    magicnet_refresh_status
    desc2="$(config get override.description)"
    printf "%s\n%s\n" "$desc1" "$desc2"
' >"$TMP/status-refresh.log"
printf 'MiHoMo status: Running\nMiHoMo status: Running\n' | cmp - "$TMP/status-refresh.log"
if rg -q 'sing-box|No kernel|Not running' "$TMP/status-refresh.log"; then
    echo "status refresh overwrote a running mihomo description" >&2
    cat "$TMP/status-refresh.log" >&2
    exit 1
fi

assert_transparent_mode() {
    local mode="$1"
    local before_marker after_marker
    local expected_tproxy_port expected_redirect_port

    expected_tproxy_port="$(sed -n 's/^MAGICNET_TPROXY_PORT=//p' "$MODDIR/.config/magicnet/tproxy.conf")"
    expected_redirect_port="$(sed -n 's/^MAGICNET_TPROXY_REDIRECT_PORT=//p' "$MODDIR/.config/magicnet/tproxy.conf")"

    before_marker="$(wc -l <"$MOCK_LOG")"
    run sh -c '
        . "$MODDIR/lib/kamfw/.kamfwrc"
        import __runtime__
        . "$MODDIR/lib/magicnet.sh"
        magicnet_tproxy_has_kernel_support() {
            return 0
        }
        magicnet_transparent_set_mode "$1"
        magicnet_transparent_apply
    ' _ "$mode"
    after_marker="$(wc -l <"$MOCK_LOG")"
    sed -n "$((before_marker + 1)),${after_marker}p" "$MOCK_LOG" >"$TMP/${mode}-commands.log"

    run "$MODDIR/cli" transparent status

    python3 - "$MODDIR/.config/mihomo/config.yaml" "$MODDIR/.config/sing-box/config.json" "$mode" "$expected_tproxy_port" "$expected_redirect_port" <<'PY'
import json
import pathlib
import sys

import yaml

mihomo_path, singbox_path, mode, expected_tproxy_port, expected_redirect_port = sys.argv[1:]
mihomo = yaml.safe_load(pathlib.Path(mihomo_path).read_text())
singbox = json.loads(pathlib.Path(singbox_path).read_text())

tun_enabled = bool(mihomo.get("tun", {}).get("enable"))
inbound_types = [inbound.get("type") for inbound in singbox.get("inbounds", [])]
sniff_rule = next((rule for rule in singbox.get("route", {}).get("rules", []) if rule.get("action") == "sniff"), None)

if mode == "tun":
    if not tun_enabled:
        raise SystemExit("mihomo tun.enable is false in tun mode")
    if "tun" not in inbound_types:
        raise SystemExit("sing-box tun inbound missing in tun mode")
    if "tproxy" in inbound_types:
        raise SystemExit("sing-box tproxy inbound still present in tun mode")
    if not sniff_rule:
        raise SystemExit("sing-box sniff rule missing in tun mode")
    if sniff_rule.get("inbound") != ["mixed-in", "tun-in"]:
        raise SystemExit(f"sing-box sniff inbound list mismatch in tun mode: {sniff_rule.get('inbound')!r}")
elif mode == "tproxy":
    if tun_enabled:
        raise SystemExit("mihomo tun.enable is true in tproxy mode")
    tproxy_inbound = next((inbound for inbound in singbox.get("inbounds", []) if inbound.get("type") == "tproxy"), None)
    redirect_inbound = next((inbound for inbound in singbox.get("inbounds", []) if inbound.get("type") == "redirect"), None)
    if not tproxy_inbound:
        raise SystemExit("sing-box tproxy inbound missing in tproxy mode")
    if not redirect_inbound:
        raise SystemExit("sing-box redirect inbound missing in tproxy mode")
    if tproxy_inbound.get("listen_port") != int(expected_tproxy_port):
        raise SystemExit(f"sing-box tproxy port mismatch: {tproxy_inbound.get('listen_port')!r}")
    if redirect_inbound.get("listen_port") != int(expected_redirect_port):
        raise SystemExit(f"sing-box redirect port mismatch: {redirect_inbound.get('listen_port')!r}")
    if "tun" in inbound_types:
        raise SystemExit("sing-box tun inbound still present in tproxy mode")
    if not sniff_rule:
        raise SystemExit("sing-box sniff rule missing in tproxy mode")
    if sniff_rule.get("inbound") != ["mixed-in", "tproxy-in", "redirect-in"]:
        raise SystemExit(f"sing-box sniff inbound list mismatch in tproxy mode: {sniff_rule.get('inbound')!r}")
else:
    raise SystemExit(f"unsupported mode: {mode}")
PY

    case "$mode" in
        tun)
            rg -q '^iptables .* -t mangle -D PREROUTING -j MAGICNET_TPROXY$' "$TMP/${mode}-commands.log"
            rg -q '^ip route flush table 100$' "$TMP/${mode}-commands.log"
            ;;
        tproxy)
            rg -q "^iptables .* -t mangle -A MAGICNET_TPROXY -p tcp --dport 53 -j TPROXY --on-port ${expected_tproxy_port} --tproxy-mark 0x1/0x1$" "$TMP/${mode}-commands.log"
            rg -q "^iptables .* -t mangle -A MAGICNET_TPROXY -p udp -i ap0 -j TPROXY --on-port ${expected_tproxy_port} --tproxy-mark 0x1/0x1$" "$TMP/${mode}-commands.log"
            rg -q '^iptables .* -t mangle -I PREROUTING -j MAGICNET_TPROXY$' "$TMP/${mode}-commands.log"
            rg -q '^iptables .* -t mangle -I OUTPUT -j MAGICNET_TPROXY_OUTPUT$' "$TMP/${mode}-commands.log"
            rg -q '^iptables .* -t mangle -I PREROUTING -p tcp -m socket -j MAGICNET_TPROXY_DIVERT$' "$TMP/${mode}-commands.log"
            rg -q '^iptables .* -t nat -I OUTPUT -j MAGICNET_TPROXY_REDIRECT$' "$TMP/${mode}-commands.log"
            rg -q '^iptables .* -t nat -A MAGICNET_TPROXY_REDIRECT -m owner --uid-owner 0 -j RETURN$' "$TMP/${mode}-commands.log"
            rg -q '^iptables .* -t nat -A MAGICNET_TPROXY_REDIRECT -d 127.0.0.0/8 -j RETURN$' "$TMP/${mode}-commands.log"
            rg -q "^iptables .* -t nat -A MAGICNET_TPROXY_REDIRECT -p tcp -j REDIRECT --to-ports ${expected_redirect_port}$" "$TMP/${mode}-commands.log"
            rg -q '^ip rule add fwmark 0x1 table 100 pref 100$' "$TMP/${mode}-commands.log"
            rg -q '^ip route add local default dev lo table 100$' "$TMP/${mode}-commands.log"
            ;;
    esac
}

cat >"$MODDIR/.config/magicnet/tproxy.conf" <<'EOF'
MAGICNET_TPROXY_PORT=19098
MAGICNET_TPROXY_REDIRECT_PORT=19099
EOF
assert_transparent_mode tun
assert_transparent_mode tproxy
assert_transparent_mode tun

run sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    magicnet_iface_exists() {
        case "$1" in
            magicnet0|ap0|tun0) return 0 ;;
            *) return 1 ;;
        esac
    }
    magicnet_collect_external_vpn_ifaces() {
        printf "%s\n" tun0
    }
    magicnet_enable_hotspot_forward
'

run sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    magicnet_collect_tun_ifaces() {
        printf "%s\n" magicnet0
    }
    magicnet_collect_external_vpn_ifaces() {
        printf "%s\n" tun0
    }
    magicnet_vpn_coexist_enabled() {
        return 0
    }
    magicnet_enable_vpn_coexist
'

"$HOST_JQ" empty "$MODDIR/.config/sing-box/config.json"
python3 - "$MODDIR/.config/mihomo/config.yaml" <<'PY'
import pathlib
import sys
import yaml

yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
PY

rg -q '^iptables .*tetherctrl_FORWARD.*-i ap0 -o magicnet0 -j ACCEPT$' "$MOCK_LOG"
rg -q '^iptables -t nat .*POSTROUTING -o magicnet0 -j MASQUERADE$' "$MOCK_LOG"
rg -q '^ip rule add priority 8900 iif tun0 lookup main$' "$MOCK_LOG"
rg -q '^ip rule add priority 8950 iif tun0 lookup main$' "$MOCK_LOG"

echo "fake Magisk smoke passed: $MODDIR"
