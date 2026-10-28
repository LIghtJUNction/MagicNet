# MagicNet

[简体中文](README.md) · [English](README.en.md) · [Русский](README.ru.md)

<a href="https://donate.lmm.best/?project=magicnet"><img src="https://donate.lmm.best/badge.svg?project=magicnet&amp;currency=CNY&amp;lang=en&amp;period=all&amp;layout=compact&amp;theme=dark&amp;width=360&amp;title=MagicNet" alt="Donate" width="360" /></a>

**A no-fuss sing-box transparent proxy for rooted Android phones.**

Tired of a proxy app hogging Android's one and only VPN slot? MagicNet runs our own [sing-box fork](sing-box) at the system level through Magisk, KernelSU or APatch, so the VPN slot stays free. You decide which apps go through the proxy, which go direct, what happens on your home Wi-Fi, and how hotspot clients are handled.

You get two transparent modes, and you switch between them yourself:

- **`tun` (default)** creates a virtual interface called `magicnet0`. It's reliable and widely compatible, and it's what most people need.
- **`ebpf`** steers traffic with kernel hooks. Pick it if you like to tinker and your kernel supports it.

Switching uses a transaction with rollback and attempts to restore the previous state on failure. Recovery can also fail, so uninterrupted connectivity is not guaranteed. If switching fails, inspect `cli transparent status`, `cli health` and recovery diagnostics rather than repeatedly switching modes.

## What you get

- **Bring the subscription you already have.** Paste public HTTPS subscription URLs (up to five sources), or import local Clash/Mihomo YAML, base64, sharing links, sing-box JSON or plain text. You don't need a "sing-box-only" subscription.
- **Per-app, Wi-Fi and hotspot policies.** Set each app to Proxy, Direct or Bypass. Switch policy automatically by Wi-Fi network, and choose Direct or Proxy for hotspot clients.
- **A WebUI that shows what's going on.** Check subscriptions, proxy groups, node latency, traffic and diagnostics in one place. The overview draws a live traffic constellation (device → dataplane → sing-box → exit) from verified status only. Press `Ctrl/⌘ + K` or `/` to jump to any page.
- **Honest status reporting.** TUN is judged by `magicnet0`. eBPF is judged by capability, cgroup and TC attachment state. If MagicNet can't confirm something, it says so instead of pretending all is well.
- **Scriptable when you want it.** The WebUI and optional, authenticated MCP server reuse controlled CLI operations. MCP exposes a subset, including service control, configuration and subscriptions, app policies, node selection and testing, status diagnostics and backups—not every WebUI action. Use the MCP `tools/list` response as the available-tool reference.

## Up and running in five minutes

1. Download a module ZIP from [Releases](https://github.com/LIghtJUNction/MagicNet/releases), install it through Magisk, KernelSU or APatch, and reboot.
2. Turn Android **Private DNS** off. "Automatic" isn't good enough; it needs to be off.
3. Open the module WebUI from your root manager. On the Subscriptions page, add a subscription URL you're authorized to use, or import a local subscription file.
4. Save and activate it, then check the health page. Once sing-box and the selected network mode show as healthy, you're done.

Prefer a terminal? Three lines in a root shell:

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
```

A working TUN setup creates `magicnet0`. eBPF never creates that interface, so check the local cgroup and shared TC/interface states instead. The shared hotspot path can stay pending until a downstream interface shows up. That's expected.

> MagicNet is just a tool. It doesn't provide subscriptions, proxy nodes or external network access. Please use only resources you're authorized to access.

## Languages

The WebUI speaks Simplified Chinese, English and Russian. Pick one from the language selector and your browser remembers it.

The setup guide and module action menu support Russian and English, plus the existing Chinese, Japanese and Korean translations. They follow Android's system language by default, and interactive terminal installs also offer a language picker. To override the action menu language for a single run:

```bash
su -c 'KAM_UI_LANGUAGE=en sh /data/adb/modules/MagicNet/action.sh'
```

Use `ru` for Russian. This only changes MagicNet's interface language, not Android's. CLI commands, machine-readable status, configuration values and raw logs keep their original format so scripts don't break. The bundled third-party core panel has its own language settings.

## Handy commands

```bash
su -c /data/adb/modules/MagicNet/cli sub status
su -c /data/adb/modules/MagicNet/cli sub update sing-box
su -c /data/adb/modules/MagicNet/cli node test-all
su -c /data/adb/modules/MagicNet/cli service restart sing-box
su -c /data/adb/modules/MagicNet/cli transparent set tun
su -c /data/adb/modules/MagicNet/cli transparent set ebpf
su -c /data/adb/modules/MagicNet/cli diagnose
su -c /data/adb/modules/MagicNet/cli support bundle
```

App policy examples. Use `direct` for "just don't proxy this". Save `bypass` for apps that must coexist with another VPN:

```bash
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.browser direct'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'
```

## Building it yourself

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init
kam build
```

Source builds need [kam](https://github.com/MemDeco-WG/kamfw). The more detailed docs are currently in Chinese only, sorry about that: [user guide](docs/user-guide.md), [MCP](docs/mcp.md) and [Tailscale](docs/tailscale.md).

Questions or just want to say hi? Join us on [Discord](https://discord.gg/asRwgK9FpA).
