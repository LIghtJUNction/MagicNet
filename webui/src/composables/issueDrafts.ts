import { t } from "@/i18n";
import { ROUTE_TAGS, safeRouteHop, safeRouteText, isGoogleEvidence, boundedLines, compactSupport } from "@/composables/networkEvidence";
const MAX_ISSUE_BODY_CHARS = 5200;

export type IssueKind =
  | "route-feedback"
  | "app-connectivity"
  | "command-error"
  | "subscription-node"
  | "dns-routing"
  | "other";

export const ISSUE_KIND_OPTIONS: ReadonlyArray<{
  value: IssueKind;
  label: string;
  description: string;
  context: string;
}> = [
  {
    value: "route-feedback",
    label: "路由反馈",
    description: "推荐：提交最近应用和网站实际命中的路由，帮助持续改进规则。",
    context: "附带近期应用包名、目标域名、命中规则、路由链和相关错误；IP、节点名、凭据和 URL 路径会被过滤。",
  },
  {
    value: "app-connectivity",
    label: "某个 App 无法联网",
    description: "应用打不开、连接超时，或流量走错出口。",
    context: "附带近期活动连接的进程、规则和代理链，以及脱敏后的 sing-box 日志尾部。",
  },
  {
    value: "command-error",
    label: "命令或操作报错",
    description: "CLI/WebUI 操作失败、超时或没有生效。",
    context: "附带上一条命令的安全分类、执行阶段、后台任务状态和脱敏错误输出。",
  },
  {
    value: "subscription-node",
    label: "订阅或节点异常",
    description: "订阅更新失败、节点不可用，或代理组选择异常。",
    context: "附带订阅状态、选择器摘要和相关 sing-box 日志。",
  },
  {
    value: "dns-routing",
    label: "DNS、TUN 或分流异常",
    description: "DNS 泄露、TUN 未接管、直连/代理分流不符合预期。",
    context: "附带健康检查、DNS、网络与透明代理状态。",
  },
  {
    value: "other",
    label: "其他问题",
    description: "不属于以上类型，或暂时无法判断。",
    context: "附带通用支持包和最近一次 WebUI 操作摘要。",
  },
];

export type IssueReport = {
  summary: string;
  reproduction: string;
  expected: string;
  actual: string;
  frequency: string;
};

export type IssueReportInput = IssueReport & {
  kind: IssueKind;
};

export function issueKindLabel(kind: IssueKind): string {
  return t(ISSUE_KIND_OPTIONS.find((option) => option.value === kind)?.label || "其他问题");
}

function fenced(text: string): string {
  const body = text.trim() || "(empty)";
  return `\`\`\`text\n${body.replace(/```/g, "`\u200b``")}\n\`\`\``;
}

function issueSection(title: string, body: string): string {
  return `## ${title}\n\n${fenced(body)}\n`;
}

function deterministicSlice(text: string, limit: number): string {
  const normalized = text.replace(/\r\n/g, "\n").trim();
  if (normalized.length <= limit) return normalized;
  const head = Math.floor(limit * 0.72);
  const tail = Math.max(0, limit - head - 48);
  return `${normalized.slice(0, head)}\n[deterministically truncated]\n${normalized.slice(-tail)}`;
}

export function propValue(text: string, key: string): string {
  const prefix = `${key}=`;
  return text
    .split("\n")
    .find((line) => line.startsWith(prefix))
    ?.slice(prefix.length)
    .trim() || "";
}

