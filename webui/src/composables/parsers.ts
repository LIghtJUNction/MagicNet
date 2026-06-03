import { CORE_UI, MODULE_DIR } from "@/constants";
import type { AppPolicy, BlocklistState, HealthItem, PackageInfo, RuntimeState } from "@/types";
import type { MihomoProvider } from "@/types";

export type SubscriptionState = {
  singBox: string;
  singBoxUrls: string[];
  mihomoProviders: MihomoProvider[];
};

export type CaptureState = {
  enabled: boolean;
  host: string;
  port: string;
  name: string;
  apps: string[];
  domains: string[];
  newApp: string;
  newDomain: string;
};

export type CertState = {
  dir: string;
  files: string[];
  name: string;
  text: string;
};

export type McpState = {
  enabled: boolean;
  bind: string;
  port: string;
  pid: string;
  url: string;
};

export type TailscaleState = {
  enabled: boolean;
  authKeySet: boolean;
  hostname: string;
  subnets: string;
};

export const runtimeDefaults: RuntimeState = {
  core: "unknown",
  selectedCore: "sing-box",
  singBox: "unknown",
  singBoxDisabled: false,
  mihomo: "unknown",
  watchdog: "unknown",
  fswatch: "unknown",
  transparentMode: "tun",
  hotspotMode: "proxy",
  vpnCoexist: "on",
  api: "http://127.0.0.1:9090",
  webui: CORE_UI,
  subPath: `${MODULE_DIR}/.config/sing-box/subscription.url`
};

export const blockDefaults: BlocklistState = {
  enabled: true,
  community: true,
  url: "https://raw.githubusercontent.com/LIghtJUNction/MagicMihomo/main/ruleset/magicnet/ban.yaml",
  manual: [],
  communityRules: [],
  communityDomains: [],
  allowRules: [],
  newDomain: ""
};

export const captureDefaults: CaptureState = {
  enabled: false,
  host: "192.168.1.100",
  port: "8888",
  name: "MagicNet-Capture",
  apps: [],
  domains: [],
  newApp: "",
  newDomain: ""
};

export const certDefaults: CertState = {
  dir: `${MODULE_DIR}/system/etc/security/cacerts`,
  files: [],
  name: "magicnet-ca",
  text: ""
};

export const mcpDefaults: McpState = {
  enabled: false,
  bind: "127.0.0.1",
  port: "8765",
  pid: "stopped",
  url: "http://127.0.0.1:8765/mcp"
};

export const tailscaleDefaults: TailscaleState = {
  enabled: false,
  authKeySet: false,
  hostname: "android-magicnet",
  subnets: "100.64.0.0/10"
};

export function parseRuntime(text: string, previous: RuntimeState): RuntimeState {
  const next = {
    ...runtimeDefaults,
    selectedCore: previous.selectedCore,
    singBoxDisabled: previous.singBoxDisabled,
    transparentMode: previous.transparentMode
  };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("sing-box:")) next.singBox = line.slice(9).trim() || "stopped";
    if (line.startsWith("sing-box-disabled:")) next.singBoxDisabled = line.slice(18).trim() === "1";
    if (line.startsWith("mihomo:")) next.mihomo = line.slice(7).trim() || "stopped";
    if (line.startsWith("watchdog:")) next.watchdog = line.slice(9).trim() || "stopped";
    if (line.startsWith("fswatch:")) next.fswatch = line.slice(8).trim() || "stopped";
    if (line.startsWith("Selected:")) {
      const selected = line.slice(9).trim();
      if (selected === "sing-box" || selected === "mihomo") next.selectedCore = selected;
    }
    if (line.startsWith("Transparent:")) next.transparentMode = line.includes("tproxy") ? "tproxy" : "tun";
    if (line.startsWith("Hotspot:")) next.hotspotMode = line.includes("direct") ? "direct" : "proxy";
    if (line.startsWith("VPN Coexist:")) next.vpnCoexist = line.includes("off") ? "off" : "on";
    if (line.startsWith("API:")) next.api = line.slice(4).trim() || next.api;
    if (line.startsWith("WebUI:")) next.webui = line.slice(6).trim() || next.webui;
    if (line.startsWith("Sub URL:")) next.subPath = line.slice(8).trim() || next.subPath;
  });
  if (next.singBox !== "stopped" && next.singBox !== "unknown") next.core = "sing-box";
  else if (next.mihomo !== "stopped" && next.mihomo !== "unknown") next.core = "mihomo";
  else if (next.singBox === "stopped" && next.mihomo === "stopped") next.core = "stopped";
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
  const next: SubscriptionState = { ...previous, singBoxUrls: [], mihomoProviders: [] };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    const provider = line.match(/^mihomo\.([A-Za-z0-9_-]+)=(.*)$/);
    if (/^sing-box\.\d+=/.test(line)) next.singBoxUrls.push(line.replace(/^sing-box\.\d+=/, ""));
    else if (provider) next.mihomoProviders.push({ name: provider[1], url: provider[2] });
    else if (line.startsWith("sing-box=")) next.singBox = line.slice(9);
  });
  if (!next.singBoxUrls.length && next.singBox) next.singBoxUrls = [next.singBox];
  return next;
}

export function parseCapture(text: string, previous: CaptureState): CaptureState {
  const next: CaptureState = { ...previous, apps: [], domains: [] };
  let section: "apps" | "domains" | null = null;
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (!line) return;
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) === "1";
    else if (line.startsWith("host=")) next.host = line.slice(5);
    else if (line.startsWith("port=")) next.port = line.slice(5);
    else if (line.startsWith("name=")) next.name = line.slice(5);
    else if (line === "apps:") section = "apps";
    else if (line === "domain suffixes:") section = "domains";
    else if (section) next[section].push(line);
  });
  return next;
}

export function parseCerts(text: string, previous: CertState): CertState {
  const next: CertState = { ...previous, files: [] };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (!line) return;
    if (line.startsWith("dir=")) next.dir = line.slice(4);
    else next.files.push(line);
  });
  return next;
}

export function parseMcp(text: string, previous: McpState): McpState {
  const next = { ...previous };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) !== "0";
    else if (line.startsWith("bind=")) next.bind = line.slice(5);
    else if (line.startsWith("port=")) next.port = line.slice(5);
    else if (line.startsWith("pid=")) next.pid = line.slice(4);
    else if (line.startsWith("url=")) next.url = line.slice(4);
  });
  if (!next.url) next.url = `http://${next.bind}:${next.port}/mcp`;
  return next;
}

export function parseTailscale(text: string, previous: TailscaleState): TailscaleState {
  const next = { ...previous };
  text.split(/\r?\n/).forEach((raw) => {
    const line = raw.trim();
    if (line.startsWith("enabled=")) next.enabled = line.slice(8) === "1";
    else if (line.startsWith("auth_key_set=")) next.authKeySet = line.slice(13) === "1";
    else if (line.startsWith("hostname=")) next.hostname = line.slice(9) || next.hostname;
    else if (line.startsWith("subnets=")) next.subnets = line.slice(8) || next.subnets;
  });
  return next;
}
