import type { ConnectionTarget } from "@/composables/parsers";
import { formatConnectionBytes } from "./connectionInsights";

export type ConnectionClosePlan = {
  status: "idle" | "ok" | "warning" | "danger";
  title: string;
  detail: string;
  targetCount: number;
  targetBytes: number;
  totalCount: number;
  totalBytes: number;
  sharePercent: number;
};

export function buildConnectionClosePlan(
  mode: "top" | "matched" | "all",
  targets: ConnectionTarget[],
  allConnections: ConnectionTarget[],
  query = ""
): ConnectionClosePlan {
  const totalBytes = sumBytes(allConnections);
  const targetBytes = sumBytes(targets);
  const sharePercent = totalBytes ? Math.round((targetBytes / totalBytes) * 100) : 0;
  if (!allConnections.length) {
    return plan("idle", "没有活动连接", "刷新后可基于真实连接生成关闭计划。", targets, allConnections, totalBytes, targetBytes, sharePercent);
  }
  if (!targets.length) {
    return plan("idle", "没有命中连接", "当前条件没有可关闭的活动连接。", targets, allConnections, totalBytes, targetBytes, sharePercent);
  }
  if (mode === "all") {
    return plan("danger", "高风险关闭", `将断开全部 ${targets.length} 条连接，应用可能立即重连。`, targets, allConnections, totalBytes, targetBytes, sharePercent);
  }
  if (mode === "matched" && !query.trim()) {
    return plan("warning", "需要过滤条件", "关闭命中连接前必须先输入过滤条件。", [], allConnections, totalBytes, 0, 0);
  }
  if (sharePercent >= 60 || targets.length >= Math.max(8, Math.ceil(allConnections.length / 2))) {
    return plan("warning", "影响范围较大", `将断开 ${targets.length} 条连接，覆盖约 ${sharePercent}% 当前流量。`, targets, allConnections, totalBytes, targetBytes, sharePercent);
  }
  return plan("ok", "影响可控", `将断开 ${targets.length} 条连接，覆盖约 ${sharePercent}% 当前流量。`, targets, allConnections, totalBytes, targetBytes, sharePercent);
}

export function connectionClosePlanTone(status: ConnectionClosePlan["status"]): string {
  if (status === "danger") return "border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] bg-[color-mix(in_srgb,var(--mn-coral)_55%,white)] text-[var(--mn-danger)]";
  if (status === "warning") return "border-[color-mix(in_srgb,var(--mn-oat)_70%,transparent)] bg-[color-mix(in_srgb,var(--mn-oat)_55%,white)] text-[var(--mn-warning)]";
  if (status === "ok") return "border-[color-mix(in_srgb,var(--mn-cactus)_50%,transparent)] bg-[color-mix(in_srgb,var(--mn-cactus)_40%,white)] text-[var(--mn-success)]";
  return "border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] text-[var(--mn-ink-muted)]";
}

export function formatConnectionCloseDetail(plan: ConnectionClosePlan): string {
  return `${plan.detail} 目标流量 ${formatConnectionBytes(plan.targetBytes)} / ${formatConnectionBytes(plan.totalBytes)}。`;
}

function plan(
  status: ConnectionClosePlan["status"],
  title: string,
  detail: string,
  targets: ConnectionTarget[],
  allConnections: ConnectionTarget[],
  totalBytes: number,
  targetBytes: number,
  sharePercent: number
): ConnectionClosePlan {
  return {
    status,
    title,
    detail,
    targetCount: targets.length,
    targetBytes,
    totalCount: allConnections.length,
    totalBytes,
    sharePercent
  };
}

function sumBytes(connections: ConnectionTarget[]): number {
  return connections.reduce((sum, item) => sum + item.totalBytes, 0);
}
