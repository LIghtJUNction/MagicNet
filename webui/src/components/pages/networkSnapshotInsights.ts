import { t } from "@/i18n";
import { statusToneClasses } from "@/lib/statusTone";
export type NetworkSnapshotInsight = {
  label: string;
  value: string;
  detail: string;
  tone: "ok" | "warn" | "info";
};

export function buildNetworkSnapshotInsights(
  text: string,
): NetworkSnapshotInsight[] {
  const lower = text.toLowerCase();
  const interfaces = collectInterfaceNames(text);
  const egress = interfaces.filter((name) =>
    /^(wlan|wlp|enp|rmnet|ccmni|eth|usb|rndis|pdp|ap|swlan|wwan|cell|p2p|ppp)/i.test(
      name,
    ),
  );
  // magicnet0 is authoritative only when configured_mode=tun. In eBPF mode
  // cgroup/TC attachment facts come from `cli transparent status`, not links.
  const hasTun =
    interfaces.some((name) => name.toLowerCase() === "magicnet0") ||
    /\bmagicnet0\b/i.test(text);
  const hasPolicyRule = hasSnapshotLine(
    text,
    /\bip rule:|from all fwmark\b|lookup \d+\b|lookup main\b/i,
  );
  const hasNat = hasSnapshotLine(
    text,
    /\bmasquerade\b|\bsnat\b|\bdnat\b|-t nat\b|chain postrouting\b/i,
  );
  const hasDnsRedirect = hasSnapshotLine(
    text,
    /\b(dpt:53|--dport 53|udp dpt:domain|tcp dpt:domain|redirect\b.*:53|to-ports (?:53|1053))\b/i,
  );
  return [
    {
      label: t("TUN 接口"),
      value: hasTun ? t("detected") : t("not detected"),
      detail: hasTun
        ? t("快照中发现 magicnet0 TUN。")
        : t("未发现 magicnet0；eBPF 模式下这是正常现象，请结合 transparent status。"),
      tone: hasTun ? "ok" : "info",
    },
    {
      label: t("出口接口"),
      value: egress.length ? egress.slice(0, 4).join(", ") : t("unknown"),
      detail: egress.length
        ? t("检测到常见出口接口命名线索。")
        : t("未识别常见出口接口命名线索。"),
      tone: egress.length ? "info" : "warn",
    },
    {
      label: t("策略路由"),
      value: hasPolicyRule ? t("detected") : t("not detected"),
      detail: hasPolicyRule
        ? t("快照文本包含 policy routing 线索。")
        : t("未看到明显 ip rule/policy route 线索。"),
      tone: hasPolicyRule ? "ok" : "info",
    },
    {
      label: "NAT",
      value: hasNat ? t("detected") : t("not detected"),
      detail: hasNat
        ? t("快照文本包含 NAT/MASQUERADE 线索。")
        : t("未看到 NAT 线索，热点转发或共享网络需继续确认。"),
      tone: hasNat ? "ok" : "info",
    },
    {
      label: t("DNS 捕获"),
      value: hasDnsRedirect ? t("detected") : t("not detected"),
      detail: hasDnsRedirect
        ? t("快照文本包含 53 端口 redirect 线索。")
        : t("未看到 DNS redirect 线索，可结合 DNS 工具继续测试。"),
      tone: hasDnsRedirect ? "ok" : "info",
    },
    {
      label: t("规模"),
      value: t("{count} interfaces", { count: interfaces.length }),
      detail: t("{value1} 行有效快照文本。", { value1: text.split(/\r?\n/).filter((line) => line.trim()).length }),
      tone:
        lower.includes("error") || lower.includes("failed") ? "warn" : "info",
    },
  ];
}

export function formatNetworkSnapshotReport(
  text: string,
  insights: NetworkSnapshotInsight[],
): string {
  const nonEmptyLines = text
    .split(/\r?\n/)
    .filter((line) => line.trim()).length;
  return [
    "MagicNet network snapshot",
    `snapshot_lines=${nonEmptyLines}`,
    "raw_snapshot=omitted",
    ...insights.map(
      (item) =>
        `${item.label}=${item.value} tone=${item.tone} detail=${item.detail}`,
    ),
  ]
    .join("\n")
    .trim();
}

export function networkInsightTone(
  tone: NetworkSnapshotInsight["tone"],
): string {
  if (tone === "ok") return statusToneClasses("ok");
  if (tone === "warn") return statusToneClasses("warn");
  return statusToneClasses("neutral");
}

function collectInterfaceNames(text: string): string[] {
  const names =
    text.match(
      /\b(?:wlan|wlp|enp|rmnet|ccmni|eth|usb|rndis|pdp|ap|swlan|wwan|cell|p2p|ppp|veth|br|bridge|tun|utun|lo|magicnet)[\w.:-]*/gi,
    ) || [];
  return Array.from(new Set(names.map((name) => name.replace(/:$/, ""))));
}

function hasSnapshotLine(text: string, pattern: RegExp): boolean {
  return text.split(/\r?\n/).some((line) => pattern.test(line));
}
