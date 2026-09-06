import { t } from "@/i18n";
import type { ConnectionTarget } from "@/composables/parsers";

export type ConnectionInsight = {
  label: string;
  value: string;
  detail: string;
  tone: "success" | "warning" | "danger" | "neutral";
};

export function buildConnectionInsights(
  allConnections: ConnectionTarget[],
  visibleConnections: ConnectionTarget[],
  query: string
): ConnectionInsight[] {
  const totalBytes = sumBytes(allConnections);
  const visibleBytes = sumBytes(visibleConnections);
  const largest = allConnections[0];
  const topProcess = topBy(allConnections, (item) => item.process || item.inbound || t("unknown"));
  const topRule = topBy(allConnections, (item) => [item.rule, item.rulePayload].filter(Boolean).join(" ") || t("unknown"));
  return [
    insight(
      t("最大流量连接"),
      largest ? formatConnectionBytes(largest.totalBytes) : "-",
      largest ? largest.label : t("暂无连接"),
      largest && totalBytes && largest.totalBytes / totalBytes > 0.5 ? "warning" : "neutral"
    ),
    insight(
      query.trim() ? t("过滤命中流量") : t("当前显示流量"),
      totalBytes ? `${Math.round((visibleBytes / totalBytes) * 100)}%` : "-",
      `${formatConnectionBytes(visibleBytes)} / ${formatConnectionBytes(totalBytes)}`,
      query.trim() && visibleConnections.length ? "success" : "neutral"
    ),
    insight(
      t("Top 流量应用"),
      topProcess ? formatConnectionBytes(topProcess.bytes) : "-",
      topProcess ? t("{value1} · {value2} 条", { value1: topProcess.name, value2: topProcess.count }) : t("暂无应用信息"),
      topProcess && totalBytes && topProcess.bytes / totalBytes > 0.6 ? "warning" : "neutral"
    ),
    insight(
      t("Top 流量规则"),
      topRule ? formatConnectionBytes(topRule.bytes) : "-",
      topRule ? t("{value1} · {value2} 条", { value1: topRule.name, value2: topRule.count }) : t("暂无规则信息"),
      topRule && totalBytes && topRule.bytes / totalBytes > 0.6 ? "warning" : "neutral"
    )
  ];
}

export function formatConnectionBytes(value: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let amount = Math.max(0, value);
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  return unit === 0 ? `${Math.round(amount)} ${units[unit]}` : `${amount.toFixed(1)} ${units[unit]}`;
}

function topBy(connections: ConnectionTarget[], keyOf: (item: ConnectionTarget) => string): { name: string; count: number; bytes: number } | null {
  const buckets = connections.reduce<Record<string, { name: string; count: number; bytes: number }>>((acc, item) => {
    const name = keyOf(item);
    acc[name] ||= { name, count: 0, bytes: 0 };
    acc[name].count += 1;
    acc[name].bytes += item.totalBytes;
    return acc;
  }, {});
  return Object.values(buckets).sort((left, right) => right.bytes - left.bytes || right.count - left.count)[0] || null;
}

function sumBytes(connections: ConnectionTarget[]): number {
  return connections.reduce((sum, item) => sum + item.totalBytes, 0);
}

function insight(label: string, value: string, detail: string, tone: ConnectionInsight["tone"]): ConnectionInsight {
  return { label, value, detail, tone };
}
