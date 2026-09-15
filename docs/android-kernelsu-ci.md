# Android KernelSU acceptance workflow

`Android KernelSU Acceptance` is a manual-only GitHub Actions workflow for testing a real MagicNet module installation inside an Android virtual device. It is intentionally separate from normal push/PR CI because an emulator, KernelSU lifecycle reboots, live proxy nodes, and throughput probes are comparatively expensive and externally variable.

## What it exercises

The workflow uses an Android 15 / API 35 `google_apis` x86_64 AVD and boots it with a pinned KernelSU v3.2.0-compatible GKI kernel. It then:

1. installs the matching `ksud` userspace and verifies the KernelSU kernel interface;
2. installs `dist/MagicNet.zip` with `ksud module install`;
3. reboots through the real KernelSU post-fs-data/service lifecycle;
4. replaces only the packaged arm64 executables with x86_64 test builds so the hardware-accelerated AVD can run the same module tree;
5. imports a fresh public free-node Clash subscription;
6. validates MagicNet health, transparent routing, sing-box state, config validity, and the `magicnet0` interface;
7. probes the maintained `network-targets.tsv` domestic/global service matrix;
8. records reachability, repeated request latency, optional throughput, sing-box/CLI/MCP RSS, high-water RSS, thread and file-descriptor counts, Android memory information, `top`, logs, dmesg, and module state.

All reports are uploaded as the `android-kernelsu-acceptance-*` Actions artifact and the network summary is also written to the workflow step summary.

## Triggering it

Open **Actions → Android KernelSU Acceptance → Run workflow**. Inputs control the public proxy shard (`global`, `US`, or `JP`), the number of latency rounds, throughput probes, stricter external-network gating, and whether the pristine AVD cache should be bypassed.

The default policy treats individual public endpoint failures as observations because free nodes and third-party sites fluctuate. Losing all domestic reachability or all global/proxied reachability still fails the run. `strict_external=true` additionally requires at least 80% of all endpoint rounds to succeed.

## Caches

The workflow keeps three independent cache classes:

- normal Go/Rust/KAM build outputs;
- the checksum-pinned KernelSU AVD kernel and matching `ksud` binary;
- a pristine Android 15 AVD plus its system image.

The pristine AVD is saved before any KernelSU/MagicNet mutation. A test run therefore never writes the installed module or subscription back into the AVD cache.

## Public proxy feed

The acceptance test uses `Au1rxx/free-vpn-subscriptions`. Its published Clash feed is refreshed hourly and its project performs real sing-box HTTP-over-proxy verification before publishing nodes. The workflow always fetches the live subscription during the test instead of caching it as authoritative state.

Free proxy operators can observe traffic metadata and possibly plaintext traffic. For that reason this workflow only accesses anonymous public test endpoints. Do not put private subscription URLs, cookies, account tokens, application logins, or other credentials into this test.

## Scope

The service matrix represents network behavior needed by common domestic and international apps (WeChat/Tencent, Bilibili, Taobao, Alipay, Google/Play connectivity, YouTube, ChatGPT, Claude, GitHub, Telegram, Discord, etc.). It deliberately does not automate login flows in proprietary apps. Those flows require redistributable APKs/test accounts and should be a separate opt-in device-farm layer if added later.

GitHub-hosted runners are not mainland-China mobile networks. The domestic results verify MagicNet routing and service reachability from the AVD runner, not carrier-specific behavior on China Telecom/Unicom/Mobile. Real-device acceptance remains necessary for carrier, OEM, battery, and long-lived mobile-session behavior.
