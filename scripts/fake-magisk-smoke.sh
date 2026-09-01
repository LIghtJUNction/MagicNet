#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="${1:-}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/magicnet-fake-magisk.XXXXXX")"
MODDIR="$TMP/module"
MOCK_BIN="$TMP/bin"
TOYBOX_APPLET_BIN="$TMP/toybox-bin"
POISONED_CALLER_PATH="$TMP/poisoned-caller-path"
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
        stop_fake_core_processes "sing-box" 2>/dev/null || true
        if [[ -s "$MODDIR/.state/fake-sing-box.pid" ]]; then
            kill "$(cat "$MODDIR/.state/fake-sing-box.pid")" 2>/dev/null || true
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
need env

HOST_JQ="$(command -v jq)"
HOST_GETENT="$(command -v getent || true)"
HOST_ENV="$(command -v env)"

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

    install_customize_fixtures() {
        local tool host_tool
        for tool in bash chmod cp cut date find grep ln mkdir rm sed sh tr unzip; do
            host_tool="$(command -v "$tool")" || {
                echo "missing host tool fixture: $tool" >&2
                exit 127
            }
            [[ -x "$host_tool" ]] || {
                echo "host tool fixture is not executable: $tool" >&2
                exit 127
            }
            [[ ! -e "$MODDIR/bin/$tool" ]] || {
                echo "customize fixture collides with package binary: $tool" >&2
                exit 1
            }
            ln -s "$host_tool" "$MODDIR/bin/$tool"
        done
        for tool in chcon restorecon getevent am cmd settings chown; do
            [[ ! -e "$MODDIR/bin/$tool" ]] || {
                echo "customize fixture collides with package binary: $tool" >&2
                exit 1
            }
            ln -s "$MOCK_BIN/$tool" "$MODDIR/bin/$tool"
        done
    }

    remove_customize_fixtures() {
        rm -f "$MODDIR/bin"/{am,bash,chcon,chmod,chown,cmd,cp,cut,date,find,getevent,grep,ln,mkdir,restorecon,rm,sed,settings,sh,tr,unzip}
    }

    install_customize_fixtures
    export ZIPFILE="$ZIP_PATH"
    export MODPATH="$MODDIR"
    export MODDIR
    export BOOTMODE=true
    export MAGICNET_NONINTERACTIVE=1
    export TMPDIR="$TMP/tmp"
    mkdir -p "$TMPDIR" "$POISONED_CALLER_PATH"
    if ! "$HOST_ENV" -u LD_LIBRARY_PATH \
        ZIPFILE="$ZIP_PATH" \
        MODPATH="$MODDIR" \
        MODDIR="$MODDIR" \
        BOOTMODE=true \
        MAGICNET_NONINTERACTIVE=1 \
        TMPDIR="$TMPDIR" \
        PATH="$MODDIR/bin:$POISONED_CALLER_PATH" \
        "$MODDIR/bin/sh" "$MODDIR/customize.sh" >"$TMP/customize.log" 2>&1; then
        echo "customize.sh failed during fake Magisk zip smoke" >&2
        exit 1
    fi
    remove_customize_fixtures
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
MAGICNET_FAKE_SETTINGS_FILE="$TMP/settings-global"
cat >"$MOCK_BIN/settings" <<'SH'
#!/usr/bin/env bash
set -e
case "${1:-} ${2:-} ${3:-}" in
    "get global tether_offload_disabled")
        if [[ -f "${MAGICNET_FAKE_SETTINGS_FILE:?}" ]]; then
            cat "$MAGICNET_FAKE_SETTINGS_FILE"
        else
            printf '%s\n' null
        fi
        ;;
    "put global tether_offload_disabled")
        printf '%s\n' "${4:-}" >"${MAGICNET_FAKE_SETTINGS_FILE:?}"
        ;;
    "delete global tether_offload_disabled")
        rm -f "${MAGICNET_FAKE_SETTINGS_FILE:?}"
        ;;
esac
SH
chmod +x "$MOCK_BIN/settings"
mkdir -p "$MODDIR/bin"
cp "$CLI_BIN" "$MODDIR/bin/magicnet-cli"
cp "$MCP_BIN" "$MODDIR/bin/magicnet-mcp-server"
cp "$HOST_JQ" "$MODDIR/bin/jq"
rm -f "$MODDIR/cli"
ln -s "bin/magicnet-cli" "$MODDIR/cli"
chmod +x "$MODDIR/bin/magicnet-cli" "$MODDIR/bin/magicnet-mcp-server" "$MODDIR/bin/jq"

cat >>"$MODDIR/lib/kamfw/__singbox__.sh" <<'SH'

if [ -n "${MAGICNET_FAKE_LOG:-}" ]; then
    singbox_tun() {
        info "fake smoke skips host /dev/net/tun check"
    }
fi
SH
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
if [[ "${1:-}" == "-S" && "${2:-}" == "OUTPUT" ]]; then
    echo "-A OUTPUT -o lo -p udp --dport 53 -j REJECT"
    exit 0
fi
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
write_mock ecapture '
case "${1:-}" in
    --version|version) echo "eCapture fake 0.0.0"; exit 0 ;;
    tls|gotls|nspr) sleep 1; exit 0 ;;
esac
echo "eCapture fake 0.0.0"
exit 0
'
# shellcheck disable=SC2016
write_mock sing-box '
case "${1:-}" in
    version) echo "sing-box fake 0.0.0"; exit 0 ;;
    check)
        [[ "${MAGICNET_FAKE_SINGBOX_CHECK_FAIL:-0}" != 1 ]]
        exit 0
        ;;
    tools)
        if [[ "${2:-}" == "ebpf" && "${3:-}" == "status" ]]; then
            [[ "${MAGICNET_FAKE_EBPF_PROBE_FAIL:-0}" != 1 ]] || exit 1
            programs="[]"
            if [[ -s "${MODDIR:?}/.state/fake-sing-box.pid" ]] \
                && kill -0 "$(cat "$MODDIR/.state/fake-sing-box.pid")" 2>/dev/null; then
                programs="[{\"name\":\"sb_ebpf_conn4_\",\"type\":\"cgroup_sock_addr\"}]"
                if grep -Eq "\"mode\"[[:space:]]*:[[:space:]]*\"hybrid\"" "$MODDIR/.config/sing-box/config.json"; then
                    programs="[{\"name\":\"sb_ebpf_conn4_\",\"type\":\"cgroup_sock_addr\"},{\"name\":\"sb_share_ingres\",\"type\":\"sched_cls\"}]"
                fi
            fi
            printf "%s\n" "{\"available\":true,\"local\":{\"available\":true},\"shared_network\":{\"available\":true},\"active_programs\":${programs}}"
        fi
        exit 0
        ;;
    run)
        if [[ "${MAGICNET_FAKE_SINGBOX_START_FAIL:-0}" == 1 ]] \
            && grep -Eq "\"type\"[[:space:]]*:[[:space:]]*\"ebpf\"" "${3:-/dev/null}"; then
            exit 1
        fi
        mkdir -p "${MODDIR:?}/.state"
        echo "$$" >"$MODDIR/.state/fake-sing-box.pid"
        printf "%s" "sing-box" >/proc/$$/comm 2>/dev/null || true
        while :; do sleep 3600; done
        ;;
