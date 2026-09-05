import type { SubscriptionSourceUsage, SubscriptionState } from "../types.ts";

export type SubscriptionUsageRow = {
  id: string;
  index: number;
  name: string;
  hostname: string;
  state: SubscriptionSourceUsage["state"];
  stateLabel: string;
  usedBytes: number | null;
  totalBytes: number | null;
  remainingBytes: number | null;
  progressPercent: number | null;
  usedLabel: string;
  totalLabel: string;
  remainingLabel: string;
  expiryLabel: string;
  expiryHint: string;
  updatedLabel: string;
  tone: "neutral" | "success" | "warning" | "danger";
  expired: boolean;
  daysRemaining: number | null;
};

function safeInteger(value: unknown, maximum = Number.MAX_SAFE_INTEGER): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= maximum
    ? value
    : null;
}

function safeHostname(value: unknown): string {
  if (typeof value !== "string" || !value || /[\s@/?#\\]/.test(value)) return "";
  try {
    const url = new URL(`https://${value}/`);
    return url.hostname === value.toLowerCase() ? url.hostname : "";
  } catch {
    return "";
  }
}

/** Only accept provider metadata; device connection counters never enter this model. */
export function parseSubscriptionSourceUsage(text: string | undefined): SubscriptionSourceUsage[] {
  if (!text) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const sources: SubscriptionSourceUsage[] = [];
  for (const value of parsed) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const index = safeInteger(value.index);
    if (!index || typeof value.id !== "string" || !/^[a-f0-9]{64}$/.test(value.id)) continue;
    const state = value.state === "fresh" || value.state === "cached" ? value.state : "unknown";
    const count = (field: unknown) => state === "unknown" ? null : safeInteger(field);
    // Bound dates to year 9999, avoiding Invalid Date and implausible overflow output.
    const epoch = (field: unknown) => state === "unknown" ? null : safeInteger(field, 253402300799);
    sources.push({
      id: value.id,
      index,
      hostname: safeHostname(value.hostname),
      state,
      uploadBytes: count(value.upload_bytes),
      downloadBytes: count(value.download_bytes),
      totalBytes: count(value.total_bytes),
      expireEpoch: epoch(value.expire_epoch),
      updatedEpoch: epoch(value.updated_epoch),
    });
  }
  // Ambiguous identities are discarded together, rather than choosing a row by order.
  return sources.filter((source) => sources.filter((other) => other.id === source.id || other.index === source.index).length === 1)
    .sort((a, b) => a.index - b.index);
}

export function formatSubscriptionBytes(bytes: number | null): string {
  if (bytes === null || safeInteger(bytes) === null) return "未提供";
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
  const index = bytes > 0 ? Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1) : 0;
  return `${new Intl.NumberFormat("zh-CN", { maximumFractionDigits: index ? 2 : 0 }).format(bytes / 1024 ** index)} ${units[index]}`;
}

function formatDate(epoch: number, includeTime = false): string {
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric", month: "2-digit", day: "2-digit",
    ...(includeTime ? { hour: "2-digit", minute: "2-digit", hour12: false } as const : {}),
  }).format(new Date(epoch * 1000));
}

function usageRow(source: SubscriptionSourceUsage, nowEpoch: number): SubscriptionUsageRow {
  const usedBytes = source.uploadBytes !== null && source.downloadBytes !== null
    ? safeInteger(source.uploadBytes + source.downloadBytes)
    : null;
  const hasQuota = source.totalBytes !== null && source.totalBytes > 0;
  const remainingBytes = hasQuota && usedBytes !== null ? Math.max(0, source.totalBytes! - usedBytes) : null;
  const progressPercent = hasQuota && usedBytes !== null ? Math.min(100, usedBytes / source.totalBytes! * 100) : null;
  const hasExpiry = source.expireEpoch !== null && source.expireEpoch > 0;
  const expired = hasExpiry && source.expireEpoch! <= nowEpoch;
  const daysRemaining = hasExpiry ? Math.max(0, Math.ceil((source.expireEpoch! - nowEpoch) / 86400)) : null;
  const expiryHint = !hasExpiry ? "服务商未提供到期信息"
    : expired ? "已到期"
    : daysRemaining === 1 ? "24 小时内到期"
    : `剩余 ${daysRemaining} 天`;
  return {
    id: source.id,
    index: source.index,
    name: `订阅 ${source.index}`,
    hostname: source.hostname,
    state: source.state,
    stateLabel: source.state === "fresh" ? "已同步" : source.state === "cached" ? "上次用量" : "未提供用量",
    usedBytes,
    totalBytes: source.totalBytes,
    remainingBytes,
    progressPercent,
    usedLabel: formatSubscriptionBytes(usedBytes),
    totalLabel: hasQuota ? formatSubscriptionBytes(source.totalBytes) : "未提供额度",
    remainingLabel: remainingBytes === null ? "未提供" : formatSubscriptionBytes(remainingBytes),
    expiryLabel: hasExpiry ? formatDate(source.expireEpoch!) : "未提供到期时间",
    expiryHint,
    updatedLabel: source.updatedEpoch ? formatDate(source.updatedEpoch, true) : "尚未获取",
    tone: expired || progressPercent === 100 ? "danger"
      : (progressPercent !== null && progressPercent >= 90) || (daysRemaining !== null && daysRemaining <= 3) ? "warning"
      : "neutral",
    expired,
    daysRemaining,
  };
}

export function buildSubscriptionUsageOverview(
  state: SubscriptionState,
  nowEpoch = Date.now() / 1000,
): SubscriptionUsageRow[] {
  if (state.sourceMode === "local") return [];
  // list and status are read separately. Keep labels and counters from the same
  // status snapshot; matching counters to list positions could mix two providers.
  const sources = state.sourceUsage.length ? state.sourceUsage : state.singBoxUrls.map((value, index) => {
    let hostname = "";
    try {
      const url = new URL(value);
      if (url.protocol === "https:" && !url.username && !url.password) hostname = safeHostname(url.hostname);
    } catch { /* The editor reports malformed URLs; overview keeps a private fallback. */ }
    return {
      id: `unknown-${index + 1}`, index: index + 1, hostname, state: "unknown" as const,
      uploadBytes: null, downloadBytes: null, totalBytes: null, expireEpoch: null, updatedEpoch: null,
    };
  });
  return sources.map((source) => usageRow(source, Number.isFinite(nowEpoch) ? nowEpoch : Date.now() / 1000));
}
