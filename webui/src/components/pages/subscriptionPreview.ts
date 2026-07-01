export type SubscriptionPreview = {
  key: string;
  index: number;
  label: string;
  status: "ok" | "duplicate" | "invalid" | "over-limit";
  notes: string[];
};

export type SubscriptionInputSummary = {
  raw: number;
  valid: number;
  duplicate: number;
  overLimit: number;
};

export function summarizeSubscriptionInput(text: string, limit = 5): SubscriptionInputSummary {
  const raw = subscriptionLines(text);
  const valid = raw.filter(isHttpUrl);
  return {
    raw: raw.length,
    valid: valid.length,
    duplicate: Math.max(0, raw.length - uniqueNonEmpty(raw).length),
    overLimit: Math.max(0, uniqueNonEmpty(raw).length - limit)
  };
}

export function buildSubscriptionPreview(text: string, limit = 5): SubscriptionPreview[] {
  const seen = new Set<string>();
  return subscriptionLines(text).map((line, index) => previewSubscriptionLine(line, index, seen, limit));
}

export function formatSubscriptionSummary(text: string, previews: SubscriptionPreview[]): string {
  const summary = summarizeSubscriptionInput(text);
  const omitted = Math.max(0, summary.raw - previews.length);
  return [
    "MagicNet subscription input summary",
    "privacy_note=full subscription URLs are omitted",
    `raw=${summary.raw}`,
    `valid=${summary.valid}`,
    `duplicate=${summary.duplicate}`,
    `over_limit=${summary.overLimit}`,
    `preview_count=${previews.length}`,
    `omitted_count=${omitted}`,
    "",
    "[sources]",
    ...previews.map((item) => `#${item.index} ${item.label} status=${item.status} notes=${item.notes.join(";")}`)
  ].join("\n").trim();
}

function previewSubscriptionLine(line: string, index: number, seen: Set<string>, limit: number): SubscriptionPreview {
  try {
    const url = new URL(line);
    const normalized = url.toString();
    const duplicate = seen.has(normalized);
    seen.add(normalized);
    const protocolOk = url.protocol === "http:" || url.protocol === "https:";
    const notes = [
      url.search || url.hash ? "含参数，界面已隐藏" : "无 query/hash",
      url.pathname.length > 1 ? "含路径，界面已隐藏" : "无路径",
      url.protocol === "http:" ? "非 HTTPS" : ""
    ].filter(Boolean);
    return {
      key: `${index}-${url.hostname}`,
      index: index + 1,
      label: protocolOk ? `${url.protocol}//${url.hostname}` : "协议不支持",
      status: !protocolOk ? "invalid" : index >= limit ? "over-limit" : duplicate ? "duplicate" : "ok",
      notes
    };
  } catch {
    return {
      key: `${index}-invalid`,
      index: index + 1,
      label: "无法解析 URL",
      status: "invalid",
      notes: ["必须是一行一个 http(s) URL"]
    };
  }
}

function subscriptionLines(text: string): string[] {
  return text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
}

function isHttpUrl(line: string): boolean {
  return /^https?:\/\/\S+$/i.test(line);
}

function uniqueNonEmpty(values: string[]): string[] {
  return Array.from(new Set(values.filter(Boolean)));
}