esac
exit 0
'
# shellcheck disable=SC2016
write_mock curl '
out=""
url=""
write_out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            out="${2:-}"
            shift 2
            ;;
        -w|--write-out)
            write_out="${2:-}"
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
render_http_metrics() {
    local code="$1"
    local connect="$2"
    local start="$3"
    local total="$4"
    local rendered="$write_out"
    rendered="${rendered//\%\{http_code\}/$code}"
    rendered="${rendered//\%\{time_connect\}/$connect}"
    rendered="${rendered//\%\{time_starttransfer\}/$start}"
    rendered="${rendered//\%\{time_total\}/$total}"
    printf "%b" "$rendered"
}
if [[ -n "${MAGICNET_FAKE_CURL_FAIL_URL:-}" && "$url" == "$MAGICNET_FAKE_CURL_FAIL_URL" ]]; then
    [[ -z "$write_out" ]] || render_http_metrics 000 0.000 0.000 0.000
    exit 7
fi
if [[ -n "${MAGICNET_FAKE_CURL_HTTP_CODE_URL:-}" && "$url" == "$MAGICNET_FAKE_CURL_HTTP_CODE_URL" ]]; then
    [[ -z "$write_out" ]] || render_http_metrics "${MAGICNET_FAKE_CURL_HTTP_CODE:-429}" 0.010 0.020 0.030
    exit 0
fi
case "$url" in
    http://127.0.0.1:9090/version)
        printf "%s\n" "{\"version\":\"fake\"}"
        exit 0
        ;;
    http://127.0.0.1:9090/providers/proxies*)
        printf "%s\n" "{\"providers\":{\"premium_a\":{\"proxies\":[{\"name\":\"fake-node\",\"type\":\"VMess\"}]}}}"
        exit 0
        ;;
    http://127.0.0.1:9090/proxies*)
        printf "%s\n" "{\"proxies\":{\"fake-node\":{\"name\":\"fake-node\",\"type\":\"VMess\"}},\"all\":[\"fake-node\"]}"
        exit 0
        ;;
    http://127.0.0.1:7892*|https://www.baidu.com|https://www.google.com|https://chatgpt.com)
        if [[ -n "$write_out" ]]; then
            render_http_metrics 200 0.010 0.020 0.030
        else
            printf "%s\n" "HTTP/1.1 200 OK"
        fi
        exit 0
        ;;
esac
emit_subscription_fixture() {
    cat <<YAML
proxies:
  - name: fresh-sub-node
    type: vmess
    server: 127.0.0.1
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    alterId: 0
    cipher: auto
YAML
    printf "%b" "    tls: true\n    servername: \"edge.example\r.test\"\n"
}
if [[ -n "$out" ]]; then
    if [[ "$out" == "-" ]]; then
        emit_subscription_fixture
    else
        emit_subscription_fixture >"$out"
    fi
    exit 0
fi
printf "%s\n" "{}"
'
# shellcheck disable=SC2016
write_mock getent '
if [[ "${1:-}" == "ahosts" && "${2:-}" == "example.invalid" ]]; then
    printf "%s\\n" "1.1.1.1 STREAM example.invalid"
    exit 0
fi
if [[ -n "${MAGICNET_FAKE_HOST_GETENT:-}" ]]; then
    exec "$MAGICNET_FAKE_HOST_GETENT" "$@"
fi
exit 127
'
export MAGICNET_FAKE_HOST_GETENT="$HOST_GETENT"
# shellcheck disable=SC2016
write_mock ss '
if [[ "${1:-}" == "-lnt" || "${1:-}" == "-lntp" ]]; then
    if [[ -s "${MODDIR:?}/.state/fake-sing-box.pid" ]]; then
        printf "%s\n" "LISTEN 0 4096 127.0.0.1:7892 0.0.0.0:*"
        printf "%s\n" "LISTEN 0 4096 127.0.0.1:9090 0.0.0.0:*"
    fi
fi
exit 0
'
# shellcheck disable=SC2016
write_mock killall '
signal=""
if [[ "${1:-}" == -* ]]; then
    signal="$1"
    shift || true
fi
name="${1:-}"
case "$name" in
    sing-box) pid_file="${MODDIR:?}/.state/fake-sing-box.pid" ;;
    *) exit 0 ;;
esac
if [[ -s "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if [[ -n "$signal" ]]; then
        kill "$signal" "$pid" 2>/dev/null || true
    else
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
fi
exit 0
'
cp "$MOCK_BIN/sing-box" "$MODDIR/bin/sing-box"
cp "$MOCK_BIN/ecapture" "$MODDIR/bin/ecapture"
cp "$MOCK_BIN/curl" "$MODDIR/bin/curl"
cp "$MOCK_BIN/ss" "$MODDIR/bin/ss"
cp "$MOCK_BIN/killall" "$MODDIR/bin/killall"

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
esac
exit 1
SH
chmod +x "$MOCK_BIN/pidof"
cp "$MOCK_BIN/pidof" "$MODDIR/bin/pidof"

# Keep the fake subscription refresh deterministic after the production
# fetcher moved DNS resolution into magicnet-cli. All normal CLI commands still
# execute the host-built binary; only the reserved example.invalid fixture is
# resolved locally for this smoke test.
cat >"$MODDIR/bin/magicnet-cli-smoke" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "sub" && "${2:-}" == "resolve-host" && "${3:-}" == "example.invalid" ]]; then
    printf '%s\n' "magicnet-cli resolve-host ${3:-} ${4:-}" >>"${MAGICNET_FAKE_LOG:?}"
    printf '%s\n' "1.1.1.1"
    exit 0
fi
module_dir="${MODDIR:-}"
if [[ -z "$module_dir" ]]; then
    case "$0" in
        */cli) module_dir="${0%/*}" ;;
        */bin/*) module_dir="${0%/bin/*}" ;;
        *) echo "cannot locate fake MagicNet module root" >&2; exit 1 ;;
    esac
fi
exec "$module_dir/bin/magicnet-cli" "$@"
SH
chmod +x "$MODDIR/bin/magicnet-cli-smoke"
rm -f "$MODDIR/cli"
ln -s "bin/magicnet-cli-smoke" "$MODDIR/cli"

install_runtime_path_fixtures() {
    local applet host_applet mock
    local applets=(
        awk basename bash cat chmod cksum cp cut date dirname env false find flock grep head id
        kill ln ls mkdir mkfifo mv nohup printf ps pwd readlink realpath rm sed sh sleep sort
        tail timeout touch tr true uname wc whoami xargs
    )
    local mocks=(
        am chcon chown cmd getent getevent getprop ip ip6tables ipset iptables
        magiskpolicy ndc pkill pm resetprop restorecon setprop settings su svc
    )

    for applet in "${applets[@]}"; do
        # `command -v` resolves shell builtins such as true and false to their
        # names, not executable paths. Fixtures must always link to a host
        # executable because the runtime PATH is deliberately module-only.
        host_applet="$(PATH="$ORIGINAL_PATH" type -P -- "$applet" || true)"
        if [[ -z "$host_applet" || ! -x "$host_applet" ]]; then
            echo "runtime fixture is missing required host applet: $applet" >&2
            exit 127
        fi
        if [[ -e "$MODDIR/bin/$applet" || -L "$MODDIR/bin/$applet" ]]; then
            echo "runtime fixture collides with package binary: $applet" >&2
            exit 1
        fi
        ln -s "$host_applet" "$MODDIR/bin/$applet"
    done

    for mock in "${mocks[@]}"; do
        [[ -x "$MOCK_BIN/$mock" ]] || continue
        if [[ -e "$MODDIR/bin/$mock" || -L "$MODDIR/bin/$mock" ]]; then
            echo "runtime mock fixture collides with package binary: $mock" >&2
            exit 1
        fi
        ln -s "$MOCK_BIN/$mock" "$MODDIR/bin/$mock"
    done
}

install_runtime_path_fixtures

"$HOST_JQ" '.outbounds += [{"type":"vmess","tag":"old-cached-node","server":"127.0.0.1","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000","security":"auto"}]' \
    "$MODDIR/.config/sing-box/config.json" >"$TMP/sing-box-config.json"
mv "$TMP/sing-box-config.json" "$MODDIR/.config/sing-box/config.json"

export MODDIR
export MODPATH="$MODDIR"
export BOOTMODE=true
export KAM_LANG=en
export MAGICNET_FAKE_LOG="$MOCK_LOG"
export MAGICNET_FAKE_SETTINGS_FILE
export MAGICNET_NOTIFY_ENABLED=0
export MAGICNET_WATCHDOG_ENABLED=0
export MAGICNET_FSWATCH_ENABLED=0
export MAGICNET_CONFIG_LOCK_TIMEOUT=2
export MAGIC_HOTSPOT_IFACES="ap0"
export MAGIC_VPN_COEXIST_IFACES="tun0"
export MAGIC_TUN_IFACES="magicnet0"
export PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH"
# The host-only CLI test runner keeps its command doubles out of the
# production trusted PATH and opts into them explicitly here.
export MAGICNET_TEST_PATH="$PATH"

run() {
    echo "+ $*"
    "$@"
}

stop_fake_core_processes() {
    local name="$1"
    local comm pid cmdline
    for comm in /proc/[0-9]*/comm; do
        [[ -r "$comm" ]] || continue
        [[ "$(cat "$comm" 2>/dev/null || true)" == "$name" ]] || continue
        pid="${comm#/proc/}"
        pid="${pid%/comm}"
        cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
        case "$cmdline" in
        *"$TMP"* | *"$MODDIR"*)
            kill "$pid" 2>/dev/null || true
            ;;
        esac
    done
}

