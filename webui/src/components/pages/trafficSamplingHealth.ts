import { t } from "@/i18n";
import type { TrafficSample } from "@/composables/trafficStatsParsers";

export type TrafficSamplingHealth = {
  level: "idle" | "ok" | "warning" | "danger";
  label: string;
  detail: string;
  latestAgeSeconds: number | null;
  sampleCount: number;
  consecutiveFailures: number;
};

export function evaluateTrafficSamplingHealth(
  samples: TrafficSample[],
  consecutiveFailures: number,
  autoSampling: boolean,
  nowMillis = Date.now()
): TrafficSamplingHealth {
  const latest = samples.at(-1) || null;
  const latestAgeSeconds = latest ? Math.max(0, Math.round((nowMillis - latest.timestampMillis) / 1000)) : null;
  if (consecutiveFailures >= 3) {
    return health(
      "danger",
      t("采样已失效"),
      autoSampling
        ? t("连续 3 次以上未解析到真实流量，自动采样会暂停。")
        : t("连续 3 次以上未解析到真实流量，请检查 api stats 输出。"),
      latestAgeSeconds,
      samples.length,
      consecutiveFailures
    );
  }
  if (!latest) {
    return health(
      "idle",
      t("等待采样"),
      t("还没有可用于趋势和告警判断的真实样本。"),
      latestAgeSeconds,
      samples.length,
      consecutiveFailures
    );
  }
  if (latestAgeSeconds !== null && latestAgeSeconds > 60) {
    return health(
      "warning",
      t("样本已陈旧"),
      t("最近样本是 {latestAgeSeconds}s 前的数据，建议重新采样。", { latestAgeSeconds: latestAgeSeconds }),
      latestAgeSeconds,
      samples.length,
      consecutiveFailures
    );
  }
  if (autoSampling && latestAgeSeconds !== null && latestAgeSeconds > 15) {
    return health(
      "warning",
      t("自动采样滞后"),
      t("自动采样开启但最近样本已滞后 {latestAgeSeconds}s。", { latestAgeSeconds: latestAgeSeconds }),
      latestAgeSeconds,
      samples.length,
      consecutiveFailures
    );
  }
  if (consecutiveFailures > 0) {
    return health(
      "warning",
      t("最近有失败"),
      t("最近连续 {consecutiveFailures} 次未解析成功，当前仍保留上一批样本。", { consecutiveFailures: consecutiveFailures }),
      latestAgeSeconds,
      samples.length,
      consecutiveFailures
    );
  }
  if (samples.length < 3) {
    return health(
      "idle",
      t("样本不足"),
      t("至少 3 个样本后趋势和持续告警更可信。"),
      latestAgeSeconds,
      samples.length,
      consecutiveFailures
    );
  }
  return health(
    "ok",
    t("采样正常"),
    autoSampling ? t("自动采样正在提供可用趋势窗口。") : t("手动样本可用于当前速率判断。"),
    latestAgeSeconds,
    samples.length,
    consecutiveFailures
  );
}

function health(
  level: TrafficSamplingHealth["level"],
  label: string,
  detail: string,
  latestAgeSeconds: number | null,
  sampleCount: number,
  consecutiveFailures: number
): TrafficSamplingHealth {
  return { level, label, detail, latestAgeSeconds, sampleCount, consecutiveFailures };
}
