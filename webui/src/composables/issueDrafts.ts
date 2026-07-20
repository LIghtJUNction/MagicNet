const MAX_ISSUE_BODY_CHARS = 5200;

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

export function sanitizeDiagnosticText(text: string): string {
  return text
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
  backgroundLabel: string;
  backgroundArgs: string;
  backgroundStatus: string;
};

const SAFE_COMMANDS: Record<string, readonly string[]> = {
  app: ["list", "packages", "add", "add-many", "remove"],
  backup: ["create", "restore", "restore-file"],
  block: ["list", "add", "remove", "update"],
  config: ["apply", "show"],
  "config-editor": ["get", "save-file", "sync-template"],
  core: ["status", "logs"],
  diagnose: [],
  dns: ["status", "set", "test"],
  health: [],
  mcp: ["status", "start", "stop"],
  repair: [],
  service: ["status", "logs", "start", "stop", "restart", "ensure"],
  setup: [],
  sub: ["apply-file", "get", "list", "schedule", "set", "set-file", "status", "update", "update-all"],
  supervisor: ["status", "start", "stop", "restart"],
  sysroute: ["snapshot", "list", "add-rule", "del-rule", "add-route", "del-route"],
  topology: [],
  transparent: ["get", "set"],
  warp: ["status", "import", "route"],
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

export function buildIssueBody(parts: {
  moduleProp: string;
  device: string;
  support: string;
  operation: IssueOperationContext;
}): string {
  const sections = [
    "## Problem",
    "",
    "请在这里描述你遇到的问题、复现步骤和期望结果。",
    "",
    "## Generated Context",
    "",
    issueSection("Module", deterministicSlice(sanitizeDiagnosticText(parts.moduleProp), 500)),
    issueSection("Device", deterministicSlice(sanitizeDiagnosticText(parts.device), 500)),
    issueSection("Support Bundle", deterministicSlice(sanitizeDiagnosticText(parts.support), 3000)),
    issueSection("UI Operation", deterministicSlice(sanitizeDiagnosticText(operationText(parts.operation)), 600)),
  ].join("\n");
  return deterministicSlice(sections, MAX_ISSUE_BODY_CHARS);
}

export function buildIssueUrl(repo: string, title: string, canonicalBody: string): string {
  return `${repo}/issues/new?title=${encodeURIComponent(title)}&body=${encodeURIComponent(canonicalBody)}`;
}
