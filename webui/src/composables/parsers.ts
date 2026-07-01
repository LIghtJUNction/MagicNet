import { MODULE_DIR, SING_BOX_UI } from "@/constants";
import type { AppPolicy, BlocklistState, DnsState, HealthItem, PackageInfo, RuntimeState, TransparentMode, WarpState } from "@/types";

export type SubscriptionState = {
  singBox: string;
  singBoxUrls: string[];
};

export type McpState = {
  enabled: boolean;
  bind: string;
  port: string;
  pid: string;
  url: string;
  secretSet: boolean;
};

export type NetworkSnapshotSummary = {
  interfaces: number;
  ipRules: number;
  routes: number;
  natRules: number;
};

export type ConfigValidationState = {
  status: "idle" | "ok" | "error";
  summary: string;
  checkedAt: string;
};

export type RouteRuleSummary = {
  proxy: string[];
  direct: string[];
  block: string[];
  warp: string[];
};

export type ConnectionTarget = {
  id: string;
  label: string;
  source: string;
  network: string;
  inbound: string;
  rule: string;
  rulePayload: string;
  chain: string;
  process: string;
  detail: string;
  upload: number;
  download: number;
  totalBytes: number;
};

export type ConnectionBucket = {
  name: string;
  query: string;
  count: number;
  bytes: number;
};

export type ConnectionSnapshot = {
  count: number;
  uploadTotal: number;
  downloadTotal: number;
  connections: ConnectionTarget[];
};

export const runtimeDefaults: RuntimeState = {
  singBoxState: "unknown",
  singBox: "unknown",
  fswatch: "unknown",
  transparentMode: "tun",
  api: "http://127.0.0.1:9090",
  webui: SING_BOX_UI,
  subPath: `${MODULE_DIR}/.config/sing-box/subscription.url`
};

export const blockDefaults: BlocklistState = {
  enabled: true,
  community: true,
  url: "https://raw.githubusercontent.com/LIghtJUNction/MagicNet/main/src/MagicNet/.config/magicnet/community-ban.yaml",
  manual: [],
  communityRules: [],
  communityDomains: [],
  allowRules: [],
  newDomain: ""
};

export const mcpDefaults: McpState = {
  enabled: false,
  bind: "127.0.0.1",
  port: "8766",
  pid: "stopped",
  url: "http://127.0.0.1:8766/mcp",
  secretSet: false
};

export const dnsDefaults: DnsState = {
  profile: "default",
  primary: "bootstrap-local-dns",
  secondary: "",
  transport: "default"
};

export const warpDefaults: WarpState = {
  enabled: false,
  configured: false,
  tag: "warp",
  endpoint: "",
  addresses: 0,
  allowedIps: 0,
  importText: "",
  routeDomain: ""
};

export function normalizeTransparentMode(value: string): TransparentMode | null {
  const mode = value.trim().toLowerCase();
  if (mode === "external") return "external-tun";
  if (["proxy", "external-tun", "hybrid", "tun"].includes(mode)) return mode as TransparentMode;
  return null;
}

function normalizeRuntimeStatus(value: string): string {
  const status = value.trim();
  const compact = status.toLowerCase();
  if (!status) return "stopped";
  if (["stopped", "stop", "not installed", "not running", "not found", "missing"].includes(compact)) return "stopped";
  if (status.includes("已停止") || status.includes("未运行") || status.includes("未安装")) return "stopped";
  if (["running", "run"].includes(compact) || status.includes("正在运行")) return "running";
  return status;
}

