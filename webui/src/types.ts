export type ExecResult = {
  errno?: number;
  stdout?: string;
  stderr?: string;
  out?: string;
  err?: string;
};

export type AppPolicy = {
  mode: "blacklist" | "whitelist";
  proxy: string[];
  bypass: string[];
};

export type RuntimeState = {
  core: "sing-box" | "mihomo" | "stopped" | "unknown";
  selectedCore: "sing-box" | "mihomo";
  singBox: string;
  mihomo: string;
  watchdog: string;
  fswatch: string;
  transparentMode: "auto" | "tun" | "ebpf";
  hotspotMode: "proxy" | "direct";
  vpnCoexist: "on" | "off";
  api: string;
  webui: string;
  subPath: string;
};

export type HealthItem = {
  key: string;
  status: "ok" | "warn" | "fail" | "info";
  detail: string;
};

export type SpecialAction = "open-core" | "copy-core" | "copy-support";
export type AiAssistant = "chatgpt" | "gemini" | "kimi" | "qwen" | "deepseek";

export type ActionItem = {
  label: string;
  hint: string;
  icon: string;
  tone?: "strong";
  command?: string;
  special?: SpecialAction;
};

export type PackageInfo = {
  packageName: string;
  versionName: string;
  versionCode: number;
  appLabel: string;
  isSystem: boolean;
  uid: number;
};

export type SysrouteSnapshot = {
  generatedAt: string;
  interfaces: string[];
  addresses: string[];
  rules: string[];
  mainRoutes: string[];
  defaultRoutes: string[];
  tunRoutes: string[];
  allRoutes: string[];
  outputGuards: string[];
  notes: string[];
  raw: string;
};

export type BlocklistState = {
  enabled: boolean;
  community: boolean;
  url: string;
  manual: string[];
  communityRules: string[];
  communityDomains: string[];
  allowRules: string[];
  newDomain: string;
};

export type McpState = {
  enabled: boolean;
  bind: string;
  port: string;
  pid: string;
  url: string;
};

export type MihomoProvider = {
  name: string;
  url: string;
};

export type CoreUiTarget = "metacubex" | "yacd" | "zashboard";
export type WebuiPanelKind = "online" | "local";

export type WebuiPanel = {
  id: string;
  kind: WebuiPanelKind;
  name: string;
  url: string;
  downloadUrl: string;
  metadata: string;
};

export type ConfigEditorTarget = "mihomo" | "sing-box";

export type ConfigEditorState = {
  target: ConfigEditorTarget;
  text: string;
  originalText: string;
  loadedTarget: ConfigEditorTarget | "";
  dirty: boolean;
  lastCheck: "idle" | "ok" | "error";
  path: string;
};

export type State = {
  hasKsu: boolean;
  busy: boolean;
  activeTask: string;
  activeCommand: string;
  coreLaunch: {
    active: boolean;
    label: string;
    url: string;
  };
  coreAutoOpen: {
    enabled: boolean;
    target: CoreUiTarget;
    attempted: boolean;
  };
  webuiPanels: WebuiPanel[];
  webuiPanelForm: WebuiPanel;
  commandPhase: "idle" | "accepted" | "queued" | "running" | "done" | "error";
  commandNotice: string;
  commandQueueDepth: number;
  coreMenuOpen: boolean;
  statusDrawerOpen: boolean;
  status: "checking" | "online" | "offline" | "local";
  statusText: string;
  runtime: RuntimeState;
  lastCommand: string;
  output: string;
  appPolicy: AppPolicy;
  subscriptions: {
    singBox: string;
    mihomo: string;
    singBoxUrls: string[];
    mihomoProviders: MihomoProvider[];
  };
  backupPassword: string;
  backupPayload: string;
  restorePassword: string;
  restorePayload: string;
  certs: string[];
  certName: string;
  certText: string;
  certBase64: string;
  capture: {
    enabled: boolean;
    host: string;
    port: string;
    name: string;
    apps: string[];
    domains: string[];
    newApp: string;
    newDomain: string;
  };
  blocklist: BlocklistState;
  mcp: McpState;
  pingtest: string;
  topology: string;
  topologyFocus: string;
  sysrouteSnapshot: SysrouteSnapshot;
  sysroute: {
    rulePriority: string;
    ruleTable: string;
    routeTable: string;
    routeDest: string;
    routeDev: string;
    routeVia: string;
  };
  health: HealthItem[];
  packages: PackageInfo[];
  packageQuery: string;
  newPackage: string;
  newTarget: "proxy" | "bypass";
  configEditor: ConfigEditorState;
  activeTab: "control" | "config" | "health" | "topology" | "apps" | "block" | "subs" | "capture" | "certs" | "webui" | "logs";
};
