import { t } from "@/i18n";
import { MODULE_DIR, SING_BOX_UI } from "../constants.ts";
import type {
  AppPolicy,
  BlocklistState,
  ConfigValidationState,
  DnsState,
  HealthItem,
  McpState,
  PackageInfo,
  RouteRuleSummary,
  RuntimeState,
  SubscriptionState,
  TransparentMode,
  WarpState,
  WifiPolicyState,
} from "../types.ts";

export type {
  SubscriptionState,
  McpState,
  ConfigValidationState,
  RouteRuleSummary,
};

export const subscriptionDefaults: SubscriptionState = {
  singBox: "",
  singBoxUrls: [],
  sourceUsage: [],
  userAgent: "",
  filters: [],
  configuredCount: 0,
  sourceMode: "url",
  updateRunning: false,
  updateLockOwner: "none",
  lastPhase: "never",
  lastResult: "never",
  lastAttemptEpoch: 0,
  lastSuccessEpoch: 0,
  lastConfiguredCount: 0,
  lastSourceCount: 0,
  lastImportedCount: 0,
  lastSkippedCount: 0,
  lastGenerationId: "none",
  lastReason: "none",
  cacheCount: 0,
  cacheProvenanceCount: 0,
  cacheSource: "unknown",
  scheduleIntervalHours: "off",
  scheduleEnabled: false,
  scheduleRunning: false,
  scheduleOwner: "none",
  scheduleOwnerValid: true,
  refreshEventCount: 0,
  refreshErrorCount: 0,
};

export type NetworkSnapshotSummary = {
  interfaces: number;
  ipRules: number;
  routes: number;
  natRules: number;
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

export type ConnectionFlowSummary = {
  proxied: number;
  direct: number;
  blocked: number;
  unknown: number;
};

export type ConnectionSnapshot = {
  /** Raw connection count as reported by sing-box, before dedup/filtering. */
  count: number;
  uploadTotal: number;
  downloadTotal: number;
  connections: ConnectionTarget[];
};

export const runtimeDefaults: RuntimeState = {
  singBoxState: "unknown",
  singBox: "unknown",
  singBoxRssKib: null,
  serviceReady: null,
  fswatch: "unknown",
  transparentMode: "unknown",
  transparentEffectiveMode: "unknown",
  transparentCapability: "unknown",
  transparentLocalCgroup: "unknown",
  transparentSharedTc: "unknown",
  transparentSharedInterfaces: [],
  transparentSharedInterfaceCount: null,
  transparentRecentError: "",
  transparentTransition: "unknown",
  api: "",
  webui: SING_BOX_UI,
  subPath: `${MODULE_DIR}/.config/sing-box/subscription.url`,
};

export const blockDefaults: BlocklistState = {
  enabled: true,
  community: true,
  url: "https://raw.githubusercontent.com/LIghtJUNction/MagicNet/main/src/MagicNet/.config/magicnet/community-ban.yaml",
  manual: [],
  communityRules: [],
  communityDomains: [],
  allowRules: [],
  newDomain: "",
};

export const mcpDefaults: McpState = {
  enabled: false,
  bind: "127.0.0.1",
  port: "8766",
  pid: "stopped",
  url: "http://127.0.0.1:8766/mcp",
  secretSet: false,
  portOwner: "",
};

function isMcpIpv4Literal(value: string): boolean {
  const octets = value.split(".");
  return (
    octets.length === 4 &&
    octets.every(
      (octet) => /^(0|[1-9]\d{0,2})$/.test(octet) && Number(octet) <= 255,
    )
  );
}

function isMcpIpv6Literal(value: string): boolean {
  if (!value.includes(":") || !/^[0-9a-f:.]+$/i.test(value)) return false;
  try {
    return new URL(`http://[${value}]/`).hostname.startsWith("[");
  } catch {
    return false;
  }
}

/** Match the backend's bare-IP-literal MCP bind contract. */
export function isMcpIpLiteral(value: string): boolean {
  const bind = value.trim();
  return isMcpIpv4Literal(bind) || isMcpIpv6Literal(bind);
}

export function isValidMcpPort(value: string): boolean {
  const port = value.trim();
  const portNumber = Number(port);
  return (
    /^\d+$/.test(port) &&
    Number.isInteger(portNumber) &&
    portNumber >= 1 &&
    portNumber <= 65535
  );
}

/** Render a device endpoint without producing an ambiguous IPv6 host:port. */
export function formatMcpHostPort(bind: string, port: string): string {
  const host = bind.trim();
  const normalizedPort = port.trim();
  return isMcpIpv6Literal(host)
    ? `[${host}]:${normalizedPort}`
    : `${host}:${normalizedPort}`;
}

export function formatMcpUrl(bind: string, port: string): string {
  return `http://${formatMcpHostPort(bind, port)}/mcp`;
}

export const dnsDefaults: DnsState = {
  profile: "default",
  primary: "bootstrap-local-dns",
  secondary: "",
  transport: "default",
};

export const warpDefaults: WarpState = {
  enabled: false,
  configured: false,
  tag: "warp",
  endpoint: "",
  addresses: 0,
  allowedIps: 0,
  importText: "",
  routeDomain: "",
};

export const wifiPolicyDefaults: WifiPolicyState = {
  observed: false,
  enabled: false,
  policyMode: "blacklist",
  intervalSeconds: 5,
  supervisor: "stopped",
  connected: false,
  ssid: "",
  bssid: "",
  matched: false,
  desiredMode: "rule",
  currentMode: "unavailable",
  ssids: [],
  bssids: [],
};

export function normalizeTransparentMode(
  value: string,
): TransparentMode | null {
  const mode = value.trim().toLowerCase();
  return mode === "tun" || mode === "ebpf" ? mode : null;
}

export function parseHealth(text: string): HealthItem[] {
  return text
    .split(/\r?\n/)
    .map((line) => {
      const match = line
        .trim()
        .match(/^\[(ok|warn|fail|info)\]\s+([^:]+):?\s*(.*)$/i);
      if (!match) return null;
      return {
        status: match[1].toLowerCase() as HealthItem["status"],
        key: match[2].trim(),
        detail: match[3].trim(),
      };
    })
    .filter((item): item is HealthItem => Boolean(item));
}

export function parseApps(text: string): AppPolicy {
  const policy: AppPolicy = {
    mode: "blacklist",
    proxy: [],
    direct: [],
    bypass: [],
  };
  let section: "proxy" | "direct" | "bypass" | null = null;
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (!line) return;
    if (line.startsWith("mode="))
      policy.mode = line.includes("whitelist") ? "whitelist" : "blacklist";
    else if (line === "proxy apps:") section = "proxy";
    else if (line === "direct apps:") section = "direct";
    else if (line === "bypass apps:") section = "bypass";
    else if (section) policy[section].push(line);
  });
  return policy;
}

