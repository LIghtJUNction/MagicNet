import { t } from "@/i18n";
import type { HealthItem } from "@/types";

export type HealthCheckSummary = {
  level: "idle" | "ok" | "warning" | "danger";
  label: string;
  detail: string;
  counts: Record<HealthItem["status"], number>;
  attention: HealthItem[];
};

const STATUS_ORDER: HealthItem["status"][] = ["fail", "warn", "info", "ok"];

export function summarizeHealthChecks(items: HealthItem[]): HealthCheckSummary {
  const counts = countByStatus(items);
  const attention = items
    .filter((item) => item.status === "fail" || item.status === "warn")
    .sort((left, right) => STATUS_ORDER.indexOf(left.status) - STATUS_ORDER.indexOf(right.status))
    .slice(0, 5);
  if (!items.length) {
    return {
      level: "idle",
      label: t("尚未运行健康检查"),
      detail: t("运行 health 后会按真实检查结果生成总览。"),
      counts,
      attention
    };
  }
  if (counts.fail) {
    return {
      level: "danger",
      label: t("{value1} 项失败", { value1: counts.fail }),
      detail: t("{value1} 需要优先处理。", { value1: attention.map((item) => item.key).join("、") || t("健康检查") }),
      counts,
      attention
    };
  }
  if (counts.warn) {
    return {
      level: "warning",
      label: t("{value1} 项警告", { value1: counts.warn }),
      detail: t("{value1} 建议检查。", { value1: attention.map((item) => item.key).join("、") || t("健康检查") }),
      counts,
      attention
    };
  }
  return {
    level: "ok",
    label: t("健康检查通过"),
    detail: t("{value1} 项真实检查没有失败或警告。", { value1: items.length }),
    counts,
    attention
  };
}

export function formatHealthCheckReport(items: HealthItem[], summary: HealthCheckSummary): string {
  return [
    "MagicNet health check summary",
    `level=${summary.level}`,
    `total=${items.length}`,
    `ok=${summary.counts.ok}`,
    `warn=${summary.counts.warn}`,
    `fail=${summary.counts.fail}`,
    `info=${summary.counts.info}`,
    "",
    "status,key",
    ...items.map((item) => `${item.status},${csvCell(item.key)}`)
  ].join("\n").trim();
}

function countByStatus(items: HealthItem[]): Record<HealthItem["status"], number> {
  return items.reduce<Record<HealthItem["status"], number>>((counts, item) => {
    counts[item.status] += 1;
    return counts;
  }, { ok: 0, warn: 0, fail: 0, info: 0 });
}

function csvCell(value: string): string {
  return value.includes(",") || value.includes("\"") ? `"${value.replace(/"/g, "\"\"")}"` : value;
}
