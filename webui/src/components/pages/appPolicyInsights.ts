import { fnv32Hex } from "@/lib/fnv32";

export type AppPolicyMode = "blacklist" | "whitelist";

export type AppPolicyInsight = {
  label: string;
  value: string;
  tone: "success" | "warning" | "danger" | "neutral";
};

export type AppPolicySummary = {
  summary: string;
  items: AppPolicyInsight[];
  conflicts: string[];
  installedProxy: string[];
  installedDirect: string[];
  installedBypass: string[];
};

export type AppPolicySafeReportInput = {
  mode: AppPolicyMode;
  proxy: string[];
  direct: string[];
  bypass: string[];
  summary: AppPolicySummary;
};

export function isValidPackageName(pkg: string): boolean {
  return /^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(pkg);
}

export function buildAppPolicySummary(
  mode: AppPolicyMode,
  proxy: string[],
  direct: string[],
  bypass: string[],
  installedPackages: Set<string>,
  availableRecommendedCount: number
): AppPolicySummary {
  const directSet = new Set(direct);
  const bypassSet = new Set(bypass);
  const conflicts = Array.from(new Set([
    ...proxy.filter((pkg) => directSet.has(pkg) || bypassSet.has(pkg)),
    ...direct.filter((pkg) => bypassSet.has(pkg))
  ]));
  const installedProxy = installedPackages.size ? proxy.filter((pkg) => installedPackages.has(pkg)) : [];
  const installedDirect = installedPackages.size ? direct.filter((pkg) => installedPackages.has(pkg)) : [];
  const installedBypass = installedPackages.size ? bypass.filter((pkg) => installedPackages.has(pkg)) : [];
  const installedKnown = installedPackages.size > 0;
  const unlisted = mode === "whitelist" ? "绕过当前数据面" : "进入当前数据面";
  return {
    summary: mode === "whitelist"
      ? "Proxy 强制代理；Direct 在 MagicNet 内强制直连；未列出应用绕过当前数据面。"
      : "Proxy 强制代理；Direct 在 MagicNet 内强制直连；Bypass 完全绕过当前数据面。",
    conflicts,
    installedProxy,
    installedDirect,
    installedBypass,
    items: [
      insight("Proxy 强制", `${proxy.length} 个`, proxy.length ? "success" : "neutral"),
      insight("Direct 直连", `${direct.length} 个`, direct.length ? "success" : "neutral"),
      insight("Bypass TUN", `${bypass.length} 个`, bypass.length ? "warning" : "neutral"),
      insight("未列出应用", unlisted, mode === "blacklist" ? "success" : "neutral"),
      insight("名单冲突", conflicts.length ? `${conflicts.length} 个` : "无", conflicts.length ? "danger" : "success"),
      insight("当前列表命中", installedKnown ? `P ${installedProxy.length} / D ${installedDirect.length} / B ${installedBypass.length}` : "未读取应用", installedKnown ? "success" : "warning"),
      insight("可应用推荐", `${availableRecommendedCount} 个`, availableRecommendedCount ? "neutral" : "success")
    ]
  };
}

export function formatAppPolicySafeReport(input: AppPolicySafeReportInput): string {
  return [
    "MagicNet app policy",
    "privacy_note=package names omitted; fingerprints are weak change markers, not privacy proof",
    `mode=${input.mode}`,
    `proxy_count=${input.proxy.length}`,
    `direct_count=${input.direct.length}`,
    `bypass_count=${input.bypass.length}`,
    `summary=${input.summary.summary}`,
    `conflict_count=${input.summary.conflicts.length}`,
    `current_list_proxy=${input.summary.installedProxy.length}`,
    `current_list_direct=${input.summary.installedDirect.length}`,
    `current_list_bypass=${input.summary.installedBypass.length}`,
    `proxy_fingerprint=${fingerprintList(input.proxy)}`,
    `direct_fingerprint=${fingerprintList(input.direct)}`,
    `bypass_fingerprint=${fingerprintList(input.bypass)}`,
    `conflict_fingerprint=${fingerprintList(input.summary.conflicts)}`,
    "",
    "[insights]",
    ...input.summary.items.map((item) => `${item.label}=${item.value} (${item.tone})`)
  ].join("\n").trim();
}

export function formatAppPolicyFullReport(input: AppPolicySafeReportInput): string {
  return [
    "MagicNet app policy",
    "privacy_note=contains package names from app policy lists",
    `mode=${input.mode}`,
    `proxy_count=${input.proxy.length}`,
    `direct_count=${input.direct.length}`,
    `bypass_count=${input.bypass.length}`,
    `summary=${input.summary.summary}`,
    `conflict_count=${input.summary.conflicts.length}`,
    `current_list_proxy=${input.summary.installedProxy.length}`,
    `current_list_direct=${input.summary.installedDirect.length}`,
    `current_list_bypass=${input.summary.installedBypass.length}`,
    "",
    "[insights]",
    ...input.summary.items.map((item) => `${item.label}=${item.value} (${item.tone})`),
    "",
    "[proxy]",
    ...input.proxy,
    "",
    "[direct]",
    ...input.direct,
    "",
    "[bypass]",
    ...input.bypass
  ].join("\n").trim();
}

function insight(label: string, value: string, tone: AppPolicyInsight["tone"]): AppPolicyInsight {
  return { label, value, tone };
}

function fingerprintList(values: string[]): string {
  if (!values.length) return "none";
  return fnv32Hex(values.slice().sort().join("\n"));
}
