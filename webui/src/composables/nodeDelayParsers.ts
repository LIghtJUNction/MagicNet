import { t } from "@/i18n";
export type NodeDelayQuality = "fast" | "normal" | "slow" | "failed";

export type NodeDelayEntry = {
  node: string;
  summary: string;
  delayMillis: number | null;
  quality: NodeDelayQuality;
};

export type NodeDelayStats = {
  tested: number;
  usable: number;
  failed: number;
  fast: number;
  normal: number;
  slow: number;
  averageMillis: number | null;
  medianMillis: number | null;
  usablePercent: number;
  fastest: NodeDelayEntry | null;
  slowest: NodeDelayEntry | null;
};

const FAST_MAX_MS = 120;
const NORMAL_MAX_MS = 250;

export function parseNodeTestAll(text: string): NodeDelayEntry[] {
  const entries = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .map(parseNodeDelayLine)
    .filter((entry): entry is NodeDelayEntry => Boolean(entry));
  return Array.from(new Map(entries.map((entry) => [entry.node, entry])).values())
    .sort((left, right) => (left.delayMillis ?? Number.MAX_SAFE_INTEGER) - (right.delayMillis ?? Number.MAX_SAFE_INTEGER) || left.node.localeCompare(right.node));
}

export function parseCurrentNode(text: string): string {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line && !line.startsWith("["))
    || "";
}

/**
 * The genuinely lowest-latency usable entry, regardless of how the caller
 * ordered `entries`. Single definition shared by the stats panel and the
 * switch plan so the two can never disagree about "fastest".
 */
export function fastestEntry(entries: NodeDelayEntry[]): NodeDelayEntry | null {
  return extremeEntry(entries, (candidate, best) => candidate < best);
}

export function slowestEntry(entries: NodeDelayEntry[]): NodeDelayEntry | null {
  return extremeEntry(entries, (candidate, best) => candidate > best);
}

function extremeEntry(
  entries: NodeDelayEntry[],
  beats: (candidateMillis: number, bestMillis: number) => boolean
): NodeDelayEntry | null {
  let best: NodeDelayEntry | null = null;
  for (const entry of entries) {
    if (entry.delayMillis === null) continue;
    if (best === null || beats(entry.delayMillis, best.delayMillis as number)) best = entry;
  }
  return best;
}

export function buildNodeDelayStats(entries: NodeDelayEntry[]): NodeDelayStats {
  const usable = entries.filter((entry) => entry.delayMillis !== null);
  const averageMillis = usable.length
    ? Math.round(usable.reduce((total, entry) => total + (entry.delayMillis || 0), 0) / usable.length)
    : null;
  const medianMillis = usable.length ? medianDelay(usable.map((entry) => entry.delayMillis || 0)) : null;
  return {
    tested: entries.length,
    usable: usable.length,
    failed: entries.filter((entry) => entry.quality === "failed").length,
    fast: entries.filter((entry) => entry.quality === "fast").length,
    normal: entries.filter((entry) => entry.quality === "normal").length,
    slow: entries.filter((entry) => entry.quality === "slow").length,
    averageMillis,
    medianMillis,
    usablePercent: entries.length ? Math.round((usable.length / entries.length) * 100) : 0,
    fastest: fastestEntry(usable),
    slowest: slowestEntry(usable)
  };
}

export function nodeDelayHealthText(stats: NodeDelayStats): string {
  if (!stats.tested) return t("还没有测速结果。");
  if (!stats.usable) return t("全部节点测速失败，先检查订阅、网络或 sing-box 运行状态。");
  return t("{usable}/{tested} 个节点返回延迟，中位 {medianMillis}ms。测速未验证 HTTP 状态码或登录结果，低延迟不代表目标网站允许访问。", { usable: stats.usable, tested: stats.tested, medianMillis: stats.medianMillis ?? t("未知") });
}

export function nodeDelayQualityLabel(quality: NodeDelayQuality): string {
  if (quality === "fast") return t("快");
  if (quality === "normal") return t("正常");
  if (quality === "slow") return t("慢");
  return t("失败");
}

export function formatNodeDelayReport(entries: NodeDelayEntry[]): string {
  const stats = buildNodeDelayStats(entries);
  return [
    "MagicNet node delay report",
    "privacy_note=node names are omitted from this summary",
    `tested=${stats.tested}`,
    `usable=${stats.usable}`,
    `failed=${stats.failed}`,
    `average_ms=${stats.averageMillis ?? "none"}`,
    `median_ms=${stats.medianMillis ?? "none"}`,
    `parsed_usable_percent=${stats.usablePercent}`,
    `health=${nodeDelayHealthText(stats)}`,
    `fast=${stats.fast}`,
    `normal=${stats.normal}`,
    `slow=${stats.slow}`,
    `fastest_present=${stats.fastest ? 1 : 0}`,
    `slowest_present=${stats.slowest ? 1 : 0}`,
    `fastest_ms=${stats.fastest?.delayMillis ?? "none"}`,
    `slowest_ms=${stats.slowest?.delayMillis ?? "none"}`,
    "",
    ...entries.slice(0, 50).map((entry, index) => `${index + 1}. quality=${entry.quality} delay_ms=${entry.delayMillis ?? "none"}`)
  ].join("\n").trim();
}

export function sanitizeNodeText(value: string): string {
  return value
    .replace(/\b(?:https?|socks?|ss|ssr|vmess|vless|trojan|hysteria2?|tuic|anytls):\/\/[^\s"'<>]+/gi, "[filtered-url]")
    .replace(/\b(private_?key|password|passwd|token|secret|uuid|api[_-]?key)(\s*[:=]\s*)[^\s,;}\]]+/gi, "$1$2[filtered]");
}

function parseNodeDelayLine(line: string): NodeDelayEntry | null {
  const index = line.indexOf("=");
  if (index <= 0) return null;
  const node = line.slice(0, index).trim();
  const summary = line.slice(index + 1).trim();
  if (!node || !summary) return null;
  const delayMillis = parseNodeDelayMillis(summary);
  return {
    node,
    summary,
    delayMillis,
    quality: nodeDelayQuality(delayMillis)
  };
}

function parseNodeDelayMillis(value: string): number | null {
  const match = value.match(/\b(\d+)\s*ms\b/i);
  return match?.[1] ? Number(match[1]) : null;
}

function medianDelay(values: number[]): number {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  if (sorted.length % 2) return sorted[middle];
  return Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

function nodeDelayQuality(delayMillis: number | null): NodeDelayQuality {
  if (delayMillis === null) return "failed";
  if (delayMillis <= FAST_MAX_MS) return "fast";
  if (delayMillis <= NORMAL_MAX_MS) return "normal";
  return "slow";
}
