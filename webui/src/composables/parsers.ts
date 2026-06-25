import { MODULE_DIR, SING_BOX_UI } from "@/constants";
import type { AppPolicy, BlocklistState, HealthItem, PackageInfo, RuntimeState, TransparentMode } from "@/types";

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
