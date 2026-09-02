export type ConfigOutline = {
  status: "idle" | "ok" | "error";
  summary: string;
  keys: string[];
  counts: Array<{ label: string; value: string }>;
};

export type ConfigAuditItem = {
  label: string;
  value: string;
  tone: "success" | "warning" | "danger" | "neutral";
};

export type ConfigAudit = {
  status: "idle" | "ok" | "warning" | "error";
  summary: string;
  items: ConfigAuditItem[];
  outboundTags: string[];
};

type SensitiveFinding = {
  kind: "url" | "field";
  key?: string;
  count: number;
};

const SENSITIVE_URL_PATTERN = /https?:\/\/[^\s"',}\]]+/gi;
const SENSITIVE_KEY_SOURCE = [
  "authorization",
  "proxy-authorization",
  "private[_-]?key",
  "password",
  "passwd",
  "token",
  "secret",
  "uuid",
  "api[_-]?key",
  "access[_-]?token",
  "refresh[_-]?token",
  "client[_-]?secret",
  "subscription(?:[_-]?url)?",
  "security(?:[_ -]?code)?",
].join("|");
const SENSITIVE_KEY_PATTERN = new RegExp(`^(?:${SENSITIVE_KEY_SOURCE})$`, "i");
const SENSITIVE_QUOTED_FIELD_PATTERN = new RegExp(
  `(["']?(${SENSITIVE_KEY_SOURCE})["']?\\s*[:=]\\s*)(["'])(.*?)\\3`,
  "gi",
);
const SENSITIVE_BARE_FIELD_PATTERN = new RegExp(
  `(["']?(${SENSITIVE_KEY_SOURCE})["']?\\s*[:=]\\s*)[^"',\\s;}\\]]+`,
  "gi",
);

export function sanitizeConfigText(text: string): string {
  return text
    .replace(SENSITIVE_URL_PATTERN, "[filtered-url]")
    .replace(
      SENSITIVE_QUOTED_FIELD_PATTERN,
      (_match, prefix: string, _key: string, quote: string) =>
        `${prefix}${quote}[filtered]${quote}`,
    )
    .replace(
      SENSITIVE_BARE_FIELD_PATTERN,
      (_match, prefix: string) => `${prefix}[filtered]`,
    );
}

const SAFE_INBOUND_TYPES = new Set(["tun", "mixed", "direct"]);
const SAFE_TUN_STACKS = new Set(["system", "gvisor", "mixed"]);
const SAFE_BOOLEAN_KEYS = [
  "auto_route",
  "auto_redirect",
  "strict_route",
] as const;
const ISSUE_DIFF_CONTEXT = 3;
export const MAX_CONFIG_ISSUE_DIFF_BYTES = 24 * 1024;

export function sanitizeConfigForIssue(text: string): string {
  const parsed = JSON.parse(text) as unknown;
  if (!isRecord(parsed)) throw new Error("配置根节点不是 JSON object。");
  const inbounds = arrayRecords(parsed.inbounds).map((inbound, index) => {
    const type = stringValue(inbound.type);
    const safe: Record<string, unknown> = {
      id: `inbound-${index + 1}`,
      type: SAFE_INBOUND_TYPES.has(type) ? type : "other",
    };
    if (type === "tun") {
      const stack = stringValue(inbound.stack);
      if (SAFE_TUN_STACKS.has(stack)) safe.stack = stack;
      if (typeof inbound.mtu === "number" && Number.isSafeInteger(inbound.mtu))
        safe.mtu = inbound.mtu;
      for (const key of SAFE_BOOLEAN_KEYS)
        if (typeof inbound[key] === "boolean") safe[key] = inbound[key];
    }
    return safe;
  });
  const safe = {
    format: "magicnet-config-diff-v1",
    structure: {
      inbound_count: inbounds.length,
      outbound_count: Array.isArray(parsed.outbounds)
        ? parsed.outbounds.length
        : 0,
      route_rule_count:
        isRecord(parsed.route) && Array.isArray(parsed.route.rules)
          ? parsed.route.rules.length
          : 0,
      dns_server_count:
        isRecord(parsed.dns) && Array.isArray(parsed.dns.servers)
          ? parsed.dns.servers.length
          : 0,
    },
    inbounds,
  };
  return `${JSON.stringify(safe, null, 2)}\n`;
}

export function buildUnifiedConfigDiff(before: string, after: string): string {
  const beforeRaw = parseIssueConfig(before);
  const afterRaw = parseIssueConfig(after);
  const beforeSafe = JSON.parse(sanitizeConfigForIssue(before)) as Record<
    string,
    unknown
  >;
  const afterSafe = JSON.parse(sanitizeConfigForIssue(after)) as Record<
    string,
    unknown
  >;
  const changedSections = (
    ["inbounds", "outbounds", "route", "dns"] as const
  ).filter(
    (key) => JSON.stringify(beforeRaw[key]) !== JSON.stringify(afterRaw[key]),
  );
  if (changedSections.length) {
    beforeSafe.change_markers = Object.fromEntries(
      changedSections.map((key) => [key, "before"]),
    );
    afterSafe.change_markers = Object.fromEntries(
      changedSections.map((key) => [key, "after"]),
    );
  }
  const oldLines = JSON.stringify(beforeSafe, null, 2).split("\n");
  const newLines = JSON.stringify(afterSafe, null, 2).split("\n");
  let prefix = 0;
  while (
    prefix < oldLines.length &&
    prefix < newLines.length &&
    oldLines[prefix] === newLines[prefix]
  )
    prefix++;
  if (prefix === oldLines.length && prefix === newLines.length) return "";
  let suffix = 0;
  while (
    suffix < oldLines.length - prefix &&
    suffix < newLines.length - prefix &&
    oldLines[oldLines.length - 1 - suffix] ===
      newLines[newLines.length - 1 - suffix]
  )
    suffix++;
  const oldStart = Math.max(0, prefix - ISSUE_DIFF_CONTEXT);
  const newStart = Math.max(0, prefix - ISSUE_DIFF_CONTEXT);
  const oldEnd = Math.min(
    oldLines.length,
    oldLines.length - suffix + ISSUE_DIFF_CONTEXT,
  );
  const newEnd = Math.min(
    newLines.length,
    newLines.length - suffix + ISSUE_DIFF_CONTEXT,
  );
  const contextBefore = oldLines
    .slice(oldStart, prefix)
    .map((line) => ` ${line}`);
  const removed = oldLines
    .slice(prefix, oldLines.length - suffix)
    .map((line) => `-${line}`);
  const added = newLines
    .slice(prefix, newLines.length - suffix)
    .map((line) => `+${line}`);
  const contextAfter = oldLines
    .slice(oldLines.length - suffix, oldEnd)
    .map((line) => ` ${line}`);
  return [
    "--- config.before.json",
    "+++ config.after.json",
    `@@ -${oldStart + 1},${oldEnd - oldStart} +${newStart + 1},${newEnd - newStart} @@`,
    ...contextBefore,
    ...removed,
    ...added,
    ...contextAfter,
  ].join("\n");
}

function parseIssueConfig(text: string): Record<string, unknown> {
  const parsed = JSON.parse(text) as unknown;
  if (!isRecord(parsed)) throw new Error("配置根节点不是 JSON object。");
  return parsed;
}

export function buildConfigOutline(text: string): ConfigOutline {
  const trimmed = text.trim();
  if (!trimmed) {
    return {
      status: "idle",
      summary: "尚未加载配置",
      keys: [],
      counts: outlineCounts({}),
    };
  }

  try {
    const parsed = JSON.parse(trimmed);
    if (!isRecord(parsed)) {
      return {
        status: "error",
        summary: "配置根节点不是 JSON object",
        keys: [],
        counts: outlineCounts({}),
      };
    }
    const keys = Object.keys(parsed);
    return {
      status: "ok",
      summary: `${keys.length} 个顶层键`,
      keys: keys.slice(0, 12),
      counts: outlineCounts(parsed),
    };
  } catch {
    return {
      status: "error",
      summary: "JSON 语法错误",
      keys: [],
      counts: outlineCounts({}),
    };
  }
}

export function buildConfigAudit(text: string): ConfigAudit {
  const trimmed = text.trim();
  if (!trimmed)
    return {
      status: "idle",
      summary: "加载配置后显示运行关键项。",
      items: [],
      outboundTags: [],
    };

  const parsed = parseConfigRoot(trimmed);
  if (parsed.error || !parsed.root) {
    return {
      status: "error",
      summary: parsed.error || "JSON 解析失败。",
      items: [],
      outboundTags: [],
    };
  }

  const root = parsed.root;
  const inbounds = arrayRecords(root.inbounds);
  const outbounds = arrayRecords(root.outbounds);
  const route = isRecord(root.route) ? root.route : {};
  const dns = isRecord(root.dns) ? root.dns : {};
  const experimental = isRecord(root.experimental) ? root.experimental : {};
  const clashApi = isRecord(experimental.clash_api)
    ? experimental.clash_api
    : {};
  const inboundTypes = uniqueStrings(
    inbounds.map((item) => stringValue(item.type)),
  );
  const outboundTags = uniqueStrings(
    outbounds.map((item) => stringValue(item.tag)),
  );
  const selectorCount = outbounds.filter((item) =>
    ["selector", "urltest"].includes(stringValue(item.type)),
  ).length;
  const externalController = stringValue(clashApi.external_controller);
  const routeFinal = stringValue(route.final);
  const dnsFinal = stringValue(dns.final);
  const preferredProxyTag = findPreferredProxyTag(outbounds);
  const missingRuleOutbounds = findMissingRuleOutbounds(
    route.rules,
    outboundTags,
  );
  const missingDnsDetours = findMissingDnsDetours(dns.servers, outboundTags);
  const sensitiveFindings = detectSensitiveFindings(text);

  const items: ConfigAuditItem[] = [
    auditItem(
      "TUN 入站",
      inboundTypes.includes("tun") ? "存在" : "缺失",
      inboundTypes.includes("tun") ? "success" : "warning",
    ),
    auditItem(
      "Mixed 入站",
      inboundTypes.includes("mixed") ? "存在" : "可选",
      inboundTypes.includes("mixed") ? "success" : "neutral",
    ),
    auditItem(
      "WebUI API",
      externalController || "未配置",
      externalController ? "success" : "warning",
    ),
    auditItem(
      "route.final",
      finalAuditValue(routeFinal, outboundTags),
      finalAuditTone(routeFinal, outboundTags, true),
    ),
    auditItem(
      "dns.final",
      finalAuditValue(dnsFinal, outboundTags),
      finalAuditTone(dnsFinal, outboundTags, false),
    ),
    auditItem(
      "主代理候选",
      preferredProxyTag || "未识别",
      preferredProxyTag ? "success" : "warning",
    ),
    auditItem(
      "选择器",
      `${selectorCount} 个`,
      selectorCount ? "success" : "neutral",
    ),
    auditItem(
      "route.rules 出站引用",
      missingRuleOutbounds.length
        ? `缺少 ${missingRuleOutbounds.length} 个引用`
        : "全部存在",
      missingRuleOutbounds.length ? "warning" : "success",
    ),
    auditItem(
      "DNS detour 出站引用",
      missingDnsDetours.length
        ? `缺少 ${missingDnsDetours.length} 个引用`
        : "全部存在",
      missingDnsDetours.length ? "warning" : "success",
    ),
  ];

  if (sensitiveFindings.length) {
    items.push(
      auditItem(
        "敏感信息",
        summarizeSensitiveFindings(sensitiveFindings),
        "warning",
      ),
    );
  }

  const warningCount = items.filter((item) => item.tone === "warning").length;
  return {
    status: warningCount ? "warning" : "ok",
    summary: warningCount
      ? `${warningCount} 个关键项需要确认`
      : "关键运行项齐全",
    items,
    outboundTags: outboundTags.slice(0, 16),
  };
}

export function outlineCounts(
  root: Record<string, unknown>,
): Array<{ label: string; value: string }> {
  const route = isRecord(root.route) ? root.route : {};
  const dns = isRecord(root.dns) ? root.dns : {};
  return [
    { label: "inbounds", value: arrayCount(root.inbounds) },
    { label: "outbounds", value: arrayCount(root.outbounds) },
    { label: "route.rules", value: arrayCount(route.rules) },
    { label: "dns.servers", value: arrayCount(dns.servers) },
  ];
}

function arrayCount(value: unknown): string {
  return Array.isArray(value) ? String(value.length) : "-";
}

export function parseConfigRoot(text: string): {
  root: Record<string, unknown> | null;
  error: string;
} {
  try {
    const parsed = JSON.parse(text);
    return isRecord(parsed)
      ? { root: parsed, error: "" }
      : { root: null, error: "配置根节点不是 JSON object。" };
  } catch {
    return { root: null, error: "JSON 语法错误。" };
  }
}

export function arrayRecords(value: unknown): Array<Record<string, unknown>> {
  return Array.isArray(value) ? value.filter(isRecord) : [];
}

export function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

export function uniqueStrings(values: string[]): string[] {
  return Array.from(new Set(values.filter(Boolean)));
}

export function finalAuditValue(tag: string, outboundTags: string[]): string {
  if (!tag) return "未配置";
  return outboundTags.includes(tag) ? `${tag} 已存在` : `${tag} 未匹配出站`;
}

export function finalAuditTone(
  tag: string,
  outboundTags: string[],
  required: boolean,
): ConfigAuditItem["tone"] {
  if (!tag) return required ? "warning" : "neutral";
  return outboundTags.includes(tag) ? "success" : "warning";
}

export function findPreferredProxyTag(
  outbounds: Array<Record<string, unknown>>,
): string {
  const candidates = ["proxy", "auto", "urltest", "select"];
  for (const candidate of candidates) {
    if (outbounds.some((item) => stringValue(item.tag) === candidate))
      return candidate;
  }
  const selector = outbounds.find((item) =>
    ["selector", "urltest"].includes(stringValue(item.type)),
  );
  return selector ? stringValue(selector.tag) : "";
}

export function auditItem(
  label: string,
  value: string,
  tone: ConfigAuditItem["tone"],
): ConfigAuditItem {
  return { label, value, tone };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function findMissingRuleOutbounds(
  rules: unknown,
  outboundTags: string[],
): string[] {
  const known = new Set(outboundTags);
  return uniqueStrings(
    arrayRecords(rules)
      .map((rule) => stringValue(rule.outbound))
      .filter((tag) => tag && !known.has(tag)),
  );
}

function findMissingDnsDetours(
  servers: unknown,
  outboundTags: string[],
): string[] {
  const known = new Set(outboundTags);
  return uniqueStrings(
    arrayRecords(servers)
      .map((server) => stringValue(server.detour))
      .filter((tag) => tag && !known.has(tag)),
  );
}

function detectSensitiveFindings(text: string): SensitiveFinding[] {
  const findings: SensitiveFinding[] = [];
  const urlMatches = text.match(SENSITIVE_URL_PATTERN);
  if (urlMatches?.length) {
    findings.push({ kind: "url", count: urlMatches.length });
  }

  const fieldCounts = new Map<string, number>();
  countSensitiveFields(text, SENSITIVE_QUOTED_FIELD_PATTERN, fieldCounts);
  countSensitiveFields(text, SENSITIVE_BARE_FIELD_PATTERN, fieldCounts);
  for (const [key, count] of fieldCounts) {
    findings.push({ kind: "field", key, count });
  }
  return findings;
}

function countSensitiveFields(
  text: string,
  pattern: RegExp,
  counts: Map<string, number>,
): void {
  for (const match of text.matchAll(pattern)) {
    const key = normalizeSensitiveKey(match[2]);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
}

function normalizeSensitiveKey(value: unknown): string {
  const key = String(value || "").toLowerCase();
  return SENSITIVE_KEY_PATTERN.test(key) ? key : "sensitive";
}

function summarizeSensitiveFindings(findings: SensitiveFinding[]): string {
  return findings
    .map((finding) => {
      if (finding.kind === "url") return `${finding.count} 个 URL`;
      return `${finding.count} 个 ${finding.key} 字段`;
    })
    .join("，");
}
