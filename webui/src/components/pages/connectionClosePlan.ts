import { t } from "@/i18n";
import type { ConnectionTarget } from "@/composables/parsers";
import { formatConnectionBytes } from "./connectionInsights";
import { statusToneClasses } from "@/lib/statusTone";

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
    return plan("idle", t("没有活动连接"), t("刷新后可基于真实连接生成关闭计划。"), targets, allConnections, totalBytes, targetBytes, sharePercent);
  }
  if (!targets.length) {
    return plan("idle", t("没有命中连接"), t("当前条件没有可关闭的活动连接。"), targets, allConnections, totalBytes, targetBytes, sharePercent);
  }
  if (mode === "all") {
    return plan("danger", t("高风险关闭"), t("将断开全部 {value1} 条连接，应用可能立即重连。", { value1: targets.length }), targets, allConnections, totalBytes, targetBytes, sharePercent);
  }
  if (mode === "matched" && !query.trim()) {
    return plan("warning", t("需要过滤条件"), t("关闭命中连接前必须先输入过滤条件。"), [], allConnections, totalBytes, 0, 0);
  }
  if (sharePercent >= 60 || targets.length >= Math.max(8, Math.ceil(allConnections.length / 2))) {
    return plan("warning", t("影响范围较大"), t("将断开 {value1} 条连接，覆盖约 {value2}% 当前流量。", { value1: targets.length, value2: sharePercent }), targets, allConnections, totalBytes, targetBytes, sharePercent);
  }
  return plan("ok", t("影响可控"), t("将断开 {value1} 条连接，覆盖约 {value2}% 当前流量。", { value1: targets.length, value2: sharePercent }), targets, allConnections, totalBytes, targetBytes, sharePercent);
}

export function connectionClosePlanTone(status: ConnectionClosePlan["status"]): string {
  if (status === "danger") return statusToneClasses("danger");
  if (status === "warning") return statusToneClasses("warning");
  if (status === "ok") return statusToneClasses("ok");
  return statusToneClasses("neutral");

}

export function formatConnectionCloseDetail(plan: ConnectionClosePlan): string {
  return t("{value1} 目标流量 {value2} / {value3}。", { value1: plan.detail, value2: formatConnectionBytes(plan.targetBytes), value3: formatConnectionBytes(plan.totalBytes) });
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
