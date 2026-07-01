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
    fastest: usable[0] || null,
    slowest: usable[usable.length - 1] || null
  };
}

export function nodeDelayHealthText(stats: NodeDelayStats): string {
  if (!stats.tested) return "还没有测速结果。";
  if (!stats.usable) return "全部节点测速失败，先检查订阅、网络或 sing-box 运行状态。";
  if (stats.usablePercent < 50) return `解析可用率 ${stats.usablePercent}%，节点池不稳定，不建议只按最快节点切换。`;
  if (stats.medianMillis !== null && stats.medianMillis <= FAST_MAX_MS) return `中位延迟 ${stats.medianMillis}ms，解析可用率 ${stats.usablePercent}%，节点池状态良好。`;
  if (stats.medianMillis !== null && stats.medianMillis <= NORMAL_MAX_MS) return `中位延迟 ${stats.medianMillis}ms，解析可用率 ${stats.usablePercent}%，可优先使用最快节点。`;
  return `中位延迟 ${stats.medianMillis ?? "未知"}ms，解析可用率 ${stats.usablePercent}%，建议继续筛选更低延迟节点。`;
}

export function nodeDelayQualityLabel(quality: NodeDelayQuality): string {
  if (quality === "fast") return "快";
  if (quality === "normal") return "正常";
  if (quality === "slow") return "慢";
  return "失败";
}

export function formatNodeDelayReport(entries: NodeDelayEntry[]): string {
  const stats = buildNodeDelayStats(entries);
  return [
    "MagicNet node delay report",
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
    `fastest=${stats.fastest ? `${sanitizeNodeText(stats.fastest.node)} ${sanitizeNodeText(stats.fastest.summary)}` : "none"}`,
    `slowest=${stats.slowest ? `${sanitizeNodeText(stats.slowest.node)} ${sanitizeNodeText(stats.slowest.summary)}` : "none"}`,
    "",
    ...entries.slice(0, 50).map((entry, index) => `${index + 1}. ${sanitizeNodeText(entry.node)} ${sanitizeNodeText(entry.summary)}`)
  ].join("\n").trim();
}

export function sanitizeNodeText(value: string): string {
  return value
    .replace(/\b(?:https?|socks?|ss|ssr|vmess|vless|trojan|hysteria2?|tuic):\/\/[^\s"'<>]+/gi, "[filtered-url]")
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
