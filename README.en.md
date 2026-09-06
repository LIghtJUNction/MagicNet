# MagicNet

[简体中文](README.md) · [English](README.en.md) · [Русский](README.ru.md)

MagicNet manages Android network traffic through a root-controlled [sing-box fork](sing-box), without occupying Android's VPN slot. It supports explicit `tun` and `ebpf` modes, with `tun` enabled by default.

## Features

- Import public HTTPS subscription URLs or local Clash/Mihomo YAML, base64, sharing links, sing-box JSON and text files. Up to five URL sources are supported.
- Route apps through Proxy, Direct or Bypass policies, and configure Wi-Fi and hotspot policies.
- Inspect subscriptions, proxy groups, node latency, traffic and diagnostics from the WebUI.
- Switch explicitly between TUN and eBPF, with rollback on failure. TUN uses `magicnet0`; eBPF reports capability, cgroup and TC attachment state.
- Manage the same operations through the CLI and optional authenticated MCP server.

## Install and configure

1. Download a module ZIP from [Releases](https://github.com/LIghtJUNction/MagicNet/releases), install it through Magisk, KernelSU or APatch, and reboot.
2. Turn Android **Private DNS** off. Do not leave it set to Automatic.
3. Open the module WebUI in your root manager. Add an authorized subscription URL or import a local subscription file on the Subscriptions page.
4. Save and activate the subscription. Check the health page to confirm that sing-box and the selected network mode are working.

You can also configure and inspect the module from a root shell:

```bash
su -c '/data/adb/modules/MagicNet/cli setup "https://example.com/subscription"'
su -c /data/adb/modules/MagicNet/cli health
su -c /data/adb/modules/MagicNet/cli transparent status
```

A working TUN configuration creates `magicnet0`. For eBPF, inspect the local cgroup and shared TC/interface states; `magicnet0` is not required. The shared hotspot path can remain pending until a downstream interface is available.

MagicNet does not provide subscriptions, proxy nodes or external network access. Use resources you are authorized to access.

## Languages

The WebUI supports Simplified Chinese, English and Russian. Use its language selector to change the interface; your choice is remembered in the browser.

The setup guide and module action menu support Russian and English alongside existing Chinese, Japanese and Korean translations. They follow Android's language by default. Interactive terminal installation also offers a language picker. To override the action menu language for one invocation:

```bash
su -c 'KAM_UI_LANGUAGE=en sh /data/adb/modules/MagicNet/action.sh'
```

Use `ru` for Russian. This changes MagicNet's interface language without changing Android's system language. CLI commands, machine-readable status, configuration values and raw logs retain their original format. The bundled third-party core panel has its own language settings.

## Common commands

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

App policy examples:

```bash
su -c '/data/adb/modules/MagicNet/cli app add com.example.app proxy'
su -c '/data/adb/modules/MagicNet/cli app add com.example.browser direct'
su -c '/data/adb/modules/MagicNet/cli app add com.example.vpn bypass'
```

## Development and documentation

```bash
git clone https://github.com/LIghtJUNction/MagicNet.git
cd MagicNet
git submodule update --init
kam build
```

The source build requires [kam](https://github.com/MemDeco-WG/kamfw). More detailed documentation is currently available in Chinese: [user guide](docs/user-guide.md), [MCP](docs/mcp.md), and [Tailscale](docs/tailscale.md).