export function parsePackages(text: string): PackageInfo[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) =>
      /^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)+$/.test(line),
    )
    .map((packageName) => ({
      packageName,
      versionName: "",
      versionCode: 0,
      appLabel: packageName,
      isSystem: false,
      uid: 0,
    }));
}

export function parseNetworkSnapshotSummary(
  text: string,
): NetworkSnapshotSummary {
  const lines = text.split(/\r?\n/).map((line) => line.trim());
  return {
    interfaces: countSectionLines(lines, "[interfaces]", "[routes]"),
    ipRules: countSectionLines(lines, "ip rule:", "ip route:"),
    routes: countSectionLines(lines, "ip route:", "[forwarding]"),
    natRules: countSectionLines(lines, "[forwarding]", undefined),
  };
}

export function parseConfigValidation(
  text: string,
): Pick<ConfigValidationState, "status" | "summary"> {
  const trimmed = text.trim();
  if (!trimmed)
    return { status: "error", summary: t("命令没有返回校验结果。") };
  if (/\[info\]\s+Saved and validated/i.test(trimmed)) {
    return {
      status: "ok",
      summary: firstUsefulLine(trimmed) || t("配置已通过校验并保存。"),
    };
  }
  if (
    /config validation failed|validator missing|config target must/i.test(
      trimmed,
    )
  ) {
    return { status: "error", summary: configValidationFailureDetail(trimmed) };
  }
  return {
    status: trimmed.includes("[error]") ? "error" : "ok",
    summary: firstUsefulLine(trimmed) || trimmed.slice(0, 160),
  };
}

