---
name: magicnet-device-debugging
description: Debug and verify MagicNet on a real Android root device. Use when working on MagicNet MCP usage, adb/root validation, eBPF or netd status, DNS leak diagnosis, sing-box/TUN behavior, certificate-less packet capture, eCapture/tcpdump checks, support bundles, device logs, or module runtime issues under /data/adb/modules/MagicNet.
---

# MagicNet Device Debugging

Use the connected Android device as the source of truth. MagicNet is a root module; local config checks cannot prove vendor networking, KernelSU/Magisk behavior, eBPF hooks, DNS routing, or real packet capture.

## Ground Rules

- Never print or commit secrets from `.env`, subscriptions, MCP secrets, device tokens, or raw logs containing private traffic.
- Read `.env` only when a task needs local private defaults; do not copy its values into docs, patches, issues, commits, or replies.
- Use `/sdcard/Download/MagicNet/` for device-side temporary transfer files. Do not use `/data/local/tmp`.
- Use `su -M -c` on KernelSU devices unless the current device proves another root invocation is required.
- Keep packet capture diagnostic-only. Do not restore the removed proxy MITM/TProxy capture path, `cli capture`, capture config files, or `lib/magicnet/capture_*`.
- Do not reintroduce Android CA injection. `system/etc/security/cacerts`, `cli cert`, and generated MagicNet local CA support were removed; use tcpdump or eCapture for no-certificate diagnostics.
- Do not add module-level `post-fs-data.sh` or placeholder `uninstall.sh` just for compatibility. MagicNet uses `service.sh` and `boot-completed.sh`; uninstall hooks belong in kamfw only when real cleanup exists.
- When eBPF redirect is incomplete, `auto` must fall back to TUN. Do not silently promote netd `ALLOW_MULTI`.

## Baseline Snapshot

Start with read-only evidence:

```sh
adb devices -l
adb shell 'getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk'
adb shell 'su -M -c "id"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli service status"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli health"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli ebpf status"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli ecapture status || true"'
```

For network work, capture routes and listeners before changing anything:

```sh
adb shell 'su -M -c "ip addr; ip route; ip rule"'
adb shell 'su -M -c "ss -lntup 2>/dev/null | grep -E \"sing-box|magicnet|789|909|876\" || true"'
```

## MCP Usage

MagicNet exposes a Streamable HTTP MCP server from the device module. Enable it explicitly, read the actual bind/port from `cli mcp status`, forward that port to localhost, then call it with the device-generated secret.

```sh
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp enable 127.0.0.1 8766"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp status"'
adb forward tcp:8766 tcp:8766
```

If `cli mcp status` reports a different port, use that port in `adb forward` and in any local `.mcp.json` endpoint. Do not assume stale docs or client config are correct.

Read the secret into a local shell variable without echoing it:

```sh
MCP_SECRET="$(adb shell 'su -M -c "/data/adb/modules/MagicNet/cli mcp secret"' | tr -d '\r')"
curl -fsS -X POST http://127.0.0.1:8766/mcp \
  -H "Authorization: Bearer ${MCP_SECRET}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
unset MCP_SECRET
```

If the local MCP client reads `.mcp.json`, verify it points at `http://127.0.0.1:8766/mcp` unless `cli mcp status` reports a different port. If calls fail, inspect `/data/adb/modules/MagicNet/.log/mcp-server.log` with redaction.

## eBPF And netd Status

Use `cli ebpf status` as the first-line status view because it normalizes MagicNet eBPF program state and netd hints for agents and WebUI diagnostics.

```sh
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli ebpf status"'
adb shell 'su -M -c "ls -la /sys/fs/bpf 2>/dev/null | head -80 || true"'
adb shell 'su -M -c "logcat -d -t 300 | grep -Ei \"MagicNet|magicnet|netd|bpf\" || true"'
```

Interpret status conservatively:

- `attached` means a hook/program appears loaded; still verify traffic at the physical interface.
- `missing` or `permission denied` can be kernel, bpffs, SELinux, or vendor netd behavior.
- netd `ALLOW_MULTI` is only evidence of netd capability. Do not treat it as permission to force eBPF redirect.

## AI Website Routing Acceptance

Do not accept an AI routing fix from config inspection alone. On the installed device, verify all four public websites through MagicNet's local HTTP proxy at `127.0.0.1:7892`:

```sh
adb shell 'su -M -c '\''for url in https://chatgpt.com/ https://gemini.google.com/ https://grok.com/ https://claude.ai/; do curl -sS -o /dev/null -w "%{http_code} $url\n" --max-time 30 -x http://127.0.0.1:7892 "$url"; done'\'''
```

