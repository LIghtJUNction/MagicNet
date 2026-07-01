import type { NodeDelayEntry } from "@/composables/nodeDelayParsers";
import type { ProxyGroupSummary } from "@/composables/proxyGroupParsers";

export type ProxySelectionPlan = {
  status: "ready" | "same" | "warning";
  summary: string;
  items: Array<{ label: string; value: string; tone: "success" | "warning" | "danger" | "neutral" }>;
  warnings: string[];
};

export function buildProxySelectionPlan(group: ProxyGroupSummary, node: string, delays: NodeDelayEntry[]): ProxySelectionPlan {
  const current = group.now || "";
  const inGroup = group.proxies.includes(node);
  const same = Boolean(current && current === node);
  const tested = delays.length;
  const usable = delays.filter((entry) => entry.delayMillis !== null).length;
  const targetDelay = delays.find((entry) => entry.node === node);
  const fastest = delays.find((entry) => entry.delayMillis !== null);
  const delta = targetDelay?.delayMillis !== null && targetDelay?.delayMillis !== undefined && fastest?.delayMillis !== null && fastest?.delayMillis !== undefined
    ? targetDelay.delayMillis - fastest.delayMillis
    : null;
  const warnings = [
    ...(!inGroup ? ["目标节点不在当前代理组列表中，API 可能拒绝切换。"] : []),
    ...(same ? ["目标节点已经是当前选择。"] : []),
    ...(!tested ? ["本组还没有测速结果，只能确认选择关系，不能判断延迟。"] : []),
    ...(tested && !targetDelay ? ["目标节点未包含在最近一次测速结果中。"] : []),
    ...(delta !== null && delta > 80 ? [`目标比最快节点慢 ${delta}ms，切换前建议确认用途。`] : [])
  ];
  const status = !inGroup || same || warnings.length ? "warning" : "ready";
  return {
    status,
    summary: same ? "不会改变当前选择。" : `将从 ${current || "未选择"} 切换到 ${node}。`,
    items: [
      item("组类型", group.type || "unknown", "neutral"),
      item("组内节点", `${group.proxies.length} 个`, group.proxies.length ? "success" : "warning"),
      item("当前", current || "未选择", current ? "neutral" : "warning"),
      item("目标延迟", targetDelayLabel(targetDelay), targetDelay?.delayMillis !== null && targetDelay?.delayMillis !== undefined ? delayTone(targetDelay.delayMillis) : "warning"),
      item("测速覆盖", tested ? `${tested}/${group.proxies.length} · 可用 ${usable}` : "未测速", tested ? "success" : "warning")
    ],
    warnings
  };
}

export function formatProxySelectionPlanReport(plan: ProxySelectionPlan): string {
  return [
    "MagicNet proxy selection plan",
    "privacy_note=group/node names and raw delay messages are omitted; only counts and delay classes are included",
    `status=${plan.status}`,
    `summary=${plan.summary ? "present" : "none"}`,
    `warning_count=${plan.warnings.length}`,
    "",
    "[items]",
    ...plan.items.map((item) => `${item.label}=${safeReportValue(item.label, item.value)} (${item.tone})`)
  ].join("\n").trim();
}

function delayTone(delayMillis: number): ProxySelectionPlan["items"][number]["tone"] {
  if (delayMillis <= 120) return "success";
  if (delayMillis <= 250) return "neutral";
  return "warning";
}

function targetDelayLabel(entry: NodeDelayEntry | undefined): string {
  if (!entry) return "未测速";
  if (entry.delayMillis === null) return "测速失败";
  return `${entry.delayMillis}ms`;
}

function safeReportValue(label: string, value: string): string {
  if (label === "当前") return value ? "present" : "none";
  if (label === "组类型") return value ? "present" : "unknown";
  if (label === "目标延迟") return delayClass(value);
  return /\d/.test(value) ? value.replace(/[^\d/ .·_-]/g, "") : value;
}

function delayClass(value: string): string {
  const match = value.match(/\b(\d+)\s*ms\b/i);
  if (!match?.[1]) return value === "未测速" ? "untested" : "unknown";
  const delay = Number(match[1]);
  if (delay <= 120) return "fast";
  if (delay <= 250) return "normal";
  return "slow";
}

function item(label: string, value: string, tone: ProxySelectionPlan["items"][number]["tone"]): ProxySelectionPlan["items"][number] {
  return { label, value, tone };
}
