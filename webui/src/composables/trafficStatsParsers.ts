export type TrafficSample = {
  up: number;
  down: number;
  timestampMillis: number;
  source: "json" | "kv";
  sourceKey: string;
};

export type TrafficStatsSummary = {
  latest: TrafficSample | null;
  averageUp: number;
  averageDown: number;
  peakUp: number;
  peakDown: number;
  sampleCount: number;
  windowMillis: number;
};

export function parseTrafficSample(text: string, timestampMillis = Date.now()): TrafficSample | null {
  const wholeJson = parseTrafficJson(text, timestampMillis);
  if (wholeJson) return wholeJson;
  for (const line of text.split(/\r?\n/).reverse()) {
    const sample = parseTrafficJson(line, timestampMillis);
    if (sample) return sample;
  }
  const kvLine = text.split(/\r?\n/).reverse().find((item) => /\bup\s*=/.test(item) && /\bdown\s*=/.test(item));
  if (kvLine) {
    const fields = Object.fromEntries(kvLine.split(/\s+/).map((part) => part.split("=", 2)).filter((pair) => pair.length === 2));
    const pair = trafficPair(fields);
    return pair ? { ...pair, timestampMillis, source: "kv" } : null;
  }
  return null;
}

export function buildTrafficStatsSummary(samples: TrafficSample[]): TrafficStatsSummary {
  return {
    latest: samples.at(-1) || null,
    averageUp: average(samples.map((sample) => sample.up)),
    averageDown: average(samples.map((sample) => sample.down)),
    peakUp: Math.max(0, ...samples.map((sample) => sample.up)),
    peakDown: Math.max(0, ...samples.map((sample) => sample.down)),
    sampleCount: samples.length,
    windowMillis: samples.length >= 2 ? Math.max(0, samples[samples.length - 1].timestampMillis - samples[0].timestampMillis) : 0
  };
}

export function formatTrafficStatsReport(samples: TrafficSample[]): string {
  const summary = buildTrafficStatsSummary(samples);
  return [
    "MagicNet traffic stats",
    `samples=${summary.sampleCount}`,
    `assumed_unit=bytes_per_second`,
    `parse_source=${summary.latest?.source || "none"}`,
    `parse_source_key=${summary.latest?.sourceKey || "none"}`,
    `window_seconds=${Math.round(summary.windowMillis / 1000)}`,
    `latest_up=${Math.round(summary.latest?.up || 0)}`,
    `latest_down=${Math.round(summary.latest?.down || 0)}`,
    `average_up=${Math.round(summary.averageUp)}`,
    `average_down=${Math.round(summary.averageDown)}`,
    `peak_up=${Math.round(summary.peakUp)}`,
    `peak_down=${Math.round(summary.peakDown)}`,
    "",
    "index,timestamp,source,up_bytes_per_second,down_bytes_per_second",
    ...samples.map((sample, index) => `${index + 1},${new Date(sample.timestampMillis).toISOString()},${sample.source},${Math.round(sample.up)},${Math.round(sample.down)}`)
  ].join("\n").trim();
}

function parseTrafficJson(text: string, timestampMillis: number): TrafficSample | null {
  try {
    const json = JSON.parse(text) as Record<string, unknown>;
    const pair = trafficPair(json);
    return pair ? { ...pair, timestampMillis, source: "json" } : null;
  } catch {
    return null;
  }
}

function trafficPair(fields: Record<string, unknown>): { up: number; down: number; sourceKey: string } | null {
  const pairs = [
    ["up", "down"],
    ["upload", "download"],
    ["uploadSpeed", "downloadSpeed"],
    ["upload_speed", "download_speed"]
  ];
  for (const [upKey, downKey] of pairs) {
    const up = numberValue(fields[upKey]);
    const down = numberValue(fields[downKey]);
    if (up !== null && down !== null) return { up, down, sourceKey: `${upKey}/${downKey}` };
  }
  return null;
}

function numberValue(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return Math.max(0, value);
  if (typeof value === "string") {
    const parsed = value.match(/([0-9]+(?:\.[0-9]+)?)\s*([kmgt]?b)?(?:\/s)?/i);
    if (!parsed) return null;
    const amount = Number(parsed[1]);
    if (!Number.isFinite(amount)) return null;
    const unit = (parsed[2] || "").toLowerCase();
    const scale = unit === "kb" ? 1024 : unit === "mb" ? 1024 ** 2 : unit === "gb" ? 1024 ** 3 : unit === "tb" ? 1024 ** 4 : 1;
    return Math.max(0, amount * scale);
  }
  return null;
}

function average(values: number[]): number {
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : 0;
}