function configValidationFailureDetail(text: string): string {
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("command:"));
  return (
    lines.find(
      (line) =>
        /(?:fatal|no such file|not found|permission denied|timed out|validator missing)/i.test(
          line,
        ) && !/^config validation failed$/i.test(line),
    ) ||
    lines.find((line) => !/^config validation failed$/i.test(line)) ||
    t("配置校验失败。")
  );
}

export function parseRouteRuleSummary(text: string): RouteRuleSummary {
  const summary: RouteRuleSummary = {
    proxy: [],
    direct: [],
    block: [],
    warp: [],
  };
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

export function parseConnectionSnapshot(
  text: string,
): ConnectionSnapshot | null {
  try {
    const root = JSON.parse(text) as Record<string, unknown>;
    const rawConnections = Array.isArray(root.connections)
      ? root.connections
      : null;
    if (!rawConnections) return null;
    const connections = rawConnections
      .map(parseConnectionTarget)
      .filter((item): item is ConnectionTarget => Boolean(item))
      .filter(
        (item, index, items) =>
          items.findIndex((other) => other.id === item.id) === index,
      )
      .sort((left, right) => right.totalBytes - left.totalBytes);
    return {
      count: rawConnections.length,
      uploadTotal: safeNumber(root.uploadTotal),
      downloadTotal: safeNumber(root.downloadTotal),
      connections,
    };
  } catch {
    return null;
  }
}

export function connectionMatchesQuery(
  target: ConnectionTarget,
  query: string,
): boolean {
  const terms = query
    .split(/\s+/)
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);
  if (!terms.length) return true;
  const haystack = [
    target.label,
    target.process,
    target.source,
    target.inbound,
    target.network,
    target.rule,
    target.rulePayload,
    target.chain,
    target.detail,
  ]
    .join(" ")
    .toLowerCase();
  return terms.every((term) => haystack.includes(term));
}

export function connectionBuckets(
  connections: ConnectionTarget[],
  kind: "rule" | "chain" | "process",
): ConnectionBucket[] {
  const seeds = connections
    .map((target) => {
      const name = bucketName(target, kind);
      if (!name) return null;
      return {
        name,
        query: kind === "chain" ? name.replace(/ > /g, " ") : name,
        bytes: target.totalBytes,
      };
    })
    .filter((item): item is { name: string; query: string; bytes: number } =>
      Boolean(item),
    );
  return Object.values(
    seeds.reduce<Record<string, ConnectionBucket>>((acc, seed) => {
      acc[seed.name] ||= {
        name: seed.name,
        query: seed.query,
        count: 0,
        bytes: 0,
      };
      acc[seed.name].count += 1;
      acc[seed.name].bytes += seed.bytes;
      return acc;
    }, {}),
  )
    .sort((left, right) => right.bytes - left.bytes || right.count - left.count)
    .slice(0, 4);
}

export function connectionFlowSummary(
  connections: ConnectionTarget[],
): ConnectionFlowSummary {
  return connections.reduce<ConnectionFlowSummary>(
    (acc, target) => {
      const flow = connectionFlow(target);
      acc[flow] += 1;
      return acc;
    },
    { proxied: 0, direct: 0, blocked: 0, unknown: 0 },
  );
}

function connectionFlow(target: ConnectionTarget): keyof ConnectionFlowSummary {
  const text = [
    target.chain,
    target.rule,
    target.rulePayload,
    target.inbound,
    target.detail,
  ]
    .join(" ")
    .toLowerCase();
  if (/\b(block|reject)\b/.test(text)) return "blocked";
  if (/\b(direct|bypass)\b/.test(text)) return "direct";
  if (
    target.chain ||
    /\b(proxy|select|warp|wireguard|trojan|vmess|vless|shadowsocks|hysteria)\b/.test(
      text,
    )
  )
    return "proxied";
  return "unknown";
}

function bucketName(
  target: ConnectionTarget,
  kind: "rule" | "chain" | "process",
): string {
  if (kind === "rule")
    return [target.rule, target.rulePayload].filter(Boolean).join(" ");
  if (kind === "process") return target.process || target.inbound;
  return target.chain || target.network;
}