export function parseRuntime(text: string, previous: RuntimeState): RuntimeState {
  const next = {
    ...runtimeDefaults,
    transparentMode: previous.transparentMode
  };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("sing-box:")) next.singBox = normalizeRuntimeStatus(line.slice(9));
    if (line.startsWith("fswatch:")) next.fswatch = normalizeRuntimeStatus(line.slice(8));
    if (line.startsWith("Transparent:")) {
      next.transparentMode = normalizeTransparentMode(line.slice(12)) || next.transparentMode;
    }
    if (line.startsWith("mode=")) {
      next.transparentMode = normalizeTransparentMode(line.slice(5)) || next.transparentMode;
    }
    if (line.startsWith("API:")) next.api = line.slice(4).trim() || next.api;
    if (line.startsWith("WebUI:")) next.webui = line.slice(6).trim() || next.webui;
    if (line.startsWith("Sub URL:")) next.subPath = line.slice(8).trim() || next.subPath;
  });
  if (next.singBox !== "stopped" && next.singBox !== "unknown") next.singBoxState = "sing-box";
  else if (next.singBox === "stopped") next.singBoxState = "stopped";
  return next;
}

export function parseHealth(text: string): HealthItem[] {
  return text.split(/\r?\n/).map((line) => {
    const match = line.trim().match(/^\[(ok|warn|fail|info)\]\s+([^:]+):?\s*(.*)$/i);
    if (!match) return null;
    return { status: match[1].toLowerCase() as HealthItem["status"], key: match[2].trim(), detail: match[3].trim() };
  }).filter((item): item is HealthItem => Boolean(item));
}

export function parseApps(text: string): AppPolicy {
  const policy: AppPolicy = { mode: "blacklist", proxy: [], bypass: [] };
  let section: "proxy" | "bypass" | null = null;
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (!line) return;
    if (line.startsWith("mode=")) policy.mode = line.includes("whitelist") ? "whitelist" : "blacklist";
    else if (line === "proxy apps:") section = "proxy";
    else if (line === "bypass apps:") section = "bypass";
    else if (section) policy[section].push(line);
  });
  return policy;
}

export function parsePackages(text: string): PackageInfo[] {
  return text.split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => /^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)+$/.test(line))
    .map((packageName) => ({
      packageName,
      versionName: "",
      versionCode: 0,
      appLabel: packageName,
      isSystem: false,
      uid: 0
    }));
}

export function parseNetworkSnapshotSummary(text: string): NetworkSnapshotSummary {
  const lines = text.split(/\r?\n/).map((line) => line.trim());
  return {
    interfaces: countSectionLines(lines, "[interfaces]", "[routes]"),
    ipRules: countSectionLines(lines, "ip rule:", "ip route:"),
    routes: countSectionLines(lines, "ip route:", "[forwarding]"),
    natRules: countSectionLines(lines, "[forwarding]", undefined)
  };
}

export function parseConfigValidation(text: string): Pick<ConfigValidationState, "status" | "summary"> {
  const trimmed = text.trim();
  if (!trimmed) return { status: "error", summary: "命令没有返回校验结果。" };
  if (/\[info\]\s+Saved and validated/i.test(trimmed)) {
    return { status: "ok", summary: firstUsefulLine(trimmed) || "配置已通过校验并保存。" };
  }
  if (/config validation failed|validator missing|config target must/i.test(trimmed)) {
    return { status: "error", summary: firstUsefulLine(trimmed) || "配置校验失败。" };
  }
  return { status: trimmed.includes("[error]") ? "error" : "ok", summary: firstUsefulLine(trimmed) || trimmed.slice(0, 160) };
}

export function parseRouteRuleSummary(text: string): RouteRuleSummary {
  const summary: RouteRuleSummary = { proxy: [], direct: [], block: [], warp: [] };
  let current: keyof RouteRuleSummary | null = null;
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (!line) return;
    const heading = line.toLowerCase();
    if (heading === "proxy domain suffixes:") current = "proxy";
    else if (heading === "direct domain suffixes:") current = "direct";
    else if (heading === "block domain suffixes:") current = "block";
    else if (heading === "warp domain suffixes:") current = "warp";
    else if (current && !line.endsWith(":")) summary[current].push(line);
  });
  return summary;
}

