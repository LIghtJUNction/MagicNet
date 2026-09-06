import { t } from "@/i18n";
export type ApiEndpointProbe = {
  key: string;
  label: string;
  command: string;
  ok: boolean;
  durationMillis: number;
  outputBytes: number;
  summary: string;
};

export type ApiProbeKey = "groups" | "stats" | "connections";

export type ApiEndpointProbeSummary = {
  level: "idle" | "ok" | "warning" | "danger";
  label: string;
  detail: string;
  totalMillis: number;
  slowest: ApiEndpointProbe | null;
  failed: ApiEndpointProbe[];
};

export function summarizeApiEndpointProbes(probes: ApiEndpointProbe[]): ApiEndpointProbeSummary {
  if (!probes.length) {
    return {
      level: "idle",
      label: t("尚未预检 API"),
      detail: t("运行后会真实调用 sing-box API helpers 并记录耗时。"),
      totalMillis: 0,
      slowest: null,
      failed: []
    };
  }
  const failed = probes.filter((probe) => !probe.ok);
  const slowest = probes.reduce<ApiEndpointProbe | null>((current, probe) => {
    if (!current || probe.durationMillis > current.durationMillis) return probe;
    return current;
  }, null);
  const totalMillis = probes.reduce((sum, probe) => sum + probe.durationMillis, 0);
  if (failed.length) {
    return {
      level: "danger",
      label: t("{length} 个 API 端点失败", { length: failed.length }),
      detail: failed.map((probe) => t(probe.label)).join("、"),
      totalMillis,
      slowest,
      failed
    };
  }
  if (slowest && slowest.durationMillis >= 1800) {
    return {
      level: "warning",
      label: t("API 响应偏慢"),
      detail: t("{label} 耗时 {durationMillis}ms。", { label: t(slowest.label), durationMillis: slowest.durationMillis }),
      totalMillis,
      slowest,
      failed
    };
  }
  return {
    level: "ok",
    label: t("API 端点响应正常"),
    detail: t("{length} 个端点均返回成功。", { length: probes.length }),
    totalMillis,
    slowest,
    failed
  };
}

export function formatApiEndpointProbeReport(probes: ApiEndpointProbe[], summary: ApiEndpointProbeSummary): string {
  return [
    "MagicNet API endpoint probes",
    `level=${summary.level}`,
    `total_millis=${Math.round(summary.totalMillis)}`,
    `failed=${summary.failed.length}`,
    `slowest=${summary.slowest ? summary.slowest.key : "none"}`,
    "",
    "key,label,ok,duration_millis,output_bytes,summary",
    ...probes.map((probe) => [
      probe.key,
      t(probe.label),
      probe.ok ? "1" : "0",
      Math.round(probe.durationMillis),
      probe.outputBytes,
      probe.summary.replace(/[\r\n,]+/g, " ").slice(0, 160)
    ].join(","))
  ].join("\n").trim();
}

export function validateApiProbeOutput(key: ApiProbeKey, text: string): boolean {
  let json: unknown;
  try {
    json = JSON.parse(text.trim());
  } catch {
    return false;
  }
  if (!isRecord(json)) return false;
  if (key === "groups") return isRecord(json.providers) || isRecord(json.proxies);
  if (key === "stats") return hasNumber(json, "up") && hasNumber(json, "down");
  if (key === "connections") return Array.isArray(json.connections);
  return false;
}

export function summarizeApiProbeOutput(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return t("无输出");
  try {
    const json = JSON.parse(trimmed);
    if (Array.isArray(json)) return `JSON array items=${json.length}`;
    if (json && typeof json === "object") return `JSON object key_count=${Object.keys(json).length}`;
  } catch {
    // Keep the summary shape-only so reports do not copy endpoint payloads.
  }
  return `text lines=${trimmed.split(/\r?\n/).length} chars=${trimmed.length}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function hasNumber(value: Record<string, unknown>, key: string): boolean {
  return typeof value[key] === "number" && Number.isFinite(value[key]);
}
