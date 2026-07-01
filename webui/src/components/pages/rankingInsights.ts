export type RankingEntry = {
  rank?: number;
  name: string;
  amount?: string;
  message?: string;
  date?: string;
};

export type RankingData = {
  updatedAt: string;
  title: string;
  description: string;
  contactEmail: string;
  payment: {
    wechatUrl: string;
    alipayUrl: string;
    wechatQr?: string;
    alipayQr?: string;
    note?: string;
  };
  entries: RankingEntry[];
};

export type RankingInsight = {
  label: string;
  value: string;
  tone: "success" | "warning" | "danger" | "neutral";
};

export function buildRankingInsights(data: RankingData): RankingInsight[] {
  const completeRanks = hasCompleteRankSequence(data.entries);
  const validDates = data.entries.filter((entry) => parseEntryDate(entry.date) !== null).length;
  const latestDate = latestEntryDate(data.entries);
  return [
    insight("展示人数", `${data.entries.length} 位`, data.entries.length ? "success" : "warning"),
    insight("排名完整", completeRanks ? "1..N 唯一" : "需检查", completeRanks ? "success" : "warning"),
    insight("有效日期", `${validDates}/${data.entries.length}`, validDates === data.entries.length ? "success" : "neutral"),
    insight("最近支持", latestDate || "无", latestDate ? "success" : "neutral")
  ];
}

export function normalizeRankingData(value: unknown): RankingData {
  if (!isRecord(value)) throw new Error("ranking.json 根节点不是对象");
  if (!Array.isArray(value.entries)) throw new Error("ranking.json entries 必须是数组");
  const payment = isRecord(value.payment) ? value.payment : {};
  return {
    updatedAt: stringValue(value.updatedAt) || "unknown",
    title: stringValue(value.title) || "MagicNet 支持者排行榜",
    description: stringValue(value.description),
    contactEmail: stringValue(value.contactEmail),
    payment: {
      wechatUrl: stringValue(payment.wechatUrl),
      alipayUrl: stringValue(payment.alipayUrl),
      wechatQr: stringValue(payment.wechatQr),
      alipayQr: stringValue(payment.alipayQr),
      note: stringValue(payment.note)
    },
    entries: value.entries.map(normalizeRankingEntry)
  };
}

export function filterRankingEntries(entries: RankingEntry[], query: string): RankingEntry[] {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return entries;
  return entries.filter((entry) => {
    const text = [entry.rank, entry.name, entry.amount, entry.message, entry.date].filter(Boolean).join(" ").toLowerCase();
    return terms.every((term) => text.includes(term));
  });
}

export function formatRankingSnapshot(data: RankingData, entries: RankingEntry[]): string {
  const insights = buildRankingInsights(data);
  return [
    "MagicNet ranking snapshot",
    "privacy_note=includes public ranking names and messages only; payment QR URLs are omitted",
    `updated_at=${data.updatedAt}`,
    `entry_count=${data.entries.length}`,
    `filtered_count=${entries.length}`,
    "",
    "[insights]",
    ...insights.map((item) => `${item.label}=${item.value} (${item.tone})`),
    "",
    "[entries]",
    ...entries.map((entry) => [
      `rank=${entry.rank ?? "none"}`,
      `name=${entry.name}`,
      entry.amount ? `amount=${entry.amount}` : "",
      entry.date ? `date=${entry.date}` : "",
      entry.message ? `message=${entry.message}` : ""
    ].filter(Boolean).join(" "))
  ].join("\n").trim();
}

function latestEntryDate(entries: RankingEntry[]): string {
  return entries
    .map((entry) => ({ value: entry.date || "", time: parseEntryDate(entry.date) }))
    .filter((entry): entry is { value: string; time: number } => entry.time !== null)
    .sort((left, right) => right.time - left.time)[0]?.value || "";
}

function hasCompleteRankSequence(entries: RankingEntry[]): boolean {
  if (!entries.length) return false;
  const ranks = entries.map((entry) => entry.rank).filter((rank): rank is number => typeof rank === "number" && Number.isInteger(rank) && rank > 0);
  if (ranks.length !== entries.length) return false;
  const unique = new Set(ranks);
  if (unique.size !== entries.length) return false;
  return Array.from({ length: entries.length }, (_, index) => index + 1).every((rank) => unique.has(rank));
}

function parseEntryDate(value: string | undefined): number | null {
  if (!value || !/^\d{4}-\d{2}-\d{2}(?:T.*)?$/.test(value)) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? time : null;
}

function normalizeRankingEntry(value: unknown, index: number): RankingEntry {
  if (!isRecord(value)) throw new Error(`entries[${index}] 必须是对象`);
  const name = stringValue(value.name);
  if (!name) throw new Error(`entries[${index}].name 必须是字符串`);
  const rank = Number(value.rank);
  return {
    rank: Number.isInteger(rank) && rank > 0 ? rank : undefined,
    name,
    amount: stringValue(value.amount),
    message: stringValue(value.message),
    date: stringValue(value.date)
  };
}

function insight(label: string, value: string, tone: RankingInsight["tone"]): RankingInsight {
  return { label, value, tone };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}