export function parseConnectionSnapshot(text: string): ConnectionSnapshot | null {
  try {
    const root = JSON.parse(text) as Record<string, unknown>;
    const rawConnections = Array.isArray(root.connections) ? root.connections : null;
    if (!rawConnections) return null;
    const connections = rawConnections
      .map(parseConnectionTarget)
      .filter((item): item is ConnectionTarget => Boolean(item))
      .filter((item, index, items) => items.findIndex((other) => other.id === item.id) === index)
      .sort((left, right) => right.totalBytes - left.totalBytes);
    return {
      count: rawConnections.length,
      uploadTotal: safeNumber(root.uploadTotal),
      downloadTotal: safeNumber(root.downloadTotal),
      connections
    };
  } catch {
    return null;
  }
}

export function connectionMatchesQuery(target: ConnectionTarget, query: string): boolean {
  const terms = query.split(/\s+/).map((item) => item.trim().toLowerCase()).filter(Boolean);
  if (!terms.length) return true;
  const haystack = [
    target.label,
    target.network,
    target.rule,
    target.rulePayload,
    target.chain,
    target.detail
  ].join(" ").toLowerCase();
  return terms.every((term) => haystack.includes(term));
}

export function connectionBuckets(connections: ConnectionTarget[], kind: "rule" | "chain" | "process"): ConnectionBucket[] {
  const seeds = connections
    .map((target) => {
      const name = bucketName(target, kind);
      if (!name) return null;
      return { name, query: kind === "chain" ? name.replace(/ > /g, " ") : name, bytes: target.totalBytes };
    })
    .filter((item): item is { name: string; query: string; bytes: number } => Boolean(item));
  return Object.values(
    seeds.reduce<Record<string, ConnectionBucket>>((acc, seed) => {
      acc[seed.name] ||= { name: seed.name, query: seed.query, count: 0, bytes: 0 };
      acc[seed.name].count += 1;
      acc[seed.name].bytes += seed.bytes;
      return acc;
    }, {})
  ).sort((left, right) => right.bytes - left.bytes || right.count - left.count).slice(0, 4);
}

function bucketName(target: ConnectionTarget, kind: "rule" | "chain" | "process"): string {
  if (kind === "rule") return [target.rule, target.rulePayload].filter(Boolean).join(" ");
  if (kind === "process") return target.process || target.inbound;
  return target.chain || target.network;
}

function parseConnectionTarget(value: unknown): ConnectionTarget | null {
  if (!value || typeof value !== "object") return null;
  const item = value as Record<string, unknown>;
  const metadata = (item.metadata && typeof item.metadata === "object" ? item.metadata : {}) as Record<string, unknown>;
  const id = stringValue(item.id);
  const host = stringValue(metadata.host);
  const destination = stringValue(metadata.destinationIP);
  const port = String(metadata.destinationPort ?? "");
  const target = host || destination;
  if (!id || !target) return null;
  const label = !port || port === "0" ? target : `${target}:${port}`;
  const chain = Array.isArray(item.chains) ? item.chains.map(stringValue).filter(Boolean).join(" > ") : "";
  const network = stringValue(metadata.network);
  const source = sourceLabel(metadata);
  const inbound = stringValue(item.inbound) || stringValue(metadata.inbound) || stringValue(metadata.type);
  const rule = stringValue(item.rule);
  const rulePayload = stringValue(item.rulePayload);
  const process = processLabel(metadata);
  const upload = safeNumber(item.upload);
  const download = safeNumber(item.download);
  return {
    id,
    label,
    source,
    network,
    inbound,
    rule,
    rulePayload,
    chain,
    process,
    detail: [process, source, inbound, network, rule, rulePayload, chain].filter(Boolean).join(" · ") || "direct",
    upload,
    download,
    totalBytes: upload + download
  };
}

function sourceLabel(metadata: Record<string, unknown>): string {
  const ip = stringValue(metadata.sourceIP) || stringValue(metadata.source);
  const port = String(metadata.sourcePort ?? "");
  if (!ip) return "";
  return port && port !== "0" ? `${ip}:${port}` : ip;
}

function processLabel(metadata: Record<string, unknown>): string {
  const packageName = stringValue(metadata.processPackageName);
  if (packageName) return packageName;
  const processName = stringValue(metadata.processName);
  if (processName) return processName;
  const path = stringValue(metadata.processPath);
  return path.split("/").filter(Boolean).at(-1) || "";
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function safeNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0;
}

