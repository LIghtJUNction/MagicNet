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

export type TransparentMode = "proxy" | "external-tun" | "hybrid" | "tun";

export type RuntimeState = {
  singBoxState: "sing-box" | "stopped" | "unknown";
  singBox: string;
  fswatch: string;
  transparentMode: TransparentMode;
  api: string;
  webui: string;
  subPath: string;
};

export type HealthItem = {
  key: string;
  status: "ok" | "warn" | "fail" | "info";
  detail: string;
};

export type AiAssistant = "chatgpt" | "gemini" | "kimi" | "qwen" | "deepseek";

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
  secretSet: boolean;
  portOwner: string;
};

export type DnsState = {
  profile: "default" | "cloudflare-doh" | "cloudflare-dot" | "cloudflare-udp";
  primary: string;
  secondary: string;
  transport: string;
};

export type WarpState = {
  enabled: boolean;
  configured: boolean;
  tag: string;
  endpoint: string;
  addresses: number;
  allowedIps: number;
  importText: string;
  routeDomain: string;
};

export type SingBoxUiTarget = "zashboard";
export type WebuiPanelKind = "online" | "local";

export type WebuiPanel = {
  id: string;
  kind: WebuiPanelKind;
  name: string;
  url: string;
  downloadUrl: string;
  metadata: string;
};

export type ConfigEditorTarget = "sing-box";

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
  webuiPanels: WebuiPanel[];
  webuiPanelForm: WebuiPanel;
  commandPhase: "idle" | "accepted" | "queued" | "running" | "done" | "error";
  commandNotice: string;
  commandQueueDepth: number;
  statusDrawerOpen: boolean;
  status: "checking" | "online" | "offline" | "local";
  statusText: string;
  runtime: RuntimeState;
  lastCommand: string;
  output: string;
  appPolicy: AppPolicy;
  subscriptions: {
    singBox: string;
    singBoxUrls: string[];
  };
  backupPassword: string;
  backupPayload: string;
  restorePassword: string;
  restorePayload: string;
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
  activeTab: "control" | "config" | "health" | "topology" | "apps" | "block" | "subs" | "webui" | "logs";
};