export function stripTerminalControlSequences(text: string): string {
  return text.replace(/(?:\u001b\[|\u009b|\^\[\[)[0-?]*[ -/]*[@-~]/g, "");
}

export function sanitizeDiagnosticText(text: string): string {
  return stripTerminalControlSequences(text)
    .replace(/\b(?:https?|socks?|ss|ssr|vmess|vless|trojan|hysteria2?|tuic):\/\/[^\s"'<>]+/gi, "[filtered-url]")
    .replace(/\b(?:token|secret|password|passwd|node|query|path)[=:._-][A-Za-z0-9._~+/-]{4,}\b/gi, "[filtered-value]")
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, "[filtered-email]")
    .replace(/\b(?:enx[0-9a-f]{12}|br-[0-9a-f]{12,}|[a-z][a-z0-9_-]{0,24}[0-9a-f]{12,})\b/gi, "[filtered-interface-id]")
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b/g, "[filtered-ip]")
    .replace(/\b[0-9a-f]{0,4}:[0-9a-f:]{2,}(?:%[\w.-]+)?\b/gi, "[filtered-ip]")
    .replace(/(?:^|\s)(?:\/(?:data|sdcard|storage|home|root|proc|sys|vendor|system|apex|mnt|etc|tmp)\/[^\s"'<>]*)/gm, (value) => `${value.startsWith(" ") ? " " : ""}[filtered-path]`)
    .replace(/\b(private_?key|password|passwd|token|secret|uuid|api[_-]?key|subscription(?:_url)?|query|node|server|endpoint|path|device[_-]?id|android[_-]?id|serial|imei)(\s*[:=]\s*)[^\s,;}\]]+/gi, "$1$2[filtered]")
    .replace(/(Authorization\s*:\s*)(?:Bearer\s+)?[A-Za-z0-9._~+/=-]+/gi, "$1[filtered]")
    .replace(/(Proxy-Authorization\s*:\s*)[^\s]+/gi, "$1[filtered]");
}

export type IssueOperationContext = {
  phase: string;
  lastCommand: string;
  lastOutput: string;
  backgroundLabel: string;
  backgroundArgs: string;
  backgroundStatus: string;
};

const SAFE_COMMANDS: Record<string, readonly string[]> = {
  api: ["preflight", "groups", "conns", "proxies"],
  app: ["list", "packages", "add", "add-many", "remove"],
  backup: ["create", "export", "restore", "restore-file"],
  block: ["list", "add", "add-domain", "allow-rule", "remove", "remove-domain", "unallow-rule", "update"],
  config: ["apply", "show"],
  "config-editor": ["get", "save-file", "sync-template"],
  core: ["status", "logs"],
  diagnose: [],
  dns: ["status", "set", "test"],
  health: [],
  mcp: ["status", "start", "stop"],
  open: ["external"],
  repair: [],
  refresh: ["background", "tools"],
  route: ["list"],
  service: ["status", "logs", "start", "stop", "restart", "ensure"],
  setup: [],
  sub: ["apply-file", "get", "list", "schedule", "set", "set-file", "status", "update", "update-all"],
  supervisor: ["status", "start", "stop", "restart"],
  support: ["bundle"],
  sysroute: ["snapshot", "list", "add-rule", "del-rule", "add-route", "del-route"],
  topology: [],
  transparent: ["get", "set"],
  warp: ["status", "import", "import-file", "route"],
  webui: ["status", "verify", "payload", "install-local"],
};

export function classifyOperationCommand(raw: string): string {
  const normalized = raw.replace(/[\r\n\t]+/g, " ").toLowerCase();
  const cliMatch = normalized.match(/(?:^|[\s/'"])(?:magicnet(?:-cli)?|cli)\s+([a-z][a-z0-9-]*)(?:\s+([a-z][a-z0-9-]*))?/);
  const directMatch = normalized.match(/^\s*([a-z][a-z0-9-]*)(?:\s+([a-z][a-z0-9-]*))?/);
  const match = cliMatch || directMatch;
  if (!match) return "command=unclassified arguments=filtered";
  const command = match[1];
  const subcommand = match[2] || "";
  const allowed = SAFE_COMMANDS[command];
  if (!allowed) return "command=unclassified arguments=filtered";
  const safeSubcommand = allowed.includes(subcommand) ? subcommand : "";
  return `command=${command}${safeSubcommand ? `.${safeSubcommand}` : ""} arguments=filtered`;
}

function operationText(operation: IssueOperationContext): string {
  return [
    `phase=${operation.phase || "idle"}`,
    `last_command=${classifyOperationCommand(operation.lastCommand || "")}`,
    `background_status=${operation.backgroundStatus || "idle"}`,
    `background_label=${operation.backgroundLabel || "none"}`,
    `background_args=${classifyOperationCommand(operation.backgroundArgs || "")}`,
  ].join("\n");
}

function safeString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function connectionProcess(metadata: Record<string, unknown>): string {
  const packageName = safeString(metadata.processPackageName)
    || (Array.isArray(metadata.packageNames) ? metadata.packageNames.filter(name => typeof name === "string" && /^[a-zA-Z0-9_.]{1,160}$/.test(name)).join(",") : "");
  if (packageName) return packageName;
  const processName = safeString(metadata.processName);
  if (processName) return processName;
  const processPath = safeString(metadata.processPath);
  const fallback = processPath.split("/").filter(Boolean).at(-1) || "";
  // The core emits app_process64 before package names. Do not label it a package.
  return /^app_process(?:32|64)?\b/.test(fallback) ? `package-unavailable ${fallback}` : fallback;
}

function routingFeedbackHost(metadata: Record<string, unknown>): string {
  const host = safeString(metadata.host).replace(/\.$/, "").toLowerCase();
  if (!host || host.length > 253 || /[\s/@\\]/.test(host)) return "";
  if (/^\[?[0-9a-f:.]+\]?$/i.test(host)) return "";
  const labels = host.split(".");
  if (labels.length < 2) return "";
  if (labels.some((label) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label))) return "";
  return host;
}

function compactFeedbackValue(value: string, limit = 160): string {
  return deterministicSlice(sanitizeDiagnosticText(value), limit).replace(/\s+/g, " ").trim();
}

const SAFE_ROUTE_TAGS = ROUTE_TAGS;

/**
 * Keep routing evidence useful without exporting destinations, source
 * addresses, connection IDs, traffic sizes, or subscription-provided node
 * names. Selector tags such as proxy-rule/direct remain visible.
 */
export function summarizeConnectionsForIssue(text: string): string {
  try {
    const root = JSON.parse(text) as Record<string, unknown>;
    const raw = Array.isArray(root.connections) ? root.connections : null;
    if (!raw) return "active_connections=unavailable";
    const rows = raw
      .slice(-12)
      .map((value, index) => {
        if (!value || typeof value !== "object") return "";
        const item = value as Record<string, unknown>;
        const metadata = item.metadata && typeof item.metadata === "object"
          ? item.metadata as Record<string, unknown>
          : {};
        const process = connectionProcess(metadata);
        const network = safeString(metadata.network);
        const inbound = safeString(item.inbound)
          || safeString(metadata.inbound)
          || safeString(metadata.type);
        const rule = safeString(item.rule);
        const chain = Array.isArray(item.chains)
          ? item.chains.map(safeRouteHop).filter(Boolean).slice(0, 8).join(" -> ")
          : "";
        return [
          `connection.${index + 1}`,
          process ? `process=${process}` : "",
          inbound ? `inbound=${inbound}` : "",
          network ? `network=${network}` : "",
          rule ? `rule=${rule}` : "",
          chain ? `chain=${chain}` : "",
        ].filter(Boolean).join(" ");
      })
      .filter(Boolean);
    return [
      `active_connection_count=${raw.length}`,
      `included_recent_connections=${rows.length}`,
      ...rows,
    ].join("\n");
  } catch {
    return "active_connections=unavailable\nparse_error=invalid response";
  }
}

/**
 * Explicit opt-in route feedback. Unlike the normal connectivity report this
 * keeps app package names and DNS hostnames because those are the signals used
 * to improve maintained routing rules. IPs, connection IDs, byte counters,
 * credentials and subscription node names are still excluded.
 */
export function summarizeRoutingFeedback(text: string, maxRoutes = 24): string {
  try {
    const root = JSON.parse(text) as Record<string, unknown>;
    const raw = Array.isArray(root.connections) ? root.connections : null;
    if (!raw) return "active_connections=unavailable";

    const samples: Array<{ signature: string; line: string; count: number; google: boolean }> = [];
    const seen = new Map<string, number>();
    for (const value of raw.slice(0, 2048)) {
      if (!value || typeof value !== "object") continue;
      const item = value as Record<string, unknown>;
      const metadata = item.metadata && typeof item.metadata === "object"
        ? item.metadata as Record<string, unknown>
        : {};
      const process = compactFeedbackValue(connectionProcess(metadata), 120);
      const domain = routingFeedbackHost(metadata);
      const network = compactFeedbackValue(safeString(metadata.network), 24);
      const inbound = compactFeedbackValue(
        safeString(item.inbound) || safeString(metadata.inbound) || safeString(metadata.type),
        48,
      );
      const rule = compactFeedbackValue(safeRouteText(safeString(item.rule)), 96);
      const rulePayload = compactFeedbackValue(safeString(item.rulePayload), 120);
      const chain = Array.isArray(item.chains)
        ? item.chains.map(safeRouteHop).filter(Boolean).slice(0, 8).join(" -> ")
        : "";
      if (!process && !domain) continue;
      const signature = [process, domain, network, inbound, rule, rulePayload, chain].join("\u0000");
      const existing = seen.get(signature);
      if (existing !== undefined) {
        samples[existing].count += 1;
        continue;
      }
      seen.set(signature, samples.length);
      samples.push({
        signature,
        count: 1,
        google: isGoogleEvidence(domain, process, chain),
        line: [
          process ? `app=${process}` : "",
          domain ? `domain=${domain}` : "domain=[ip-only-or-unavailable]",
          network ? `network=${network}` : "",
          inbound ? `inbound=${inbound}` : "",
          rule ? `rule=${rule}` : "",
          rulePayload ? `payload=${rulePayload}` : "",
          chain ? `chain=${chain}` : "",
        ].filter(Boolean).join(" "),
      });

    }

    const ordered = [...samples].sort((a, b) => Number(b.google) - Number(a.google)).slice(0, Math.max(1, Math.min(128, maxRoutes)));
    return [
      `google_related_routes=${samples.filter(sample => sample.google).length}`,
      "coverage=active_connections_only; failed_short_lived_connections_may_be_missing",
      "play_app_status=not_tested",
      "privacy_note=explicit route feedback; app package names and destination domains are included",
      "filtered=source/destination IPs, connection IDs, byte counters, credentials, URL paths, subscription node names",
      `active_connection_count=${raw.length}`,
      `included_unique_routes=${ordered.length}`,
      `omitted_unique_routes=${samples.length - ordered.length}; uninspected_connections=${Math.max(0, raw.length-2048)}`,
      ...ordered.map((sample, index) => `route.${index + 1} seen=${sample.count} ${sample.line}`),
    ].join("\n");
  } catch {
    return "active_connections=unavailable\nparse_error=invalid response";
  }
}

export function sanitizeConnectionLog(text: string): string {
  return safeRouteText(sanitizeDiagnosticText(text))
    .replace(/\b(to|from)\s+[^\s,;]+/gi, "$1 [filtered-endpoint]")
    .replace(/\b(destination|host|domain|source)(\s*[:=]\s*)[^\s,;]+/gi, "$1$2[filtered-endpoint]")
    .replace(/\b(outbound|selector)(\s*[:=]\s*)([^\s,;]+)/gi, (_match, key, separator, value) => (
      `${key}${separator}${SAFE_ROUTE_TAGS.has(value) ? value : "[selected-node]"}`
    ))
    .replace(/\b(selected\s+node|node)(\s+(?:to|is)\s+|\s*[:=]\s*)[^\s,;]+/gi, "$1$2[selected-node]");
}

/** Preserve bare destination domains for opt-in routing feedback while still
 * removing credentials, URLs/paths, IPs and subscription node names. */
export function sanitizeRoutingFeedbackLog(text: string): string {
  return safeRouteText(sanitizeDiagnosticText(text))
    .replace(/\b(outbound|selector)(\s*[:=]\s*)([^\s,;]+)/gi, (_match, key, separator, value) => (
      `${key}${separator}${SAFE_ROUTE_TAGS.has(value) ? value : "[selected-node]"}`
    ))
    .replace(/\b(selected\s+node|node)(\s+(?:to|is)\s+|\s*[:=]\s*)[^\s,;]+/gi, "$1$2[selected-node]");
}

export function commandFailureContext(operation: IssueOperationContext): string {
  const output = operation.lastOutput
    .split(/\r?\n/)
    .filter((line) => !/^\s*\$\s+/.test(line))
    .join("\n");
  return [
    `captured_phase=${operation.phase || "idle"}`,
    `captured_command=${classifyOperationCommand(operation.lastCommand || "")}`,
    `background_status=${operation.backgroundStatus || "idle"}`,
    `background_command=${classifyOperationCommand(operation.backgroundArgs || "")}`,
    "",
    "[captured output]",
    deterministicSlice(sanitizeDiagnosticText(output), 1800),
  ].join("\n");
}

function issueReportText(report: Partial<IssueReport> = {}): string {
  const field = (label: string, value: string | undefined, limit: number): string => {
    const sanitized = deterministicSlice(sanitizeDiagnosticText(value || ""), limit);
    return `${label}：\n${sanitized || t("未填写")}`;
  };
  return [
    field(t("问题概述"), report.summary, 220),
    field(t("复现步骤"), report.reproduction, 320),
    field(t("期望结果"), report.expected, 160),
    field(t("实际结果"), report.actual, 220),
    field(t("发生频率 / 影响范围"), report.frequency, 140),
  ].join("\n\n");
}

export function buildIssueBody(parts: {
  kind: IssueKind;
  moduleProp: string;
  device: string;
  support: string;
  focusedContext: string;
  operation: IssueOperationContext;
  report?: Partial<IssueReport>;
}): string {
  const routeFeedback = parts.kind === "route-feedback";
  const sections = [
    "## Problem",
    "",
    issueReportText(parts.report),
    "",
    t("问题类型：{p0}", { p0: issueKindLabel(parts.kind) }),
    routeFeedback
      ? "\nPrivacy: this route-feedback report intentionally contains recent app package names and destination domains; IPs, URL paths, credentials and subscription node names are filtered."
      : "",
    "",
    "## Generated Context",
    "",
    issueSection("Focused Context", routeFeedback ? boundedLines(sanitizeDiagnosticText(parts.focusedContext), 2400) : deterministicSlice(sanitizeDiagnosticText(parts.focusedContext), 1800)),
    issueSection("Support Summary", routeFeedback ? compactSupport(sanitizeDiagnosticText(parts.support), 600) : deterministicSlice(sanitizeDiagnosticText(parts.support), 900)),
    issueSection("Module", deterministicSlice(sanitizeDiagnosticText(parts.moduleProp), 220)),
    issueSection("Device", deterministicSlice(sanitizeDiagnosticText(parts.device), 220)),
    issueSection("UI Operation", deterministicSlice(sanitizeDiagnosticText(operationText(parts.operation)), 350)),
  ].join("\n");
  return deterministicSlice(sections, MAX_ISSUE_BODY_CHARS);
}

export function buildIssueUrl(repo: string, title: string, canonicalBody: string): string {
  return `${repo}/issues/new?title=${encodeURIComponent(title)}&body=${encodeURIComponent(canonicalBody)}`;
}
