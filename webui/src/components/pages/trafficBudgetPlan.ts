import { t } from "@/i18n";
import { buildTrafficStatsSummary, type TrafficSample } from "@/composables/trafficStatsParsers";

export type TrafficBudgetPlan = {
  level: "idle" | "ok" | "warning" | "danger";
  label: string;
  detail: string;
  projectedBytes: number;
  averageTotalBytesPerSecond: number;
  remainingBytes: number;
  timeToBudgetSeconds: number | null;
  confidence: "none" | "low" | "normal";
  reportLines: string[];
};

const GIB = 1024 ** 3;

export function buildTrafficBudgetPlan(
  samples: TrafficSample[],
  budgetGiBInput: string,
  horizonMinutesInput: string
): TrafficBudgetPlan {
  const summary = buildTrafficStatsSummary(samples);
  const budgetGiB = parsePositiveNumber(budgetGiBInput);
  const horizonMinutes = parsePositiveNumber(horizonMinutesInput) ?? 60;
  const averageTotal = summary.averageUp + summary.averageDown;
  const projectedBytes = averageTotal * horizonMinutes * 60;
  const budgetBytes = budgetGiB !== null ? budgetGiB * GIB : 0;
  const remainingBytes = Math.max(0, budgetBytes - projectedBytes);
  const timeToBudgetSeconds = budgetBytes > 0 && averageTotal > 0 ? budgetBytes / averageTotal : null;
  const confidence = summary.sampleCount < 2 ? "none" : summary.sampleCount < 3 || summary.windowMillis < 30_000 ? "low" : "normal";

  if (budgetGiB === null) {
    return plan("idle", t("未设置预算"), t("输入剩余流量 GiB 后，可按真实采样速率估算消耗时间。"), projectedBytes, averageTotal, 0, timeToBudgetSeconds, confidence, summary.sampleCount, horizonMinutes);
  }
  if (!summary.latest) {
    return plan("idle", t("等待流量样本"), t("先采样一次或开启自动采样，预算预测才有数据基础。"), projectedBytes, averageTotal, remainingBytes, timeToBudgetSeconds, confidence, summary.sampleCount, horizonMinutes);
  }
  if (confidence !== "normal") {
    return plan("idle", t("样本不足，仅粗略估算"), t("已有样本窗口不足 30 秒；{horizonMinutes} 分钟消耗只作为瞬时速率外推，不做风险判定。", { horizonMinutes: horizonMinutes }), projectedBytes, averageTotal, remainingBytes, timeToBudgetSeconds, confidence, summary.sampleCount, horizonMinutes);
  }
  if (projectedBytes >= budgetBytes) {
    return plan("danger", t("预测会超出预算"), t("按当前平均速率，{horizonMinutes} 分钟内会用完输入预算。", { horizonMinutes: horizonMinutes }), projectedBytes, averageTotal, remainingBytes, timeToBudgetSeconds, confidence, summary.sampleCount, horizonMinutes);
  }
  if (projectedBytes >= budgetBytes * 0.7) {
    return plan("warning", t("接近预算上限"), t("按当前平均速率，{horizonMinutes} 分钟预计使用超过预算的 70%。", { horizonMinutes: horizonMinutes }), projectedBytes, averageTotal, remainingBytes, timeToBudgetSeconds, confidence, summary.sampleCount, horizonMinutes);
  }
  return plan("ok", t("预算压力较低"), t("按当前平均速率，{horizonMinutes} 分钟预计不会触及输入预算。", { horizonMinutes: horizonMinutes }), projectedBytes, averageTotal, remainingBytes, timeToBudgetSeconds, confidence, summary.sampleCount, horizonMinutes);
}

function plan(
  level: TrafficBudgetPlan["level"],
  label: string,
  detail: string,
  projectedBytes: number,
  averageTotalBytesPerSecond: number,
  remainingBytes: number,
  timeToBudgetSeconds: number | null,
  confidence: TrafficBudgetPlan["confidence"],
  sampleCount: number,
  horizonMinutes: number
): TrafficBudgetPlan {
  return {
    level,
    label,
    detail,
    projectedBytes,
    averageTotalBytesPerSecond,
    remainingBytes,
    timeToBudgetSeconds,
    confidence,
    reportLines: [
      `budget_level=${level}`,
      `budget_confidence=${confidence}`,
      `budget_sample_count=${sampleCount}`,
      `budget_horizon_minutes=${horizonMinutes}`,
      `budget_projected_bytes=${Math.round(projectedBytes)}`,
      `budget_average_total_bytes_per_second=${Math.round(averageTotalBytesPerSecond)}`,
      `budget_remaining_after_horizon_bytes=${Math.round(remainingBytes)}`,
      `budget_time_to_budget_seconds=${timeToBudgetSeconds === null ? "none" : Math.round(timeToBudgetSeconds)}`
    ]
  };
}

function parsePositiveNumber(value: string): number | null {
  const parsed = Number(value.trim());
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}