function parseConnectionTarget(value: unknown): ConnectionTarget | null {
  if (!value || typeof value !== "object") return null;
  const item = value as Record<string, unknown>;
  const metadata = (
    item.metadata && typeof item.metadata === "object" ? item.metadata : {}
  ) as Record<string, unknown>;
  const id = stringValue(item.id);
  const host = stringValue(metadata.host);
  const destination = stringValue(metadata.destinationIP);
  const port = String(metadata.destinationPort ?? "");
  const target = host || destination;
  if (!id || !target) return null;
  const label = !port || port === "0" ? target : `${target}:${port}`;
  const chain = Array.isArray(item.chains)
    ? item.chains.map(stringValue).filter(Boolean).join(" > ")
    : "";
  const network = stringValue(metadata.network);
  const source = sourceLabel(metadata);
  const inbound =
    stringValue(item.inbound) ||
    stringValue(metadata.inbound) ||
    stringValue(metadata.type);
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
    detail:
      [process, source, inbound, network, rule, rulePayload, chain]
        .filter(Boolean)
        .join(" · ") || "direct",
    upload,
    download,
    totalBytes: upload + download,
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
  return typeof value === "number" && Number.isFinite(value)
    ? Math.max(0, value)
    : 0;
}

function firstUsefulLine(text: string): string {
  return (
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line && !line.startsWith("command:")) || ""
  );
}

function countSectionLines(
  lines: string[],
  start: string,
  end: string | undefined,
): number {
  const startIndex = lines.findIndex(
    (line) => line.toLowerCase() === start.toLowerCase(),
  );
  if (startIndex < 0) return 0;
  const relativeEnd = end
    ? lines
        .slice(startIndex + 1)
        .findIndex((line) => line.toLowerCase() === end.toLowerCase())
    : -1;
  const endIndex =
    relativeEnd >= 0 ? startIndex + 1 + relativeEnd : lines.length;
  return lines
    .slice(startIndex + 1, endIndex)
    .filter(
      (line) =>
        line &&
        !line.startsWith("[") &&
        line !== "ip rule:" &&
        line !== "ip route:",
    ).length;
}

export function parseBlock(
  text: string,
  previous: BlocklistState,
): BlocklistState {
  const next: BlocklistState = {
    ...previous,
    manual: [],
    communityRules: [],
    communityDomains: [],
    allowRules: [],
  };
  let section:
    | keyof Pick<
        BlocklistState,
        "manual" | "communityRules" | "communityDomains" | "allowRules"
      >
    | null = null;
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (!line) return;
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) !== "0";
    else if (line.startsWith("community="))
      next.community = line.slice(10) !== "0";
    else if (line.startsWith("url=")) next.url = line.slice(4);
    else if (line === "manual domain suffixes:") section = "manual";
    else if (line === "community rules:") section = "communityRules";
    else if (line === "community domain suffixes:")
      section = "communityDomains";
    else if (line === "local allow rules:") section = "allowRules";
    else if (section) next[section].push(line);
  });
  return next;
}

export function parseMcp(text: string, previous: McpState): McpState {
  const next = { ...previous, portOwner: "" };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) !== "0";
    else if (line.startsWith("bind=")) next.bind = line.slice(5);
    else if (line.startsWith("port=")) next.port = line.slice(5);
    else if (line.startsWith("pid=")) next.pid = line.slice(4);
    else if (line.startsWith("secret_set="))
      next.secretSet = line.slice(11) === "1";
    else if (line.startsWith("port_owner=")) next.portOwner = line.slice(11);
  });
  next.url = formatMcpUrl(next.bind, next.port);
  return next;
}

export function parseWarp(text: string, previous: WarpState): WarpState {
  const next = { ...previous };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) === "1";
    else if (line.startsWith("configured="))
      next.configured = line.slice(11) === "1";
    else if (line.startsWith("tag=")) next.tag = line.slice(4) || "warp";
    else if (line.startsWith("endpoint=")) next.endpoint = line.slice(9);
    else if (line.startsWith("addresses="))
      next.addresses = Number(line.slice(10)) || 0;
    else if (line.startsWith("allowed_ips="))
      next.allowedIps = Number(line.slice(12)) || 0;
  });
  return next;
}