count_exact_script_processes() {
    local expected="$1"
    local cmdline arg count=0
    local -a argv
    for cmdline in /proc/[0-9]*/cmdline; do
        [[ -r "$cmdline" ]] || continue
        argv=()
        while IFS= read -r -d '' arg; do
            argv+=("$arg")
        done <"$cmdline"
        if [[ "${#argv[@]}" -eq 2 && "${argv[0]##*/}" == "sh" && "${argv[1]}" == "$expected" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

generated_fswatch_prune_names() {
    local loop_file="$1"
    local assignment value
    assignment="$(sed -n 's/^KAM_FSWATCH_PRUNE_NAMES=//p' "$loop_file")"
    [[ "$assignment" == \'*\' ]] || return 1
    value="${assignment#\'}"
    value="${value%\'}"
    printf '%s\n' "$value"
}

fswatch_changed_with_prune_names() {
    local prune_names="$1"
    local watch_path="$2"
    local snapshot_file="$3"
    KAM_FSWATCH_PRUNE_NAMES="$prune_names" sh -c '
        . "$MODDIR/lib/kamfw/.kamfwrc"
        import fswatch
        fswatch changed "$1" "$2"
    ' fswatch-test "$watch_path" "$snapshot_file"
}

stop_fake_core() {
    local pid_file="$1"
    local name="$2"
    stop_fake_core_processes "$name"
    if [[ -s "$pid_file" ]]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
    fi
}

start_fake_core() {
    # Use the same fake binary as production startup so the strict sing-box
    # ownership check sees a process whose /proc comm is actually sing-box.
    "$MODDIR/bin/sing-box" run -c "$MODDIR/.config/sing-box/config.json" \
        -D "$MODDIR/.config/sing-box" >/dev/null 2>&1 &
    local pid="$!"
    for _wait_fake_core in {1..20}; do
        [[ -s "$MODDIR/.state/fake-sing-box.pid" ]] && break
        sleep 0.05
    done
    [[ -s "$MODDIR/.state/fake-sing-box.pid" ]] || {
        kill "$pid" 2>/dev/null || true
        return 1
    }
}

assert_dns_cleanup_log() {
    local log_file="$1"
    rg -q '^iptables -t nat -D OUTPUT -j magicnet-dns-output$' "$log_file"
    rg -q '^iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT$' "$log_file"
}

assert_dns_interception_not_enabled() {
    local log_file="$1"
    local context="$2"
    if rg -q '^iptables -t nat -A magicnet-dns-output .*--dport 53 .*REDIRECT --to-ports 1053$' "$log_file"; then
        echo "$context enabled DNS capture without a listener" >&2
        exit 1
    fi
    if rg -q '^iptables -I OUTPUT -o lo .*--dport (53|853) -j REJECT$' "$log_file"; then
        echo "$context enabled DNS leak guard without a core" >&2
        exit 1
    fi
}

run sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import self
    config set override.description "fake smoke config"
    test "$(config get override.description)" = "fake smoke config"
    test -f "$MODDIR/.state/kamfw-config/${MODDIR##*/}/persist/override.description"
'

# Production startup intentionally refuses to launch without a configured
# subscription. Seed the fake subscription before the first lifecycle entrypoint.
printf '%s\n' 'https://example.invalid/subscription.yaml' >"$MODDIR/.config/sing-box/subscription.url"

run sh "$MODDIR/service.sh"
run sh "$MODDIR/boot-completed.sh"
hotspot_policy_ready() {
    "$HOST_JQ" -e '
    ([.outbounds[] | select(.tag == "hotspot")] | length == 1)
    and ([.outbounds[] | select(.tag == "hotspot")][0]
      | .type == "selector"
      and .outbounds == ["direct", "proxy"]
      and .default == "direct"
      and ((has("interrupt_exist_connections") | not) or .interrupt_exist_connections == true)
    )
    and ([.route.rules[] | select(
      .inbound == ["tun-in"]
      and .outbound == "hotspot"
    )] | length == 0)
    ' "$MODDIR/.config/sing-box/config.json" >/dev/null
}
for _wait_hotspot_policy in {1..20}; do
    hotspot_policy_ready && break
    sleep 1
done
unset _wait_hotspot_policy
if ! hotspot_policy_ready; then
    echo "hotspot selector or managed route did not converge after startup" >&2
    "$HOST_JQ" '{
      hotspot_selectors: [.outbounds[]? | select(.tag == "hotspot")],
      hotspot_routes: [.route.rules[]? | select((.outbound // "") == "hotspot")]
    }' "$MODDIR/.config/sing-box/config.json" >&2
    exit 1
fi

count_singbox_runs() {
    rg -c '^sing-box run ' "$MOCK_LOG" 2>/dev/null || true
}

network_set_runs_before="$(count_singbox_runs)"
run "$MODDIR/cli" network set prefer_ipv4 1500 3m >"$TMP/network-set.log"
network_set_runs_after="$(count_singbox_runs)"
if [[ "$network_set_runs_after" -le "$network_set_runs_before" ]]; then
    echo "network set reported success without restarting the running sing-box core" >&2
    cat "$TMP/network-set.log" >&2
    exit 1
fi
"$HOST_JQ" -e '
    [.inbounds[] | select(.tag == "tun-in")][0]
    | .mtu == 1500 and .udp_timeout == "3m"
    ' "$MODDIR/.config/sing-box/config.json" >/dev/null

dns_apply_runs_before="$(count_singbox_runs)"
run "$MODDIR/cli" dns apply >/dev/null
dns_apply_runs_after="$(count_singbox_runs)"
if [[ "$dns_apply_runs_after" -le "$dns_apply_runs_before" ]]; then
    echo "dns apply reported success without restarting the running sing-box core" >&2
    exit 1
fi

transparent_apply_runs_before="$(count_singbox_runs)"
run "$MODDIR/cli" transparent apply >/dev/null
transparent_apply_runs_after="$(count_singbox_runs)"
if [[ "$transparent_apply_runs_after" -le "$transparent_apply_runs_before" ]]; then
    echo "transparent apply reported success without restarting the running sing-box core" >&2
    exit 1
fi

run "$MODDIR/cli" hotspot status >"$TMP/hotspot-direct.log"
rg -q '^enabled=0$' "$TMP/hotspot-direct.log"
rg -q '^outbound=direct$' "$TMP/hotspot-direct.log"
rg -q '^offload_disabled=0$' "$TMP/hotspot-direct.log"
run "$MODDIR/cli" hotspot enable
run "$MODDIR/cli" hotspot status >"$TMP/hotspot-proxy.log"
rg -q '^enabled=1$' "$TMP/hotspot-proxy.log"
rg -q '^outbound=proxy$' "$TMP/hotspot-proxy.log"
rg -q '^offload_disabled=1$' "$TMP/hotspot-proxy.log"
rg -q '^offload_owned=1$' "$TMP/hotspot-proxy.log"
run "$MODDIR/cli" hotspot disable
run "$MODDIR/cli" hotspot status >"$TMP/hotspot-restored.log"
rg -q '^offload_disabled=0$' "$TMP/hotspot-restored.log"
rg -q '^offload_owned=0$' "$TMP/hotspot-restored.log"
test ! -e "$MAGICNET_FAKE_SETTINGS_FILE"

env -u MODDIR -u MODPATH \
    KAM_LANG="$KAM_LANG" \
    MAGICNET_FAKE_LOG="$MOCK_LOG" \
    MAGICNET_NOTIFY_ENABLED=0 \
    PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/bin/magicnet-cli" diagnose >"$TMP/cli-autodetect-diagnose.log" 2>&1
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
    command -v sing-box
' >"$TMP/runtime-path.log"
rg -q "^$MODDIR/bin/sing-box$" "$TMP/runtime-path.log"
test -x "$MODDIR/bin/magicnet-mcp-server"
test -x "$MODDIR/bin/ecapture"

MCP_TEST_PORT="$(
    python3 - <<'PY'
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
MCP_TEST_SECRET="$(env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp secret)"
MODDIR="$MODDIR" MCP_TEST_PORT="$MCP_TEST_PORT" MCP_TEST_SECRET="$MCP_TEST_SECRET" python3 - <<'PY'
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
        + f"Authorization: Bearer {os.environ['MCP_TEST_SECRET']}\r\n".encode()
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
run env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" sh "$MODDIR/service.sh"
sleep 6
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" mcp status >"$TMP/mcp-service-start.log"
rg -q '^enabled=1$' "$TMP/mcp-service-start.log"
rg -q "^port=$MCP_TEST_PORT$" "$TMP/mcp-service-start.log"
rg -q '^pid=[0-9]+$' "$TMP/mcp-service-start.log"

run "$MODDIR/cli" service status
run "$MODDIR/cli" core status
run "$MODDIR/cli" core select sing-box
run "$MODDIR/cli" core status
grep -qx 'MAGICNET_DEFAULT_CORE=sing-box' "$MODDIR/.config/magicnet/current-core.conf"
# shellcheck disable=SC2016
env MAGICNET_DEFAULT_CORE=sing-box MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    printf "%s\n" "sing-box"
' >"$TMP/default-core.log"
grep -qx 'sing-box' "$TMP/default-core.log"

mkdir -p "$MODDIR/.state/sing-box/subscription-work"
# shellcheck disable=SC2016
"$HOST_JQ" -r '
    (.outbounds | walk(if . == "fresh-sub-node" then "old-cached-node" else . end)) as $outbounds
    | "  \"outbounds\": " + ($outbounds | tojson) + ","
' \
    "$MODDIR/.config/sing-box/config.json" \
    >"$MODDIR/.state/sing-box/subscription-work/outbounds.json"
rg -q '"tag":"old-cached-node"' "$MODDIR/.state/sing-box/subscription-work/outbounds.json"
"$HOST_JQ" '
    .outbounds |= map(select(
        (.type == "vmess"
         or .type == "vless"
         or .type == "trojan"
         or .type == "shadowsocks"
         or .type == "hysteria2") | not
    ))
    | .outbounds |= map(select(.tag != "ai-chatgpt" and .tag != "ai-gemini" and .tag != "ai-grok" and .tag != "ai-claude"))
    | .outbounds += [{"type":"vmess","tag":"stale-device-node","server":"127.0.0.2","server_port":443,"uuid":"00000000-0000-0000-0000-000000000002","security":"auto"}]
' "$MODDIR/.config/sing-box/config.json" >"$TMP/base-sing-box-config.json"
mv "$TMP/base-sing-box-config.json" "$MODDIR/.config/sing-box/config.json"
"$HOST_JQ" -e '[.outbounds[] | select(.type == "selector")] | length > 0' \
    "$MODDIR/.config/sing-box/config.json" >/dev/null
if "$HOST_JQ" -e '.outbounds[] | select(.tag == "old-cached-node")' \
    "$MODDIR/.config/sing-box/config.json" >/dev/null; then
    echo "sing-box cache replay fixture still has a runtime node" >&2
    exit 1
fi
# Detached startup supervisors may still be reconciling the initial fixture.
# Quiesce them before deterministic stopped-core runtime assertions.
run "$MODDIR/cli" supervisor stop all
config_lock_ready=0
for ((attempt = 0; attempt < 100; attempt++)); do
    if flock -n "$MODDIR/.state/config-apply.lock" true; then
        config_lock_ready=1
        break
    fi
    sleep 0.1
done
if [[ "$config_lock_ready" -ne 1 ]]; then
    echo "startup config reconciliation did not release its lock" >&2
    exit 1
fi
stop_fake_core "$MODDIR/.state/fake-sing-box.pid" "sing-box"
: >"$MOCK_LOG"
# shellcheck disable=SC2016
run env MAGIC_DNS_LEAK_GUARD=1 MAGIC_DNS_GUARD_IFACES=lo sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    magicnet_apply_runtime_config
'
assert_dns_cleanup_log "$MOCK_LOG"
assert_dns_interception_not_enabled "$MOCK_LOG" "stopped runtime config"
: >"$MOCK_LOG"
# shellcheck disable=SC2016
run env MAGIC_DNS_GUARD_IFACES=lo sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    magicnet_start_kernel
'
python3 - "$MOCK_LOG" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
capture = next((i for i, line in enumerate(lines) if line == "iptables -t nat -D OUTPUT -j magicnet-dns-output"), None)
guard = next((i for i, line in enumerate(lines) if line == "iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT"), None)
run = next((i for i, line in enumerate(lines) if line.startswith("sing-box run")), None)
if capture is None or guard is None or run is None or capture > run or guard > run:
    raise SystemExit("kernel bootstrap did not clear DNS interception before starting sing-box")
PY
stop_fake_core "$MODDIR/.state/fake-sing-box.pid" "sing-box"
start_fake_core
: >"$MOCK_LOG"
# shellcheck disable=SC2016
run env MAGIC_DNS_GUARD_IFACES=lo sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    magicnet_action_toggle_singbox
'
assert_dns_cleanup_log "$MOCK_LOG"
assert_dns_interception_not_enabled "$MOCK_LOG" "toggle stop"
start_fake_core
: >"$MOCK_LOG"
# A deferred config rewrite can fail after sing-box is already running. DNS
# interception must stay disabled until every managed rewrite succeeds.
# shellcheck disable=SC2016
if run env MAGIC_DNS_GUARD_IFACES=lo sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    magicnet_enable_dns_capture() {
        return 1
    }
    magicnet_after_kernel_start_deferred_unlocked
'; then
    echo "deferred config failure was reported as success" >&2
    exit 1
fi
assert_dns_interception_not_enabled "$MOCK_LOG" "deferred config failure"

: >"$MOCK_LOG"
run env MAGIC_DNS_GUARD_IFACES=lo "$MODDIR/cli" service stop
assert_dns_cleanup_log "$MOCK_LOG"
: >"$MOCK_LOG"
# shellcheck disable=SC2016
if env MAGIC_SINGBOX=0 MAGIC_DNS_GUARD_IFACES=lo sh -c '
    . "$MODDIR/lib/kamfw/.kamfwrc"
    import __runtime__
    . "$MODDIR/lib/magicnet.sh"
    magicnet_action_toggle_singbox
'; then
    echo "toggle start reported success while sing-box was disabled" >&2
    exit 1
fi
assert_dns_cleanup_log "$MOCK_LOG"
assert_dns_interception_not_enabled "$MOCK_LOG" "failed toggle start"
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
rg -q '^  sing-box: [0-9][0-9,]*$' "$TMP/singbox-service-status.log"
"$HOST_JQ" -e '.outbounds[] | select(.tag == "old-cached-node")' "$MODDIR/.config/sing-box/config.json" >/dev/null
if "$HOST_JQ" -e '.outbounds[] | select(.tag == "stale-device-node")' "$MODDIR/.config/sing-box/config.json" >/dev/null; then
    echo "sing-box startup accepted a legacy config with missing AI selectors" >&2
    exit 1
fi
# shellcheck disable=SC2016
"$HOST_JQ" -e '
    [
      {name: "ai-chatgpt", url: "https://chatgpt.com/"},
      {name: "ai-gemini", url: "https://gemini.google.com/"},
      {name: "ai-grok", url: "https://grok.com/"},
      {name: "ai-claude", url: "https://claude.ai/"}
    ] as $services
    | [.outbounds[]
        | select(.type == "shadowsocks" or .type == "vmess" or .type == "vless" or .type == "trojan"
            or .type == "hysteria2" or .type == "anytls" or .type == "tuic")
        | .tag] as $node_tags
    | (.outbounds | INDEX(.tag)) as $by_tag
    | [.outbounds[] | select(.tag == "proxy-auto")] as $proxy_auto
    | $by_tag["ai-proxy"] as $ai_proxy
    | (if ($node_tags | length) > 0 then
        $proxy_auto == [{
          type: "urltest", tag: "proxy-auto", outbounds: $node_tags,
          url: "https://www.gstatic.com/generate_204", interval: "3m", tolerance: 30,
          idle_timeout: "10m", interrupt_exist_connections: false
        }]
          and $by_tag.proxy.type == "selector"
          and $by_tag.proxy.outbounds == ($node_tags + ["proxy-auto", "direct", "block"])
          and $by_tag.proxy.default == $node_tags[0]
      else
        ($proxy_auto | length) == 0
          and $by_tag.proxy.type == "selector"
          and $by_tag.proxy.outbounds == ["block"]
          and $by_tag.proxy.default == "block"
      end)
      and ([.outbounds[] | select(.type == "selector")] | all(. as $selector
        | if $selector.tag == "network-test" then
            $selector.default == "proxy-auto"
              and $selector.outbounds == ["proxy-auto", "proxy", "direct", "block"]
          else
            (($by_tag[$selector.default].type // "") != "urltest")
              and (if ($selector.outbounds | any(. as $member | ($by_tag[$member].type // "") == "urltest"))
                then ($node_tags | index($selector.default)) != null
                else true
                end)
          end))
      and ($services | all(. as $service
      | ($service.name + "-auto") as $auto
      | $by_tag[$service.name].type == "selector"
        and $by_tag[$service.name].default == $ai_proxy.outbounds[0]
        and $by_tag[$service.name].outbounds == ($ai_proxy.outbounds + ["block", $auto])
        and $by_tag[$auto].type == "urltest"
        and $by_tag[$auto].outbounds == $ai_proxy.outbounds
        and $by_tag[$auto].url == $service.url
        and $by_tag[$auto].interval == "10m"
        and $by_tag[$auto].tolerance == 30
        and $by_tag[$auto].idle_timeout == "10m"
        and $by_tag[$auto].interrupt_exist_connections == false
    ))
' "$MODDIR/.config/sing-box/config.json" >/dev/null
if "$HOST_JQ" -e '.outbounds[] | select(.tag == "fresh-sub-node")' "$MODDIR/.config/sing-box/config.json" >/dev/null; then
    echo "sing-box startup refreshed subscription instead of using cached config" >&2
    exit 1
fi
if rg -q '^curl .*subscription\.yaml' "$MOCK_LOG"; then
    echo "sing-box default startup fetched subscription before launching the core" >&2
    exit 1
fi
python3 - "$MOCK_LOG" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
run = next((i for i, line in enumerate(lines) if line.startswith("sing-box run")), None)
if run is None:
    raise SystemExit("sing-box was not started")
PY
stop_fake_core "$MODDIR/.state/fake-sing-box.pid" "sing-box"
: >"$MOCK_LOG"
run env \
    MAGICNET_FORCE_SUB_REFRESH=1 \
    MAGICNET_WATCHDOG_ENABLED=0 \
    MAGICNET_FSWATCH_ENABLED=0 \
    MAGICNET_NOTIFY_ENABLED=0 \
    MODDIR="$MODDIR" \
    MODPATH="$MODDIR" \
    PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" service restart sing-box
sleep 1
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" service status >"$TMP/singbox-forced-refresh-status.log"
rg -q '^  sing-box: [0-9][0-9,]*$' "$TMP/singbox-forced-refresh-status.log"
"$HOST_JQ" -e '.outbounds[] | select(.tag == "fresh-sub-node")' "$MODDIR/.config/sing-box/config.json" >/dev/null
python3 - "$MODDIR/.config/sing-box/config.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

def walk(value, path="$"):
    if isinstance(value, str):
        bad = [ch for ch in value if ord(ch) < 32]
        if bad:
            raise SystemExit(f"control character in {path}: {value!r}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            walk(item, f"{path}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            walk(item, f"{path}.{key}")

walk(data)
PY
if "$HOST_JQ" -e '.outbounds[] | select(.tag == "old-cached-node")' "$MODDIR/.config/sing-box/config.json" >/dev/null; then
    echo "sing-box forced refresh used cached nodes instead of fresh subscription" >&2
    exit 1
fi
python3 - "$MOCK_LOG" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
resolve = next((i for i, line in enumerate(lines) if line == "magicnet-cli resolve-host example.invalid 443"), None)
fetch = next((i for i, line in enumerate(lines) if line.startswith("curl ") and "subscription.yaml" in line), None)
run = next((i for i, line in enumerate(lines) if line.startswith("sing-box run")), None)
if resolve is None or fetch is None or run is None or resolve > fetch or fetch > run:
    raise SystemExit("forced refresh started sing-box before fetching the subscription")
PY
stop_fake_core "$MODDIR/.state/fake-sing-box.pid" "sing-box"
start_fake_core
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
rg -q '^fswatch=[0-9]+$' "$TMP/supervisor-status.log"
test -s "$MODDIR/.state/fswatch/magicnet-config.pid"
rg -q 'config apply' "$MODDIR/.state/fswatch/magicnet-config.loop.sh"
rg -q 'fswatch_changed' "$MODDIR/.state/fswatch/magicnet-config.loop.sh"
_fswatch_pid_file="$MODDIR/.state/fswatch/magicnet-config.pid"
_fswatch_loop_file="$MODDIR/.state/fswatch/magicnet-config.loop.sh"
_fswatch_first_pid="$(sed -n '1p' "$_fswatch_pid_file")"
kill -0 "$_fswatch_first_pid"
test "$(count_exact_script_processes "$_fswatch_loop_file")" -eq 1
_fswatch_snapshot_file="$MODDIR/.state/fswatch/magicnet-config.snapshot"
_fswatch_expected_prune_names="ui zashboard cache.db cache.db-wal cache.db-shm cache.db-journal"
_fswatch_prune_names="$(generated_fswatch_prune_names "$_fswatch_loop_file")"
for _fswatch_cache_name in cache.db cache.db-wal cache.db-shm cache.db-journal; do
    printf 'runtime-cache\n' >"$MODDIR/.config/sing-box/$_fswatch_cache_name"
    if fswatch_changed_with_prune_names "$_fswatch_prune_names" "$MODDIR/.config" "$_fswatch_snapshot_file"; then
        echo "fswatch detected ignored sing-box runtime cache: $_fswatch_cache_name" >&2
        exit 1
    fi
done
if [[ "$_fswatch_prune_names" != "$_fswatch_expected_prune_names" ]]; then
    echo "unexpected generated fswatch prune names: $_fswatch_prune_names" >&2
    exit 1
fi
printf 'watched-near-match\n' >"$MODDIR/.config/sing-box/not-cache.db"
if ! fswatch_changed_with_prune_names "$_fswatch_prune_names" "$MODDIR/.config" "$_fswatch_snapshot_file"; then
    echo "fswatch ignored non-exact cache basename: not-cache.db" >&2
    exit 1
fi
printf 'watched-config\n' >"$MODDIR/.config/magicnet/fswatch-real-change.conf"
if ! fswatch_changed_with_prune_names "$_fswatch_prune_names" "$MODDIR/.config" "$_fswatch_snapshot_file"; then
    echo "fswatch ignored a real config file change" >&2
    exit 1
fi
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
_fswatch_second_pid="$(sed -n '1p' "$_fswatch_pid_file")"
if [[ "$_fswatch_second_pid" != "$_fswatch_first_pid" ]]; then
    echo "repeated supervisor start all replaced healthy fswatch PID: $_fswatch_first_pid -> $_fswatch_second_pid" >&2
    exit 1
fi
kill -0 "$_fswatch_second_pid"
test "$(count_exact_script_processes "$_fswatch_loop_file")" -eq 1
run env \
    MAGICNET_FSWATCH_ENABLED=1 \
    MAGICNET_FSWATCH_INTERVAL=3600 \
    MAGICNET_NOTIFY_ENABLED=0 \
    MODDIR="$MODDIR" \
    MODPATH="$MODDIR" \
    PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" supervisor restart fswatch
sleep 1
_fswatch_restarted_pid="$(sed -n '1p' "$_fswatch_pid_file")"
if [[ "$_fswatch_restarted_pid" == "$_fswatch_second_pid" ]]; then
    echo "explicit supervisor restart fswatch preserved old PID: $_fswatch_restarted_pid" >&2
    exit 1
fi
kill -0 "$_fswatch_restarted_pid"
test "$(count_exact_script_processes "$_fswatch_loop_file")" -eq 1
unset _fswatch_pid_file _fswatch_loop_file _fswatch_first_pid _fswatch_second_pid _fswatch_restarted_pid
unset _fswatch_snapshot_file _fswatch_expected_prune_names _fswatch_prune_names _fswatch_cache_name
mkdir -p "$MODDIR/.state/sing-box/subscription-update.lock"
printf '999999:0:dead\n' >"$MODDIR/.state/sing-box/subscription-update.lock/owner"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" config apply
test ! -d "$MODDIR/.state/sing-box/subscription-update.lock"
cp "$MODDIR/.config/sing-box/config.json" "$TMP/config-apply-first.json"
# shellcheck disable=SC2016
if ! env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    sh -c '. "$MODDIR/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODDIR/lib/magicnet.sh"; magicnet_singbox_runtime_fingerprint_matches'; then
    echo "first config apply left a stale sing-box runtime fingerprint" >&2
    echo "stored: $(cat "$MODDIR/.state/sing-box/runtime-fingerprint" 2>/dev/null || echo missing)" >&2
    # shellcheck disable=SC2016
    env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
        sh -c '. "$MODDIR/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODDIR/lib/magicnet.sh"; printf "current: "; magicnet_singbox_runtime_fingerprint' >&2 || true
    exit 1
fi
# shellcheck disable=SC2016
run env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    sh -c '. "$MODDIR/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODDIR/lib/magicnet.sh"; magicnet_apply_runtime_config'
# shellcheck disable=SC2016
if ! env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    sh -c '. "$MODDIR/lib/kamfw/.kamfwrc"; import __runtime__; . "$MODDIR/lib/magicnet.sh"; magicnet_singbox_runtime_fingerprint_matches'; then
    echo "runtime materialization changed the running sing-box inputs:" >&2
    diff -u \
        <("$HOST_JQ" -S . "$TMP/config-apply-first.json") \
        <("$HOST_JQ" -S . "$MODDIR/.config/sing-box/config.json") >&2 || true
    exit 1
fi
config_apply_runs_before="$(count_singbox_runs)"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" config apply
config_apply_runs_after="$(count_singbox_runs)"
if [[ "$config_apply_runs_after" -ne "$config_apply_runs_before" ]]; then
    echo "effective sing-box config changed across consecutive config apply calls:" >&2
    diff -u \
        <("$HOST_JQ" -S . "$TMP/config-apply-first.json") \
        <("$HOST_JQ" -S . "$MODDIR/.config/sing-box/config.json") >&2 || true
    echo "unchanged config apply restarted the running sing-box core" >&2
    exit 1
fi
unset config_apply_runs_before config_apply_runs_after
mkdir -p "$MODDIR/.state/sing-box/subscription-update.lock"
_live_start=$(awk '{print $22}' "/proc/$$/stat")
printf '%s:%s:live\n' "$$" "$_live_start" >"$MODDIR/.state/sing-box/subscription-update.lock/owner"
if env MODDIR="$MODDIR" MODPATH="$MODDIR" PATH="$MOCK_BIN:$TOYBOX_APPLET_BIN:$MODDIR/bin:$ORIGINAL_PATH" \
    "$MODDIR/cli" config apply >/dev/null 2>&1; then
    echo "config apply ignored a live subscription update owner" >&2
    exit 1
fi
test -d "$MODDIR/.state/sing-box/subscription-update.lock"
rm -rf "$MODDIR/.state/sing-box/subscription-update.lock"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor stop all
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor status all >"$TMP/supervisor-stopped.log"
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
for _wait_supervisor in {1..20}; do
    env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor status all >"$TMP/supervisor-phase-status.log"
    if rg -q '^fswatch=[0-9]+$' "$TMP/supervisor-phase-status.log"; then
        break
    fi
    sleep 1
done
unset _wait_supervisor
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor status all >"$TMP/supervisor-phase-status.log"
rg -q '^fswatch=[0-9]+$' "$TMP/supervisor-phase-status.log"
run env MODDIR="$MODDIR" MODPATH="$MODDIR" "$MODDIR/cli" supervisor stop all

run "$MODDIR/cli" transparent status
run "$MODDIR/cli" config-editor validate sing-box
run "$MODDIR/cli" config apply
run "$MODDIR/cli" sub list
run "$MODDIR/cli" route list
run "$MODDIR/cli" block list
run "$MODDIR/cli" app list
run "$MODDIR/cli" backup export
: >"$MOCK_LOG"
run "$MODDIR/cli" diagnose >"$TMP/diagnose.log"
for _diag_name in Baidu Google ChatGPT; do
    rg -q "${_diag_name}.*HTTP 200 connect=0.010 start=0.020 total=0.030" "$TMP/diagnose.log"
done
python3 - "$MOCK_LOG" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
baidu = [line for line in lines if line.startswith("curl ") and line.endswith(" https://www.baidu.com")]
google = [line for line in lines if line.startswith("curl ") and line.endswith(" https://www.google.com")]
chatgpt = [line for line in lines if line.startswith("curl ") and line.endswith(" https://chatgpt.com")]
if len(baidu) != 1 or " -x " in baidu[0]:
    raise SystemExit("Baidu diagnostic did not use direct curl")
for name, calls in (("Google", google), ("ChatGPT", chatgpt)):
    if len(calls) != 1 or " -x http://127.0.0.1:7892 " not in calls[0]:
        raise SystemExit(f"{name} diagnostic did not use the explicit proxy")
for name, calls in (("Baidu", baidu), ("Google", google), ("ChatGPT", chatgpt)):
    if " -o /dev/null --connect-timeout 5 --max-time 10 -w " not in calls[0]:
        raise SystemExit(f"{name} diagnostic did not use bounded write-out curl")
PY
run env MAGICNET_FAKE_CURL_HTTP_CODE_URL="https://www.google.com" MAGICNET_FAKE_CURL_HTTP_CODE=429 \
    "$MODDIR/cli" diagnose >"$TMP/diagnose-http-error.log"
test "$(rg -c 'Google.*HTTP 429 connect=0.010 start=0.020 total=0.030' "$TMP/diagnose-http-error.log")" -eq 1
if rg -q 'Google.*HTTP 429.*rc=' "$TMP/diagnose-http-error.log"; then
    echo "HTTP 4xx diagnostic was reported as a transport failure" >&2
    exit 1
fi
run env MAGICNET_FAKE_CURL_FAIL_URL="https://www.google.com" "$MODDIR/cli" diagnose >"$TMP/diagnose-transport-failure.log"
test "$(rg -c 'Google.*HTTP 000 connect=0.000 start=0.000 total=0.000 rc=7' "$TMP/diagnose-transport-failure.log")" -eq 1
unset _diag_name

assert_transparent_mode() {
    local mode="$1"
    local before_marker after_marker

    before_marker="$(wc -l <"$MOCK_LOG")"
    # shellcheck disable=SC2016
    run env MAGICNET_TEST_MODE="$mode" sh -c '
        . "$MODDIR/lib/kamfw/.kamfwrc"
        import __runtime__
        . "$MODDIR/lib/magicnet.sh"
        mkdir -p "$MODDIR/.config/magicnet"
        magicnet_transparent_set_mode "$MAGICNET_TEST_MODE"
        magicnet_transparent_apply
    '
    after_marker="$(wc -l <"$MOCK_LOG")"
    sed -n "$((before_marker + 1)),${after_marker}p" "$MOCK_LOG" >"$TMP/${mode}-commands.log"

    "$MODDIR/cli" transparent status | tee "$TMP/${mode}-transparent-status.log"
    rg -qx "mode=${mode}" "$TMP/${mode}-transparent-status.log"

    python3 - "$MODDIR/.config/sing-box/config.json" "$mode" <<'PY'
import json
import pathlib
import sys

singbox_path = sys.argv[1]
mode = sys.argv[2]
singbox = json.loads(pathlib.Path(singbox_path).read_text())

inbound_types = [inbound.get("type") for inbound in singbox.get("inbounds", [])]
inbound_tags = [inbound.get("tag") for inbound in singbox.get("inbounds", [])]
sniff_rule = next((rule for rule in singbox.get("route", {}).get("rules", []) if rule.get("action") == "sniff"), None)
legacy_inbound_fields = {"sniff", "sniff_timeout", "domain_strategy"}

if inbound_tags.count("mixed-in") != 1:
    raise SystemExit(f"mixed-in inbound should appear exactly once in {mode} mode: {inbound_tags!r}")
dns_inbound = next((inbound for inbound in singbox.get("inbounds", []) if inbound.get("tag") == "magicnet-dns-in"), None)
if not dns_inbound:
    raise SystemExit(f"magicnet DNS inbound missing in {mode} mode")
if dns_inbound.get("type") != "direct" or dns_inbound.get("listen") != "127.0.0.1" or dns_inbound.get("listen_port") != 1053:
    raise SystemExit(f"magicnet DNS inbound mismatch in {mode} mode: {dns_inbound!r}")
dns_hijack = next(
    (
        rule for rule in singbox.get("route", {}).get("rules", [])
        if rule.get("action") == "hijack-dns"
        and rule.get("inbound") == ["magicnet-dns-in"]
        and "protocol" not in rule
    ),
    None,
)
if not dns_hijack:
    raise SystemExit(f"magicnet DNS hijack rule missing in {mode} mode")
for inbound in singbox.get("inbounds", []):
    present = sorted(legacy_inbound_fields.intersection(inbound))
    if present:
        raise SystemExit(f"legacy inbound fields present in {mode} mode: tag={inbound.get('tag')!r} fields={present!r}")
if "tun" not in inbound_types:
    raise SystemExit(f"sing-box tun inbound missing in {mode} mode")
tun_inbound = next((inbound for inbound in singbox.get("inbounds", []) if inbound.get("type") == "tun"), {})
if tun_inbound.get("tag") != "tun-in":
    raise SystemExit(f"sing-box tun tag mismatch in {mode} mode: {tun_inbound.get('tag')!r}")
if tun_inbound.get("address") != ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]:
    raise SystemExit(f"sing-box tun address is not dual-stack in {mode} mode: {tun_inbound.get('address')!r}")
expected_sniff_inbounds = ["mixed-in", "tun-in"]
if any(kind in inbound_types for kind in ("tproxy", "redirect")):
    raise SystemExit(f"legacy transparent inbound still present in {mode} mode: {inbound_types!r}")
if any((inbound.get("tag") or "").startswith("magicnet-") and inbound.get("tag") != "magicnet-dns-in" for inbound in singbox.get("inbounds", [])):
    raise SystemExit(f"managed transparent inbound still present in {mode} mode")
if not sniff_rule:
    raise SystemExit(f"sing-box sniff rule missing in {mode} mode")
if sniff_rule.get("inbound") != expected_sniff_inbounds:
    raise SystemExit(f"sing-box sniff inbound list mismatch in {mode} mode: {sniff_rule.get('inbound')!r}")
PY

    if rg -q -- '-j TPROXY|REDIRECT --to-ports' "$TMP/${mode}-commands.log"; then
        exit 1
    fi
}

assert_transparent_mode tun

config_digest() {
    sha256sum "$MODDIR/.config/sing-box/config.json" | awk '{print $1}'
}

mode_digest() {
    sha256sum "$MODDIR/.config/magicnet/transparent-mode.conf" | awk '{print $1}'
}

assert_no_transparent_journal() {
    if find "$MODDIR/.state" -maxdepth 3 -type d \
        \( -iname '*transparent*transaction*' -o -iname '*transparent*journal*' \) \
        -print -quit | grep -q .; then
        echo "transparent mode journal was not cleaned" >&2
        find "$MODDIR/.state" -maxdepth 3 -type d -print >&2
        exit 1
    fi
}

# A failed capability probe is a preflight failure: it must not stop the old
# generation or publish either the mode file or candidate JSON.
tun_config_digest="$(config_digest)"
tun_mode_digest="$(mode_digest)"
probe_log_start="$(wc -l <"$MOCK_LOG")"
if run env MAGICNET_FAKE_EBPF_PROBE_FAIL=1 "$MODDIR/cli" transparent set ebpf; then
    echo "transparent set ebpf ignored a failed capability probe" >&2
    exit 1
fi
[[ "$(config_digest)" == "$tun_config_digest" ]]
[[ "$(mode_digest)" == "$tun_mode_digest" ]]
tail -n "+$((probe_log_start + 1))" "$MOCK_LOG" >"$TMP/ebpf-probe-failure.log"
rg -q '^sing-box tools ebpf status ' "$TMP/ebpf-probe-failure.log"
if rg -q '^killall .*sing-box|^sing-box run ' "$TMP/ebpf-probe-failure.log"; then
    echo "failed eBPF preflight disturbed the running TUN generation" >&2
    exit 1
fi
assert_no_transparent_journal

# If the candidate core cannot start after the old generation is stopped, the
# transaction restores both exact old files and starts the old TUN generation.
start_failure_log_start="$(wc -l <"$MOCK_LOG")"
if run env MAGICNET_FAKE_SINGBOX_START_FAIL=1 "$MODDIR/cli" transparent set ebpf; then
    echo "transparent set ebpf ignored candidate start failure" >&2
    exit 1
fi
[[ "$(config_digest)" == "$tun_config_digest" ]]
[[ "$(mode_digest)" == "$tun_mode_digest" ]]
tail -n "+$((start_failure_log_start + 1))" "$MOCK_LOG" >"$TMP/ebpf-start-failure.log"
rg -q '^sing-box tools ebpf status ' "$TMP/ebpf-start-failure.log"
rg -q '^sing-box run ' "$TMP/ebpf-start-failure.log"
pidof sing-box >/dev/null
assert_no_transparent_journal

# Recreate the durable on-disk state left by an uncatchable interruption after
# target publication. The next lifecycle entrypoint must restore the exact TUN
# files before doing any new work.
fault_config_digest="$(config_digest)"
fault_mode_digest="$(mode_digest)"
fault_journal="$MODDIR/.state/transparent-transaction"
mkdir -m 700 "$fault_journal"
printf '%s\n' tun >"$fault_journal/old-mode"
printf '%s\n' 1 >"$fault_journal/old-mode-present"
printf '%s\n' ebpf >"$fault_journal/target-mode"
printf '%s\n' target-written >"$fault_journal/phase"
printf '%s\n' 1 >"$fault_journal/old-config-present"
cp "$MODDIR/.config/sing-box/config.json" "$fault_journal/old-config.json"
chmod 600 "$fault_journal"/*
printf '%s\n' 'MAGICNET_TRANSPARENT_MODE=ebpf' >"$MODDIR/.config/magicnet/transparent-mode.conf"
printf '%s\n' '{"inbounds":[]}' >"$MODDIR/.config/sing-box/config.json"
run "$MODDIR/cli" service start sing-box
[[ "$(config_digest)" == "$fault_config_digest" ]]
[[ "$(mode_digest)" == "$fault_mode_digest" ]]
pidof sing-box >/dev/null
assert_no_transparent_journal

# Successful switch and repeated apply are deterministic. CLI status and
# health must use eBPF capability/cgroup/TC evidence and must not demand
# magicnet0 when the effective mode is local.
run "$MODDIR/cli" transparent set ebpf
run "$MODDIR/cli" transparent status >"$TMP/ebpf-transparent-status.log"
rg -qx 'mode=ebpf' "$TMP/ebpf-transparent-status.log"
rg -q '(^effective_mode=local$)|(effective=mode:local)' "$TMP/ebpf-transparent-status.log"
# The host mock's long-lived process is `sleep`, so Rust ownership cannot bind
# it to the packaged sing-box executable. Status and health must fail closed
# instead of turning a capability/active-program report into attachment proof.
rg -qx 'local_cgroup=missing' "$TMP/ebpf-transparent-status.log"
if rg -qx 'local_cgroup=attached' "$TMP/ebpf-transparent-status.log"; then
    echo "eBPF transparent status trusted attachment evidence from the wrong process" >&2
    cat "$TMP/ebpf-transparent-status.log" >&2
    exit 1
fi
rg -qx 'shared_tc=inactive' "$TMP/ebpf-transparent-status.log"
if rg -q 'required[^[:alnum:]]+magicnet0|magicnet0[^[:alnum:]]+(missing|required)' "$TMP/ebpf-transparent-status.log"; then
    echo "eBPF transparent status incorrectly required magicnet0" >&2
    cat "$TMP/ebpf-transparent-status.log" >&2
    exit 1
fi
run "$MODDIR/cli" health >"$TMP/ebpf-health.log"
if rg -q '^\[ok\] Dataplane:' "$TMP/ebpf-health.log"; then
    echo "eBPF health accepted a capability report without current-process attachment evidence" >&2
    cat "$TMP/ebpf-health.log" >&2
    exit 1
fi
rg -q '^\[warn\] Dataplane:' "$TMP/ebpf-health.log"
rg -q 'configured=mode:ebpf' "$TMP/ebpf-health.log"
rg -q 'effective=mode:local' "$TMP/ebpf-health.log"
rg -q 'probe=capability:' "$TMP/ebpf-health.log"
rg -q 'attachment=' "$TMP/ebpf-health.log"
if rg -q 'required[^[:alnum:]]+magicnet0|magicnet0[^[:alnum:]]+(missing|required)' "$TMP/ebpf-health.log"; then
    echo "eBPF health incorrectly required magicnet0" >&2
    cat "$TMP/ebpf-health.log" >&2
    exit 1
fi

ebpf_config_digest="$(config_digest)"
run "$MODDIR/cli" transparent apply
[[ "$(config_digest)" == "$ebpf_config_digest" ]]
run "$MODDIR/cli" transparent apply
[[ "$(config_digest)" == "$ebpf_config_digest" ]]
assert_no_transparent_journal

# Exercise the reverse transition as well; an already-selected target is a
# successful no-op at the file/config level.
run "$MODDIR/cli" transparent set tun
restored_tun_config_digest="$(config_digest)"
restored_tun_mode_digest="$(mode_digest)"
run "$MODDIR/cli" transparent set tun
[[ "$(config_digest)" == "$restored_tun_config_digest" ]]
[[ "$(mode_digest)" == "$restored_tun_mode_digest" ]]
assert_no_transparent_journal

for legacy_mode in proxy external external-tun hybrid; do
    # shellcheck disable=SC2016
    if run env MAGICNET_TEST_MODE="$legacy_mode" sh -c '
        . "$MODDIR/lib/kamfw/.kamfwrc"
        import __runtime__
        . "$MODDIR/lib/magicnet.sh"
        magicnet_transparent_set_mode "$MAGICNET_TEST_MODE"
    '; then
        echo "legacy transparent mode was still accepted: $legacy_mode" >&2
        exit 1
    fi
done

"$HOST_JQ" empty "$MODDIR/.config/sing-box/config.json"

echo "fake Magisk smoke passed: $MODDIR"