function firstUsefulLine(text: string): string {
  return text.split(/\r?\n/).map((line) => line.trim()).find((line) => line && !line.startsWith("command:")) || "";
}

function countSectionLines(lines: string[], start: string, end: string | undefined): number {
  const startIndex = lines.findIndex((line) => line.toLowerCase() === start.toLowerCase());
  if (startIndex < 0) return 0;
  const relativeEnd = end
    ? lines.slice(startIndex + 1).findIndex((line) => line.toLowerCase() === end.toLowerCase())
    : -1;
  const endIndex = relativeEnd >= 0 ? startIndex + 1 + relativeEnd : lines.length;
  return lines
    .slice(startIndex + 1, endIndex)
    .filter((line) => line && !line.startsWith("[") && line !== "ip rule:" && line !== "ip route:")
    .length;
}

export function parseBlock(text: string, previous: BlocklistState): BlocklistState {
  const next: BlocklistState = { ...previous, manual: [], communityRules: [], communityDomains: [], allowRules: [] };
  let section: keyof Pick<BlocklistState, "manual" | "communityRules" | "communityDomains" | "allowRules"> | null = null;
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (!line) return;
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) !== "0";
    else if (line.startsWith("community=")) next.community = line.slice(10) !== "0";
    else if (line.startsWith("url=")) next.url = line.slice(4);
    else if (line === "manual domain suffixes:") section = "manual";
    else if (line === "community rules:") section = "communityRules";
    else if (line === "community domain suffixes:") section = "communityDomains";
    else if (line === "local allow rules:") section = "allowRules";
    else if (section) next[section].push(line);
  });
  return next;
}

export function parseSubs(text: string, previous: SubscriptionState): SubscriptionState {
  const next: SubscriptionState = { ...previous, singBoxUrls: [] };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (/^sing-box\.\d+=/.test(line)) next.singBoxUrls.push(line.replace(/^sing-box\.\d+=/, ""));
    else if (line.startsWith("sing-box=")) next.singBox = line.slice(9);
  });
  if (!next.singBoxUrls.length && next.singBox) next.singBoxUrls = [next.singBox];
  return next;
}

export function parseMcp(text: string, previous: McpState): McpState {
  const next = { ...previous };
  let explicitUrl = "";
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) !== "0";
    else if (line.startsWith("bind=")) next.bind = line.slice(5);
    else if (line.startsWith("port=")) next.port = line.slice(5);
    else if (line.startsWith("pid=")) next.pid = line.slice(4);
    else if (line.startsWith("secret_set=")) next.secretSet = line.slice(11) === "1";
    else if (line.startsWith("url=")) explicitUrl = line.slice(4);
  });
  next.url = explicitUrl || `http://${next.bind}:${next.port}/mcp`;
  return next;
}

export function parseDns(text: string, previous: DnsState): DnsState {
  const next = { ...previous };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("profile=")) {
      const profile = line.slice(8);
      if (["default", "cloudflare-doh", "cloudflare-dot", "cloudflare-udp"].includes(profile)) {
        next.profile = profile as DnsState["profile"];
      }
    } else if (line.startsWith("primary=")) next.primary = line.slice(8);
    else if (line.startsWith("secondary=")) next.secondary = line.slice(10);
    else if (line.startsWith("transport=")) next.transport = line.slice(10);
  });
  return next;
}

export function parseWarp(text: string, previous: WarpState): WarpState {
  const next = { ...previous };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) === "1";
    else if (line.startsWith("configured=")) next.configured = line.slice(11) === "1";
    else if (line.startsWith("tag=")) next.tag = line.slice(4) || "warp";
    else if (line.startsWith("endpoint=")) next.endpoint = line.slice(9);
    else if (line.startsWith("addresses=")) next.addresses = Number(line.slice(10)) || 0;
    else if (line.startsWith("allowed_ips=")) next.allowedIps = Number(line.slice(12)) || 0;
  });
  return next;
}
