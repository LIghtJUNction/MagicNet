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

export type TransparentMode = "tun";

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