- Require an HTTP response from every site. A redirect, authentication response, or application response proves reachability; timeout, DNS failure, TLS failure, or proxy failure does not.
- For each request, collect sing-box logs proving traffic selected its dedicated outbound: `ai-chatgpt`, `ai-gemini`, `ai-grok`, or `ai-claude`. Reject any `missing outbound`, `outbound not found`, or equivalent error.
- Follow command-line probes with a real browser visit when the user's acceptance criterion is website usability. Confirm the page loads through MagicNet rather than only proving TCP/TLS reachability.
- If testing temporarily changes a selector through the Clash API or WebUI, record its original selection and restore it before finishing.
- Redact subscription URLs, node credentials, tokens, cookies, authorization headers, and private browsing data from commands, logs, screenshots, and reports.

## Certificate-Less Packet Capture

Use these methods when the user wants packet evidence without installing a CA certificate.

### Metadata Capture With tcpdump

`tcpdump` needs no certificate and can prove whether traffic leaves a given interface, port, or DNS path. It does not decrypt HTTPS payloads.

```sh
adb shell 'su -M -c "timeout 15 tcpdump -i any -nn -c 40 '\''tcp port 443 or udp port 53 or tcp port 53 or tcp port 853 or udp port 853'\''"'
```

Trigger traffic in parallel from another shell:

```sh
adb shell 'am start -a android.intent.action.VIEW -d "https://www.cloudflare.com/cdn-cgi/trace?magicnet_probe=1"'
```

For DNS leak checks, capture on the physical egress interface when known, such as `wlan0` or `rmnet_data0`, and verify no plain DNS/DoT leaves unexpectedly:

```sh
adb shell 'su -M -c "timeout 12 tcpdump -ni wlan0 '\''port 53 or port 853'\''"'
```

If the interface is unclear, list candidates:

```sh
adb shell 'su -M -c "ip -o link show | cut -d: -f2 | tr -d \" \""'
```

### eCapture Packet Or TLS Diagnostics

Use the bundled eCapture wrapper when `cli ecapture status` says the binary is installed and executable. Treat a successful process exit as "probe started"; verify capture success by checking the output file is non-empty.

```sh
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli ecapture status"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli ecapture pcap 15 wlan0 tcp port 443"'
adb shell 'su -M -c "/data/adb/modules/MagicNet/cli ecapture tls 15 all all"'
```

Expected outputs are under `/data/adb/modules/MagicNet/.log/`, such as `ecapture.pcapng`, `ecapture-pcap.log`, `ecapture-tls.log`, and `ecapture-tls-events.log`. Confirm file content:

```sh
adb shell 'su -M -c "ls -lh /data/adb/modules/MagicNet/.log/ecapture.pcapng; wc -c /data/adb/modules/MagicNet/.log/ecapture.pcapng"'
```

Boundaries:

- `cli ecapture pcap` can write packet captures, not decrypted application payloads. If the file is 0 bytes, report pcap output as not validated even if probes started.
- `cli ecapture tls` can expose TLS plaintext events without installing a CA, but only when the kernel, eBPF probes, architecture, and target TLS library are compatible.
- Browser/app HTTPS plaintext is not guaranteed. If TLS mode is silent, fall back to packet metadata and routing/DNS evidence.

## Legacy Cleanup Checks

When auditing stale MagicNet files, treat these paths as removed mainline features:

```sh
find /data/adb/modules/MagicNet -maxdepth 4 \( \
  -path '*/system/etc/security/cacerts*' \
  -o -name 'post-fs-data.sh' \
  -o -name 'sepolice.rule' \
  -o -name 'capture_common.sh' \
  -o -name 'capture_singbox.sh' \
  -o -name 'capture.conf' \
\) -print
```

Expected result for a current install is no output. If old files appear on a device, they are migration residue; do not build new behavior around them.

For kamfw uninstall behavior, check the framework, not MagicNet module root:

```sh
adb shell 'su -M -c "test -f /data/adb/modules/MagicNet/uninstall.sh && sed -n '\''1,120p'\'' /data/adb/modules/MagicNet/uninstall.sh || true"'
```

An uninstall script is only meaningful if it contains real rollback commands or calls `kamfw run uninstall -- "$@"`.

To pull a capture for local inspection, copy through the approved transfer directory and clean it after use:

```sh
adb shell 'mkdir -p /sdcard/Download/MagicNet'
adb shell 'su -M -c "cp /data/adb/modules/MagicNet/.log/ecapture.pcapng /sdcard/Download/MagicNet/ecapture.pcapng"'
adb pull /sdcard/Download/MagicNet/ecapture.pcapng .
adb shell 'rm -f /sdcard/Download/MagicNet/ecapture.pcapng'
```

## Reporting

Report only concise evidence:

- Device model, Android version, and root availability.
- MagicNet service, health, eBPF/netd, MCP, and capture status.
- Whether tcpdump or eCapture captured packets.
- Whether HTTPS plaintext was expected, observed, or unavailable.
- Any DNS leak evidence by interface and port, without exposing private domains beyond what the user asked to test.
