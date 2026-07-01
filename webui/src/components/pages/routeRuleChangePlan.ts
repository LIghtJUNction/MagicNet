import type { RouteRuleSummary } from "@/composables/parsers";

export type RouteRuleTarget = keyof RouteRuleSummary;

export type RouteRuleChangePlan = {
  action: "add" | "remove";
  target: RouteRuleTarget;
  domain: string;
  existed: boolean;
  beforeCount: number;
  afterCount: number;
  sourceFresh: boolean;
  restart: boolean;
  items: Array<{ label: string; value: string; tone: "success" | "warning" | "danger" | "neutral" }>;
  warnings: string[];
};

export function buildRouteRuleChangePlan(summary: RouteRuleSummary, target: RouteRuleTarget, domain: string, action: "add" | "remove"): RouteRuleChangePlan {
  const current = unique(summary[target] || []);
  const sourceFresh = totalRules(summary) > 0;
  const existed = current.includes(domain);
  const beforeCount = current.length;
  const afterCount = action === "add"
    ? (existed ? beforeCount : beforeCount + 1)
    : (existed ? beforeCount - 1 : beforeCount);
  const noop = (action === "add" && existed) || (action === "remove" && !existed);
  const warnings = [
    ...(!sourceFresh ? ["当前没有可用 route list 快照；确认执行仍会以设备端真实文件为准。"] : ["页面只显示上次 route list 快照计数，不预测最终增删结果；执行后会重新回读。"]),
    ...(noop ? [action === "add" ? "上次快照显示该域名后缀已在目标列表中，执行会以设备端真实文件为准并重新应用。" : "上次快照显示该域名后缀不在目标列表中，执行会以设备端真实文件为准并重新应用。"] : []),
    ...(target === "warp" ? ["WARP 路由变更会写入 route-warp-domain-suffix.list，并触发 route apply 与当前 core 重启。"] : [])
  ];
  return {
    action,
    target,
    domain,
    existed,
    beforeCount,
    afterCount,
    sourceFresh,
    restart: true,
    items: [
      item("Target", target, "neutral"),
      item("Action", action, noop ? "neutral" : "warning"),
      item("Snapshot count", sourceFresh ? `${beforeCount}` : "unknown", "neutral"),
      item("Snapshot", sourceFresh ? "last route list" : "missing", sourceFresh ? "neutral" : "warning"),
      item("Apply", "write -> route apply -> restart", "warning")
    ],
    warnings
  };
}

export function formatRouteRuleChangePlanReport(plan: RouteRuleChangePlan): string {
  return [
    "MagicNet route rule change plan",
    "privacy_note=domain suffix omitted; no domain fingerprint is included",
    `target=${plan.target}`,
    `action=${plan.action}`,
    `source_snapshot=${plan.sourceFresh ? "present" : "missing"}`,
    `restart=${plan.restart ? 1 : 0}`
  ].join("\n");
}

function unique(values: string[]): string[] {
  return Array.from(new Set(values.filter(Boolean)));
}

function totalRules(summary: RouteRuleSummary): number {
  return summary.proxy.length + summary.direct.length + summary.block.length + summary.warp.length;
}

function item(label: string, value: string, tone: RouteRuleChangePlan["items"][number]["tone"]): RouteRuleChangePlan["items"][number] {
  return { label, value, tone };
}
