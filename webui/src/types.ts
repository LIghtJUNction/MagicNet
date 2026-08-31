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
  direct: string[];
  bypass: string[];
};

export type TransparentMode = "tun" | "ebpf";

export type TransparentEffectiveMode = "tun" | "local" | "hybrid" | "unknown";

export type WifiPolicyState = {
  enabled: boolean;
  policyMode: "blacklist" | "whitelist";
  intervalSeconds: number;
  supervisor: string;
  connected: boolean;
  ssid: string;
  bssid: string;
  matched: boolean;
  desiredMode: "rule" | "direct";
  currentMode: "rule" | "global" | "direct" | "unavailable";
  ssids: string[];
  bssids: string[];
};

export type RuntimeState = {
  singBoxState: "sing-box" | "stopped" | "unknown";
  singBox: string;
  fswatch: string;
  transparentMode: TransparentMode | "unknown";
  transparentEffectiveMode: TransparentEffectiveMode;
  transparentCapability: "ok" | "failed" | "not-required" | "unknown";
  transparentLocalCgroup:
    | "attached"
    | "missing"
    | "configured"
    | "inactive"
    | "unknown";
  transparentSharedTc:
    | "attached"
    | "missing"
    | "configured"
    | "pending"
    | "inactive"
    | "unknown";
  transparentSharedInterfaces: string[];
  transparentRecentError: string;
  transparentTransition: "stable" | "pending" | "rollback" | "unknown";
  api: string;
  webui: string;
  subPath: string;
};

export type HealthItem = {
  key: string;
  status: "ok" | "warn" | "fail" | "info";
  detail: string;
};

export type PackageInfo = {
  packageName: string;
  versionName: string;
  versionCode: number;
  appLabel: string;
  isSystem: boolean;
  uid: number;
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

export type ConfigEditorTarget = "sing-box";

export type SubscriptionScheduleInterval = "off" | "12" | "24" | "48" | "72";

export type SubscriptionState = {
  singBox: string;
  singBoxUrls: string[];
  userAgent: string;
  filters: string[];
  configuredCount: number;
  sourceMode: "url" | "local";
  updateRunning: boolean;
  updateLockOwner: string;
  lastPhase: string;
  lastResult: string;
  lastAttemptEpoch: number;
  lastSuccessEpoch: number;
  lastConfiguredCount: number;
  lastSourceCount: number;
  lastImportedCount: number;
  lastSkippedCount: number;
  lastGenerationId: string;
  lastReason: string;
  cacheCount: number;
  cacheProvenanceCount: number;
  cacheSource: string;
  scheduleIntervalHours: SubscriptionScheduleInterval;
  scheduleEnabled: boolean;
  scheduleRunning: boolean;
  scheduleOwner: string;
  scheduleOwnerValid: boolean;
  refreshEventCount: number;
  refreshErrorCount: number;
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
