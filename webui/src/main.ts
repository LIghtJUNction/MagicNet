import {
  Activity,
  Ban,
  Bell,
  ChevronDown,
  ChevronUp,
  Copy,
  DownloadCloud,
  ExternalLink,
  FileText,
  Gauge,
  Github,
  Link,
  ListFilter,
  Lock,
  Plus,
  RadioTower,
  RefreshCw,
  RotateCcw,
  Route,
  Save,
  Server,
  ShieldCheck,
  ShieldPlus,
  Smartphone,
  Stethoscope,
  Terminal,
  TerminalSquare,
  Unplug,
  Wifi,
  X,
  Zap
} from "lucide";
import * as kernelsu from "kernelsu";
import "./styles.css";

type IconNodeChild = readonly [tag: string, attrs: Record<string, string | number>];
type IconNode = readonly [tag: string, attrs: Record<string, string | number>, children?: IconNodeChild[]];

const MODULE_DIR = "/data/adb/modules/MagicNet";
const CLI = `${MODULE_DIR}/cli`;
const CORE_UI = "http://127.0.0.1:9090/ui/cubex/";
const REPO = "https://github.com/LIghtJUNction/MagicNet";
const NODE_RENDER_LIMIT = 48;
const OUTPUT_RENDER_LIMIT = 6000;
const CLI_TIMEOUT_MS = 45000;
let cliQueue: Promise<unknown> = Promise.resolve();
const ksuBridge = (globalThis as { ksu?: { exec?: unknown } }).ksu;
const hasKsuBridge = typeof ksuBridge?.exec === "function";

type ExecResult = {
  errno?: number;
  stdout?: string;
  stderr?: string;
  out?: string;
  err?: string;
};

type AppPolicy = {
  mode: "blacklist" | "whitelist";
  proxy: string[];
  bypass: string[];
};

type RuntimeState = {
  core: "sing-box" | "mihomo" | "stopped" | "unknown";
  singBox: string;
  singBoxDisabled: boolean;
  mihomo: string;
  watchdog: string;
  fswatch: string;
  api: string;
  webui: string;
  subPath: string;
};

type HealthItem = {
  key: string;
  status: "ok" | "warn" | "fail" | "info";
  detail: string;
};

type PackageInfo = {
  packageName: string;
  versionName: string;
  versionCode: number;
  appLabel: string;
  isSystem: boolean;
  uid: number;
};

type RouteRules = {
  proxy: string[];
  direct: string[];
  block: string[];
  newDomain: string;
  newTarget: "proxy" | "direct" | "block";
};

type BlocklistState = {
  enabled: boolean;
  community: boolean;
  url: string;
  manual: string[];
  communityDomains: string[];
  newDomain: string;
};

type State = {
  hasKsu: boolean;
  busy: boolean;
  activeTask: string;
  coreMenuOpen: boolean;
  statusDrawerOpen: boolean;
  status: "checking" | "online" | "offline" | "local";
  statusText: string;
  runtime: RuntimeState;
  lastCommand: string;
  output: string;
  nodes: string[];
  currentNode: string;
  appPolicy: AppPolicy;
  subscriptions: {
    singBox: string;
    mihomo: string;
  };
  setupUrl: string;
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
  routes: RouteRules;
  blocklist: BlocklistState;
  health: HealthItem[];
  packages: PackageInfo[];
  packageQuery: string;
  newPackage: string;
  newTarget: "proxy" | "bypass";
  activeTab: "control" | "health" | "apps" | "routes" | "block" | "subs" | "capture" | "certs" | "logs";
};

const state: State = {
  hasKsu: hasKsuBridge,
  busy: false,
  activeTask: "",
  coreMenuOpen: false,
  statusDrawerOpen: false,
  status: "checking",
  statusText: "检测执行通道",
  runtime: {
    core: "unknown",
    singBox: "unknown",
    singBoxDisabled: false,
    mihomo: "unknown",
    watchdog: "unknown",
    fswatch: "unknown",
    api: "http://127.0.0.1:9090",
    webui: CORE_UI,
    subPath: `${MODULE_DIR}/.config/sing-box/subscription.url`
  },
  lastCommand: "",
  output: hasKsuBridge
    ? "面板已加载。正在读取 MagicNet 运行状态..."
    : "本地预览模式：这里不会伪造设备数据。通过 KernelSU/APatch 模块 WebUI 打开后，所有按钮会直接调用模块 CLI。",
  nodes: [],
  currentNode: "",
  appPolicy: {
    mode: "blacklist",
    proxy: [],
    bypass: []
  },
  subscriptions: {
    singBox: "",
    mihomo: ""
  },
  setupUrl: "",
  certs: [],
  certName: "magicnet-ca",
  certText: "",
  certBase64: "",
  capture: {
    enabled: false,
    host: "192.168.1.100",
    port: "8888",
    name: "MagicNet-Capture",
    apps: [],
    domains: [],
    newApp: "",
    newDomain: ""
  },
  routes: {
    proxy: [],
    direct: [],
    block: [],
    newDomain: "",
    newTarget: "proxy"
  },
  blocklist: {
    enabled: true,
    community: true,
    url: "https://raw.githubusercontent.com/LIghtJUNction/MagicMihomo/main/ruleset/magicnet/ban.yaml",
    manual: [],
    communityDomains: [],
    newDomain: ""
  },
  health: [],
  packages: [],
  packageQuery: "",
  newPackage: "",
  newTarget: "proxy",
  activeTab: "control"
};

const actions = [
  {
    title: "action.sh 菜单",
    items: [
      { label: "更新 sing-box 订阅", hint: "执行 action.sh 的订阅更新", icon: "DownloadCloud", command: "sub update", tone: "strong" },
      { label: "切换 sing-box 进程", hint: "只启动或停止 sing-box，不改禁用文件", icon: "Server", command: "service toggle sing-box" },
      { label: "切换 mihomo", hint: "启动或停止 mihomo", icon: "Route", command: "service toggle mihomo" },
      { label: "网络诊断", hint: "只在手动点击时运行", icon: "Stethoscope", command: "diagnose" },
      { label: "刷新状态描述", hint: "同步模块描述和运行状态", icon: "RefreshCw", command: "service status" }
    ]
  },
  {
    title: "模块维护",
    items: [
      { label: "重启 TUN 内核", hint: "停止后重新拉起首选内核", icon: "RotateCcw", command: "service restart", tone: "strong" },
      { label: "一键自修复", hint: "重载配置、热点和 VPN 共存", icon: "Zap", command: "repair", tone: "strong" },
      { label: "重载热点转发", hint: "应用 tether 转发规则", icon: "Wifi", command: "hotspot reload" },
      { label: "重载 VPN 共存", hint: "应用外部 VPN 保护规则", icon: "ShieldCheck", command: "vpn reload" },
      { label: "清空旧连接", hint: "关闭 Clash API 连接表", icon: "Unplug", command: "api close-all" }
    ]
  }
];

const quickModes = [
  { label: "规则", value: "rule" },
  { label: "全局", value: "global" },
  { label: "直连", value: "direct" }
];

const tabs = [
  { key: "control", label: "控制", icon: "Gauge" },
  { key: "health", label: "诊断", icon: "Stethoscope" },
  { key: "apps", label: "应用", icon: "ListFilter" },
  { key: "routes", label: "分流", icon: "Route" },
  { key: "block", label: "黑名单", icon: "Ban" },
  { key: "subs", label: "订阅", icon: "DownloadCloud" },
  { key: "capture", label: "抓包", icon: "ShieldCheck" },
  { key: "certs", label: "证书", icon: "ShieldPlus" },
  { key: "logs", label: "输出", icon: "Terminal" }
] as const;

const iconMap: Record<string, IconNode> = {
  Activity,
  Ban,
  Bell,
  ChevronDown,
  ChevronUp,
  Copy,
  DownloadCloud,
  ExternalLink,
  FileText,
  Gauge,
  Github,
  Link,
  ListFilter,
  Lock,
  Plus,
  RadioTower,
  RefreshCw,
  RotateCcw,
  Route,
  Save,
  Server,
  ShieldCheck,
  ShieldPlus,
  Smartphone,
  Stethoscope,
  Terminal,
  TerminalSquare,
  Unplug,
  Wifi,
  X,
  Zap
};

function icon(name: string, size = 18): string {
  const item = iconMap[name];
  if (!item) return "";
  const attrs = item[1];
  const children = item[2] || [];
  const attrText = Object.entries({ ...attrs, width: String(size), height: String(size) })
    .map(([key, value]) => `${key}="${value}"`)
    .join(" ");
  const childText = children
    .map(([tag, childAttrs]) => `<${tag} ${Object.entries(childAttrs).map(([key, value]) => `${key}="${value}"`).join(" ")} />`)
    .join("");
  return `<${item[0]} ${attrText}>${childText}</${item[0]}>`;
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => {
    const entities: Record<string, string> = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;"
    };
    return entities[char] || char;
  });
}

function compactOutput(value: string, limit = OUTPUT_RENDER_LIMIT): string {
  if (value.length <= limit) return value;
  const head = value.slice(0, Math.floor(limit * 0.58));
  const tail = value.slice(value.length - Math.floor(limit * 0.32));
  return `${head}\n\n... 输出过长，已折叠中间 ${value.length - head.length - tail.length} 个字符 ...\n\n${tail}`;
}

function normalizeExecResult(result: ExecResult): string {
  const stdout = result.stdout || result.out || "";
  const stderr = result.stderr || result.err || "";
  return [stdout, stderr].filter(Boolean).join("\n").trim();
}

function execFailed(text: string): boolean {
  return /\b(error|failed|fail|curl:|not reachable|Connection refused|Could not connect)\b/i.test(text);
}

function hasProcess(value: string): boolean {
  return value !== "stopped" && value !== "unknown" && value.trim() !== "";
}

function nextFrame(): Promise<void> {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer = 0;
  const timeout = new Promise<never>((_, reject) => {
    timer = window.setTimeout(() => {
      reject(new Error(`${label} 超过 ${Math.round(ms / 1000)} 秒仍未返回，请到“输出”页查看日志或稍后重试。`));
    }, ms);
  });
  return Promise.race([promise, timeout]).finally(() => window.clearTimeout(timer));
}

function enqueueCli<T>(task: () => Promise<T>): Promise<T> {
  const run = cliQueue.then(task, task);
  cliQueue = run.catch(() => undefined);
  return run;
}

async function runCli(args: string, options: { refreshApps?: boolean; quiet?: boolean; label?: string } = {}): Promise<string> {
  const command = `su -c ${shellQuote(`${CLI} ${args}`)}`;
  state.lastCommand = command;

  if (!state.hasKsu) {
    const text = `当前浏览器没有 KernelSU 执行通道。\n\n在真机终端可执行：\n${command}`;
    if (!options.quiet) {
      state.output = text;
      render();
    }
    return text;
  }

  if (!options.quiet) {
    state.busy = true;
    state.activeTask = options.label || args;
    state.output = `$ ${command}\n执行中...`;
    render();
    await nextFrame();
  }

  try {
    const result = await enqueueCli(() => withTimeout(kernelsu.exec(command), CLI_TIMEOUT_MS, options.label || args));
    const text = normalizeExecResult(result);
    if (!options.quiet) {
      state.output = `$ ${command}\n${text || "完成"}`;
    }
    if (options.refreshApps) {
      await refreshApps(true);
    }
    return text;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    state.output = `$ ${command}\n执行失败：${message}`;
    return state.output;
  } finally {
    if (!options.quiet) {
      state.busy = false;
      state.activeTask = "";
      render();
    }
  }
}

function parseAppPolicy(text: string): AppPolicy {
  const policy: AppPolicy = { mode: "blacklist", proxy: [], bypass: [] };
  let section: "proxy" | "bypass" | null = null;

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line === "proxy apps:") {
      section = "proxy";
      continue;
    }
    if (line === "bypass apps:") {
      section = "bypass";
      continue;
    }
    if (line.startsWith("mode=")) {
      const mode = line.slice(5);
      policy.mode = mode === "whitelist" ? "whitelist" : "blacklist";
      continue;
    }
    if (section) policy[section].push(line);
  }

  return policy;
}

function parseRuntimeStatus(text: string): RuntimeState {
  const next: RuntimeState = {
    core: "unknown",
    singBox: "unknown",
    singBoxDisabled: state.runtime.singBoxDisabled,
    mihomo: "unknown",
    watchdog: "unknown",
    fswatch: "unknown",
    api: state.runtime.api,
    webui: state.runtime.webui,
    subPath: state.runtime.subPath
  };

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("sing-box:")) next.singBox = line.slice("sing-box:".length).trim() || "stopped";
    if (line.startsWith("sing-box-disabled:")) next.singBoxDisabled = line.slice("sing-box-disabled:".length).trim() === "1";
    if (line.startsWith("mihomo:")) next.mihomo = line.slice("mihomo:".length).trim() || "stopped";
    if (line.startsWith("watchdog:")) next.watchdog = line.slice("watchdog:".length).trim() || "stopped";
    if (line.startsWith("fswatch:")) next.fswatch = line.slice("fswatch:".length).trim() || "stopped";
    if (line.startsWith("API:")) next.api = line.slice("API:".length).trim();
    if (line.startsWith("WebUI:")) next.webui = line.slice("WebUI:".length).trim();
    if (line.startsWith("Sub URL:")) next.subPath = line.slice("Sub URL:".length).trim();
  }

  if (next.singBox !== "stopped" && next.singBox !== "unknown") {
    next.core = "sing-box";
  } else if (next.mihomo !== "stopped" && next.mihomo !== "unknown") {
    next.core = "mihomo";
  } else if (next.singBox === "stopped" && next.mihomo === "stopped") {
    next.core = "stopped";
  }

  return next;
}

function coreUiUrl(): string {
  return state.runtime.webui || CORE_UI;
}

async function refreshStatus(quiet = false): Promise<void> {
  if (!state.hasKsu) {
    state.status = "local";
    state.statusText = "本地预览";
    if (!quiet) render();
    return;
  }

  if (!quiet) {
    state.status = "checking";
    state.statusText = "读取内核状态";
    render();
  }

  const text = await runCli("service status", { quiet: true });
  state.runtime = parseRuntimeStatus(text);
  if (state.runtime.core === "sing-box" || state.runtime.core === "mihomo") {
    state.status = "online";
    state.statusText = `${state.runtime.core} 在线`;
  } else if (state.runtime.core === "stopped") {
    state.status = "offline";
    state.statusText = "TUN 未运行";
  } else {
    state.status = "offline";
    state.statusText = "状态未知";
  }
  if (!quiet) {
    state.output = `$ su -c ${CLI} service status\n${text}`;
    render();
  }
}

async function openCoreUi(): Promise<void> {
  await openCoreUiTarget("metacubex");
}

function coreUiTargetUrl(target: "metacubex" | "yacd" | "zashboard"): string {
  if (target === "yacd") return "https://yacd.metacubex.one/?hostname=127.0.0.1&port=9090&secret=";
  if (target === "zashboard") return `${state.runtime.api}/ui/`;
  return `${state.runtime.api}/ui/cubex/`;
}

async function openCoreUiTarget(target: "metacubex" | "yacd" | "zashboard"): Promise<void> {
  if (!state.hasKsu) {
    state.output = "当前浏览器没有 KernelSU 执行通道，无法确认内核 WebUI 是否在线。";
    render();
    return;
  }

  const text = await runCli("api groups", { quiet: true });
  if (!text || execFailed(text)) {
    state.status = "offline";
    state.statusText = "Clash API 未启动";
    state.activeTab = "health";
    state.output = [
      "内核 WebUI 没有打开：127.0.0.1:9090 当前不可用。",
      "",
      "先点“重启 TUN 内核”或“一键自修复”，等 Clash API 恢复后再打开内核 WebUI。",
      "",
      text
    ].filter(Boolean).join("\n");
    await refreshHealth(true);
    render();
    return;
  }

  const url = coreUiTargetUrl(target);
  state.output = `正在打开内核 WebUI：\n${url}\n\n如果当前 WebView 没有跳转，请复制这个地址到浏览器打开。`;
  render();
  window.location.assign(url);
}

async function runAction(command: string): Promise<void> {
  const text = await runCli(command, { label: command });
  if (/^health\b/.test(command)) {
    state.health = parseHealth(text);
    state.activeTab = "health";
  }
  if (/^service status\b/.test(command)) {
    state.runtime = parseRuntimeStatus(text);
  }
  if (execFailed(text)) {
    await refreshStatus(true);
    await refreshHealth(true);
    render();
    return;
  }

  if (/^(service|repair|mode|hotspot|vpn)\b/.test(command)) {
    await refreshStatus(true);
    render();
  }
  if (/^(sub|setup)\b/.test(command)) {
    await refreshSubscriptions(true);
    render();
  }
  if (/^block\b/.test(command)) {
    await refreshBlocklist(true);
    render();
  }
}

async function refreshDashboard(quiet = false): Promise<void> {
  if (!quiet) {
    state.busy = true;
    state.activeTask = "刷新面板";
    state.output = "正在刷新运行状态、订阅和模块策略...";
    render();
  }
  try {
    await refreshStatus(true);
    if (state.activeTab === "control") {
      await refreshNodes(true);
    } else if (state.activeTab === "subs") {
      await refreshSubscriptions(true);
    } else if (state.activeTab === "apps") {
      await refreshApps(true);
    } else if (state.activeTab === "routes") {
      await refreshRoutes(true);
    } else if (state.activeTab === "block") {
      await refreshBlocklist(true);
    } else if (state.activeTab === "capture") {
      await refreshCapture(true);
    } else if (state.activeTab === "certs") {
      await refreshCerts(true);
    } else if (state.activeTab === "health") {
      await refreshHealth(true);
    }
    if (!quiet) {
      state.output = "面板刷新完成。";
    }
  } finally {
    if (!quiet) {
      state.busy = false;
      state.activeTask = "";
      render();
    }
  }
}

async function refreshApps(quiet = false): Promise<void> {
  const text = await runCli("app list", { quiet });
  if (state.hasKsu && text) {
    state.appPolicy = parseAppPolicy(text);
  }
  if (!quiet) render();
}

function parseRouteRules(text: string): RouteRules {
  const next: RouteRules = {
    ...state.routes,
    proxy: [],
    direct: [],
    block: []
  };
  let section: "proxy" | "direct" | "block" | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line === "proxy domain suffixes:") {
      section = "proxy";
      continue;
    }
    if (line === "direct domain suffixes:") {
      section = "direct";
      continue;
    }
    if (line === "block domain suffixes:") {
      section = "block";
      continue;
    }
    if (section) next[section].push(line);
  }
  return next;
}

async function refreshRoutes(quiet = false): Promise<void> {
  const text = await runCli("route list", { quiet });
  if (state.hasKsu && text) {
    state.routes = parseRouteRules(text);
  }
  if (!quiet) render();
}

function parseBlocklist(text: string): BlocklistState {
  const next: BlocklistState = { ...state.blocklist, manual: [], communityDomains: [] };
  let section: "manual" | "community" | null = null;

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("enabled=")) {
      next.enabled = line.slice("enabled=".length) !== "0";
      continue;
    }
    if (line.startsWith("community=")) {
      next.community = line.slice("community=".length) !== "0";
      continue;
    }
    if (line.startsWith("url=")) {
      next.url = line.slice("url=".length);
      continue;
    }
    if (line === "manual domain suffixes:") {
      section = "manual";
      continue;
    }
    if (line === "community domain suffixes:") {
      section = "community";
      continue;
    }
    if (section === "manual") next.manual.push(line);
    if (section === "community") next.communityDomains.push(line);
  }

  return next;
}

async function refreshBlocklist(quiet = false): Promise<void> {
  const text = await runCli("block list", { quiet });
  if (state.hasKsu && text) {
    state.blocklist = parseBlocklist(text);
  }
  if (!quiet) render();
}

function parseSubscriptions(text: string): State["subscriptions"] {
  const next = { ...state.subscriptions };
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("sing-box=")) next.singBox = line.slice("sing-box=".length);
    if (line.startsWith("mihomo=")) next.mihomo = line.slice("mihomo=".length);
  }
  return next;
}

async function refreshSubscriptions(quiet = false): Promise<void> {
  const text = await runCli("sub list", { quiet });
  if (state.hasKsu && text) {
    state.subscriptions = parseSubscriptions(text);
  }
  if (!quiet) render();
}

async function refreshNodes(quiet = false): Promise<void> {
  if (!quiet) {
    state.busy = true;
    state.activeTask = "读取节点";
    state.output = "正在读取候选出口。大订阅首次读取会生成本地缓存，后续会更快。";
    render();
    await nextFrame();
  }
  try {
    const current = await runCli("node current", { quiet: true });
    const list = await runCli("node list", { quiet: true });
    if (state.hasKsu) {
      state.currentNode = current.trim();
      state.nodes = list
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);
      if (!quiet) {
        state.output = state.nodes.length
          ? `当前策略值：${state.currentNode || "未读取"}\n候选出口：${state.nodes.length} 个`
          : `当前策略值：${state.currentNode || "未读取"}\n没有可展示的候选出口。请更新订阅，或到内核面板检查当前策略组。`;
      }
    }
  } finally {
    if (!quiet) {
      state.busy = false;
      state.activeTask = "";
      render();
    }
  }
}

async function switchNode(name: string): Promise<void> {
  if (!name) return;
  await runCli(`node use ${shellQuote(name)}`);
  await refreshNodes(true);
}

async function saveSetupSubscription(): Promise<void> {
  const url = state.setupUrl.trim();
  if (!/^https?:\/\/\S+$/i.test(url)) {
    state.output = "订阅链接格式不对，必须是 http(s) URL。";
    render();
    return;
  }
  await runCli(`setup ${shellQuote(url)}`);
  state.setupUrl = "";
  await refreshSubscriptions(true);
  await refreshHealth(true);
  render();
}

function parseCapture(text: string): State["capture"] {
  const next = { ...state.capture, apps: [], domains: [] };
  let section: "apps" | "domains" | null = null;

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line === "apps:") {
      section = "apps";
      continue;
    }
    if (line === "domain suffixes:") {
      section = "domains";
      continue;
    }
    if (line.startsWith("enabled=")) {
      next.enabled = line.slice("enabled=".length) === "1";
      continue;
    }
    if (line.startsWith("host=")) {
      next.host = line.slice("host=".length);
      continue;
    }
    if (line.startsWith("port=")) {
      next.port = line.slice("port=".length);
      continue;
    }
    if (line.startsWith("name=")) {
      next.name = line.slice("name=".length);
      continue;
    }
    if (section === "apps") next.apps.push(line);
    if (section === "domains") next.domains.push(line);
  }

  return next;
}

async function refreshCapture(quiet = false): Promise<void> {
  const text = await runCli("capture list", { quiet });
  if (state.hasKsu && text) {
    state.capture = parseCapture(text);
  }
  if (!quiet) render();
}

function parseCerts(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("dir=") && !line.startsWith("["));
}

async function refreshCerts(quiet = false): Promise<void> {
  const text = await runCli("cert list", { quiet });
  if (state.hasKsu && text) {
    state.certs = parseCerts(text);
  }
  if (!quiet) render();
}

function parseHealth(text: string): HealthItem[] {
  const items: HealthItem[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || !line.includes("=")) continue;
    const [head, ...tail] = line.split(/\t/);
    const [key, statusText] = head.split("=");
    const status = ["ok", "warn", "fail", "info"].includes(statusText) ? statusText as HealthItem["status"] : "info";
    items.push({
      key,
      status,
      detail: tail.join("\t") || ""
    });
  }
  return items;
}

async function refreshHealth(quiet = false): Promise<void> {
  const text = await runCli("health", { quiet });
  if (state.hasKsu && text) {
    state.health = parseHealth(text);
  }
  if (!quiet) {
    state.activeTab = "health";
    render();
  }
}

async function generateSupportBundle(): Promise<void> {
  const text = await runCli("support bundle");
  if (text) {
    await navigator.clipboard?.writeText(text);
    if (state.hasKsu) kernelsu.toast?.("支持包已复制");
  }
}

function utf8ToBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary);
}

const healthLabels: Record<string, { label: string; icon: string; fix?: string; fixLabel?: string }> = {
  core: { label: "TUN 内核", icon: "Server", fix: "service restart", fixLabel: "重启" },
  tun: { label: "TUN 网卡", icon: "RadioTower", fix: "service restart", fixLabel: "重启" },
  watchdog: { label: "看门狗", icon: "Bell", fix: "service restart", fixLabel: "重启服务" },
  fswatch: { label: "配置监听", icon: "Activity", fix: "service restart", fixLabel: "重启服务" },
  api: { label: "Clash API", icon: "Gauge", fix: "service restart", fixLabel: "重启" },
  "sing-box-sub": { label: "sing-box 订阅", icon: "DownloadCloud", fix: "sub update-all", fixLabel: "更新" },
  "mihomo-sub": { label: "mihomo 订阅", icon: "DownloadCloud" },
  capture: { label: "抓包规则", icon: "ShieldCheck", fix: "capture apply", fixLabel: "应用" },
  blocklist: { label: "联 ban 黑名单", icon: "Ban", fix: "block update", fixLabel: "更新" },
  hotspot: { label: "热点转发", icon: "Wifi", fix: "hotspot reload", fixLabel: "重载" },
  vpn: { label: "VPN 共存", icon: "ShieldCheck", fix: "vpn reload", fixLabel: "重载" },
  certs: { label: "系统 CA", icon: "ShieldPlus" }
};

function healthSummary(): { ok: number; warn: number; fail: number; info: number } {
  return state.health.reduce(
    (acc, item) => {
      acc[item.status] += 1;
      return acc;
    },
    { ok: 0, warn: 0, fail: 0, info: 0 }
  );
}

function healthPanel(): string {
  const summary = healthSummary();
  const items = state.health.length
    ? state.health
      .map((item) => {
        const meta = healthLabels[item.key] || { label: item.key, icon: "Stethoscope" };
        return `
          <div class="health-row ${item.status}">
            <span class="health-mark">${icon(meta.icon, 18)}</span>
            <div>
              <strong>${escapeHtml(meta.label)}</strong>
              <small>${escapeHtml(item.detail || item.status)}</small>
            </div>
            <span class="health-state">${item.status}</span>
            ${meta.fix ? `<button data-run="${meta.fix}">${escapeHtml(meta.fixLabel || "修复")}</button>` : ""}
          </div>
        `;
      })
      .join("")
    : `<div class="picker-empty"><strong>还没有诊断结果</strong><span>点击运行健康诊断，面板会检查内核、TUN、API、订阅、抓包、热点、VPN 共存和证书目录。</span></div>`;

  return `
    <div class="health-panel">
      <div class="health-hero">
        <div>
          <span class="eyebrow">Health Check</span>
          <h3>一键看清透明代理链路</h3>
          <p>诊断不是日志堆叠，而是把最容易出问题的链路拆成可判定项目。</p>
        </div>
        <div class="health-actions">
          <button class="command-primary" data-run="repair">${icon("Zap", 18)}一键自修复</button>
          <button class="command-secondary" data-health-run>${icon("Stethoscope", 18)}运行诊断</button>
          <button class="command-secondary" data-support-bundle>${icon("Copy", 18)}复制支持包</button>
        </div>
      </div>
      <div class="health-summary">
        <div><strong>${summary.ok}</strong><span>正常</span></div>
        <div><strong>${summary.warn}</strong><span>警告</span></div>
        <div><strong>${summary.fail}</strong><span>失败</span></div>
        <div><strong>${summary.info}</strong><span>信息</span></div>
      </div>
      <div class="health-list">${items}</div>
    </div>
  `;
}

function nodePanel(): string {
  const selectedOutsideLimit = state.currentNode && !state.nodes.slice(0, NODE_RENDER_LIMIT).includes(state.currentNode);
  const visibleNodes = state.nodes.length
    ? [
      ...(selectedOutsideLimit ? [state.currentNode] : []),
      ...state.nodes.filter((name) => name !== state.currentNode).slice(0, NODE_RENDER_LIMIT)
    ]
    : [];
  const hiddenCount = Math.max(0, state.nodes.length - visibleNodes.length);
  const nodeRows = visibleNodes.length
    ? visibleNodes
      .map((name) => {
        const selected = name === state.currentNode;
        return `
          <button class="node-row ${selected ? "selected" : ""}" data-node-use="${escapeHtml(name)}" ${selected ? "disabled" : ""}>
            <span>${selected ? icon("ShieldCheck", 17) : icon("Route", 17)}</span>
            <div>
              <strong>${escapeHtml(name)}</strong>
              <small>候选出口</small>
            </div>
            <small>${selected ? "当前出口" : "切换"}</small>
          </button>
        `;
      })
      .join("")
    : `<div class="picker-empty"><strong>还没有节点列表</strong><span>先更新订阅，再点刷新节点。高级策略和 Provider 状态在内核 WebUI 里看。</span></div>`;

  return `
    <div class="node-panel">
      <div class="node-head">
        <div>
          <span class="eyebrow">Proxy Selector</span>
          <h3>${escapeHtml(state.currentNode || "未读取当前节点")}</h3>
          <p>这里只做快速切换和状态确认；高级策略和 Provider 状态交给内核 WebUI。当前渲染 ${visibleNodes.length}/${state.nodes.length} 条${hiddenCount ? `，剩余 ${hiddenCount} 条在内核面板查看` : ""}。</p>
        </div>
        <div class="node-actions">
          <button class="command-secondary" data-refresh-nodes>${icon("RefreshCw", 17)}刷新节点</button>
          <a class="command-secondary" data-open-core-ui href="${escapeHtml(coreUiUrl())}">${icon("ExternalLink", 17)}内核节点页</a>
          <button class="command-secondary" data-run="sub update-all">${icon("DownloadCloud", 17)}更新订阅</button>
        </div>
      </div>
      <div class="node-list">${nodeRows}</div>
    </div>
  `;
}

function activeTabPanel(tab: State["activeTab"]): string {
  if (tab === "control") {
    const restartSingBoxDisabled = state.runtime.singBoxDisabled ? "disabled" : "";
    return `
      <div class="tab-panel show">
        <div class="control-quick">
          ${commandDeck()}
        </div>
        <section class="runtime-control">
          <div class="runtime-toggle">
            <div>
              <span class="eyebrow">Core Switch</span>
              <h3>sing-box 内核开关</h3>
              <p>${state.runtime.singBoxDisabled ? "已通过 .disable_sing_box 禁用，重启到 sing-box 不可用。" : "当前允许 sing-box 作为 TUN 内核启动。"}</p>
            </div>
            <button class="toggle ${state.runtime.singBoxDisabled ? "" : "on"}" data-singbox-disable-toggle>
              ${state.runtime.singBoxDisabled ? "启用 sing-box" : "禁用 sing-box"}
            </button>
          </div>
          <form class="restart-form" data-restart-form>
            <label>
              <span>重启目标</span>
              <select name="target">
                <option value="current">重启当前内核</option>
                <option value="sing-box" ${restartSingBoxDisabled}>重启到 sing-box${state.runtime.singBoxDisabled ? "（已禁用）" : ""}</option>
                <option value="mihomo">重启到 mihomo</option>
              </select>
            </label>
            <button type="submit">${icon("RotateCcw", 17)}执行重启</button>
          </form>
        </section>
        ${setupPanel()}
        <div class="control-groups">
          ${actions
            .map(
              (group) => `
                <section class="control-group">
                  <div class="control-group-head">
                    <h3>${escapeHtml(group.title)}</h3>
                  </div>
                  <div class="action-grid">
                    ${group.items.map((item) => `
                      <button class="action-card ${item.tone || ""}" data-run="${item.command}">
                        <span>${icon(item.icon, 20)}</span>
                        <strong>${item.label}</strong>
                        <small>${item.hint}</small>
                      </button>
                    `).join("")}
                  </div>
                </section>
              `
            )
            .join("")}
        </div>
        ${nodePanel()}
        <div class="mode-panel">
          <div>
            <h3>代理模式</h3>
            <p>仅切换内核策略，网络入口保持 TUN。</p>
          </div>
          <div class="segmented">
            ${quickModes
              .map((item) => `<button data-mode="${item.value}">${item.label}</button>`)
              .join("")}
          </div>
        </div>
      </div>
    `;
  }

  if (tab === "health") return `<div class="tab-panel show">${healthPanel()}</div>`;

  if (tab === "apps") {
    return `
      <div class="tab-panel show">
        <div class="section-intro">
          <div>
            <span class="eyebrow">Per-App TUN</span>
            <h3>分应用 TUN 策略</h3>
            <p>${state.appPolicy.mode === "whitelist" ? "白名单：只有 proxy 列表进入 TUN" : "黑名单：bypass 列表不进入 TUN"}</p>
          </div>
          <div class="segmented">
            <button class="${state.appPolicy.mode === "blacklist" ? "selected" : ""}" data-app-mode="blacklist">黑名单</button>
            <button class="${state.appPolicy.mode === "whitelist" ? "selected" : ""}" data-app-mode="whitelist">白名单</button>
          </div>
        </div>
        <form class="package-form" data-package-form>
          <input name="package" value="${escapeHtml(state.newPackage)}" placeholder="com.example.app" spellcheck="false" />
          <select name="target">
            <option value="proxy" ${state.newTarget === "proxy" ? "selected" : ""}>加入 proxy</option>
            <option value="bypass" ${state.newTarget === "bypass" ? "selected" : ""}>加入 bypass</option>
          </select>
          <button type="submit">${icon("Plus", 17)}添加</button>
        </form>
        <div class="package-picker">
          <div class="picker-head">
            <div>
              <h3>已安装应用</h3>
              <p>从 KernelSU 读取用户应用，点选后写入 MagicNet app list。</p>
            </div>
            <button class="scan-button" data-scan-packages>${icon("RefreshCw", 17)}扫描用户应用</button>
          </div>
          <input class="package-search" data-package-query value="${escapeHtml(state.packageQuery)}" placeholder="搜索应用名或包名" />
          <div class="package-results">${packagePicker()}</div>
        </div>
        <div class="list-columns">
          <div class="list-panel">
            <div class="list-title"><span>${icon("Route", 17)}</span>Proxy apps</div>
            ${appList(state.appPolicy.proxy, "proxy")}
          </div>
          <div class="list-panel">
            <div class="list-title"><span>${icon("Ban", 17)}</span>Bypass apps</div>
            ${appList(state.appPolicy.bypass, "bypass")}
          </div>
        </div>
      </div>
    `;
  }

  if (tab === "routes") return `<div class="tab-panel show">${routePanel()}</div>`;
  if (tab === "block") return `<div class="tab-panel show">${blocklistPanel()}</div>`;
  if (tab === "subs") return `<div class="tab-panel show">${subscriptionsSection()}</div>`;
  if (tab === "capture") return `<div class="tab-panel show">${capturePanel()}</div>`;
  if (tab === "certs") return `<div class="tab-panel show">${certPanel()}</div>`;

  return `
    <div class="tab-panel show">
      <div class="log-toolbar">
        <button data-run="service logs sing-box 160">${icon("FileText", 17)}sing-box 日志</button>
        <button data-run="service logs mihomo 160">${icon("FileText", 17)}mihomo 日志</button>
        <button data-run="service status">${icon("RefreshCw", 17)}状态快照</button>
        <button data-health-run>${icon("Stethoscope", 17)}健康诊断</button>
        <button data-support-bundle>${icon("Copy", 17)}支持包</button>
        <button data-copy-last>${icon("Copy", 17)}复制命令</button>
      </div>
      <pre class="terminal">${escapeHtml(compactOutput(state.output))}</pre>
    </div>
  `;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary);
}

function simpleList(items: string[], kind: "app" | "domain"): string {
  if (items.length === 0) {
    return `<div class="empty">暂无规则</div>`;
  }

  return items
    .map(
      (item) => `
        <div class="app-row">
          <span>${escapeHtml(item)}</span>
          <button class="icon-button" data-remove-capture="${kind}" data-value="${escapeHtml(item)}" title="移除">
            ${icon("X", 16)}
          </button>
        </div>
      `
    )
    .join("");
}

function blockDomainList(items: string[], removable: boolean): string {
  if (items.length === 0) {
    return `<div class="empty">暂无域名后缀</div>`;
  }

  return items
    .slice(0, 120)
    .map(
      (domain) => `
        <div class="app-row">
          <span>${escapeHtml(domain)}</span>
          ${removable ? `<button class="icon-button" data-remove-block="${escapeHtml(domain)}" title="移除">${icon("X", 16)}</button>` : ""}
        </div>
      `
    )
    .join("");
}

function blocklistPanel(): string {
  const communityCount = state.blocklist.communityDomains.length;
  return `
    <div class="section-intro block-intro">
      <div>
        <span class="eyebrow">Community Blocklist</span>
        <h3>联 ban 黑名单</h3>
        <p>mihomo 使用 mnban rule-provider；sing-box 同步为本地域名后缀阻断规则。这里管理 MagicNet 独有的安全黑名单。</p>
      </div>
      <div class="section-actions">
        <button class="command-secondary" data-refresh-block>${icon("RefreshCw", 17)}读取</button>
        <button class="command-primary" data-run="block update">${icon("DownloadCloud", 17)}更新社区库</button>
      </div>
    </div>
    <div class="block-grid">
      <section class="capture-card">
        <div class="sub-head">
          <div>
            <h3>策略开关</h3>
            <p>关闭总开关会从双内核移除 MagicNet 注入的阻断规则。</p>
          </div>
        </div>
        <div class="switch-stack">
          <button class="toggle ${state.blocklist.enabled ? "on" : ""}" data-block-toggle>
            ${state.blocklist.enabled ? "黑名单已启用" : "黑名单已关闭"}
          </button>
          <button class="toggle ${state.blocklist.community ? "on" : ""}" data-community-toggle>
            ${state.blocklist.community ? "社区库已启用" : "社区库已关闭"}
          </button>
        </div>
        <form class="block-url-form" data-block-url-form>
          <label>
            <span>社区库 URL</span>
            <input value="${escapeHtml(state.blocklist.url)}" spellcheck="false" />
          </label>
          <button type="submit">${icon("Save", 17)}保存 URL</button>
        </form>
      </section>
      <section class="capture-card">
        <div class="sub-head">
          <div>
            <h3>手动阻断域名</h3>
            <p>立即写入双内核，优先级高于普通分流。</p>
          </div>
        </div>
        <form class="inline-form" data-block-add-form>
          <input value="${escapeHtml(state.blocklist.newDomain)}" placeholder="malware.example.com" spellcheck="false" />
          <button type="submit">${icon("Plus", 17)}添加</button>
        </form>
        <div class="list-panel flush">${blockDomainList(state.blocklist.manual, true)}</div>
      </section>
      <section class="capture-card wide">
        <div class="sub-head">
          <div>
            <h3>社区库缓存</h3>
            <p>当前缓存 ${communityCount} 条；更新失败时不会清空旧缓存。</p>
          </div>
        </div>
        <div class="list-panel flush community-list">${blockDomainList(state.blocklist.communityDomains, false)}</div>
      </section>
    </div>
  `;
}

function capturePanel(): string {
  return `
    <div class="capture-grid">
      <div class="section-intro">
        <div>
          <span class="eyebrow">Packet Capture Routing</span>
          <h3>抓包分流只改目标流量</h3>
          <p>App 仍看到系统 TUN，MagicNet 在内核配置里把指定包名或域名送到电脑 HTTP 代理；mihomo 和 sing-box 配置同步应用。</p>
        </div>
        <button class="command-secondary" data-run="capture apply">${icon("ShieldCheck", 17)}重新应用</button>
      </div>
      <div class="capture-card">
        <div class="sub-head">
          <div>
            <h3>抓包代理出口</h3>
            <p>目标 App 或域名会在 TUN 内被分流到你的电脑 HTTP 抓包代理。</p>
          </div>
          <button class="toggle ${state.capture.enabled ? "on" : ""}" data-capture-toggle>
            ${state.capture.enabled ? "已启用" : "未启用"}
          </button>
        </div>
        <form class="capture-form" data-capture-form>
          <label>
            <span>代理名</span>
            <input name="name" value="${escapeHtml(state.capture.name)}" spellcheck="false" />
          </label>
          <label>
            <span>电脑 IP</span>
            <input name="host" value="${escapeHtml(state.capture.host)}" spellcheck="false" />
          </label>
          <label>
            <span>端口</span>
            <input name="port" value="${escapeHtml(state.capture.port)}" inputmode="numeric" />
          </label>
          <button type="submit">${icon("Save", 17)}保存并应用到双内核</button>
        </form>
      </div>
      <div class="capture-card">
        <div class="sub-head">
          <div>
            <h3>App 规则</h3>
            <p>按包名把目标 App 流量送到抓包代理。</p>
          </div>
        </div>
        <form class="inline-form" data-capture-add="app">
          <input value="${escapeHtml(state.capture.newApp)}" placeholder="com.example.targetapp" spellcheck="false" />
          <button type="submit">${icon("Plus", 17)}添加</button>
        </form>
        <div class="list-panel flush">${simpleList(state.capture.apps, "app")}</div>
      </div>
      <div class="capture-card">
        <div class="sub-head">
          <div>
            <h3>域名后缀规则</h3>
            <p>按域名后缀把接口流量送到抓包代理。</p>
          </div>
        </div>
        <form class="inline-form" data-capture-add="domain">
          <input value="${escapeHtml(state.capture.newDomain)}" placeholder="target-api.com" spellcheck="false" />
          <button type="submit">${icon("Plus", 17)}添加</button>
        </form>
        <div class="list-panel flush">${simpleList(state.capture.domains, "domain")}</div>
      </div>
    </div>
  `;
}

function subscriptionPanel(): string {
  const items = [
    {
      key: "sing-box",
      title: "sing-box",
      value: state.subscriptions.singBox,
      file: `${MODULE_DIR}/.config/sing-box/subscription.url`,
      note: "保存后可点更新订阅，把 Clash/通用分享链接转换进 sing-box TUN 配置。"
    },
    {
      key: "mihomo",
      title: "Clash / mihomo",
      value: state.subscriptions.mihomo,
      file: `${MODULE_DIR}/.config/mihomo/subscription.url`,
      note: "保存时同步写入 mihomo config.yaml 的第一个 proxy-provider URL。"
    }
  ];

  return items
    .map(
      (item) => `
        <div class="sub-card">
          <div class="sub-head">
            <div>
              <h3>${item.title}</h3>
              <p>${item.note}</p>
            </div>
            <button class="icon-button" data-copy-sub="${item.key}" title="复制订阅链接">${icon("Copy", 16)}</button>
          </div>
          <textarea data-sub-input="${item.key}" spellcheck="false" placeholder="https://example.com/sub">${escapeHtml(item.value)}</textarea>
          <div class="sub-actions">
            <button data-save-sub="${item.key}">${icon("Save", 17)}保存</button>
            <button data-copy-path="${item.key}">${icon("Copy", 17)}复制路径</button>
            <code>${item.file}</code>
          </div>
        </div>
      `
    )
    .join("");
}

function subscriptionsSection(): string {
  const configured = Number(Boolean(state.subscriptions.singBox)) + Number(Boolean(state.subscriptions.mihomo));
  return `
    <div class="section-intro">
      <div>
        <span class="eyebrow">Subscriptions</span>
        <h3>订阅链接管理</h3>
        <p>已配置 ${configured}/2。这里可以填写、保存、复制 Clash/mihomo 和 sing-box 订阅链接，保存后再更新订阅即可生效。</p>
      </div>
      <div class="section-actions">
        <button class="command-secondary" data-refresh-subs>${icon("RefreshCw", 17)}读取链接</button>
        <button class="command-primary" data-run="sub update-all">${icon("DownloadCloud", 17)}更新全部</button>
      </div>
    </div>
    <div class="sub-grid">
      ${subscriptionPanel()}
    </div>
  `;
}

function certPanel(): string {
  const certRows = state.certs.length
    ? state.certs
      .map(
        (name) => `
          <div class="cert-row">
            <code>${escapeHtml(name)}</code>
            <button class="icon-button" data-remove-cert="${escapeHtml(name)}" title="移除证书">${icon("X", 16)}</button>
          </div>
        `
      )
      .join("")
    : `<div class="picker-empty"><strong>模块内暂无证书</strong><span>安装后路径为 ${MODULE_DIR}/system/etc/security/cacerts，重启后覆盖系统 CA 目录。</span></div>`;

  return `
    <div class="cert-layout">
      <div class="cert-card">
        <div class="sub-head">
          <div>
            <h3>安装系统 CA 证书</h3>
            <p>写入模块 systemless 覆盖目录。支持 PEM / DER / 已命名 hash.0，生效需要重启。</p>
          </div>
          <button class="icon-button" data-refresh-certs title="刷新证书">${icon("RefreshCw", 16)}</button>
        </div>
        <div class="cert-form">
          <input data-cert-name value="${escapeHtml(state.certName)}" placeholder="magicnet-ca 或 9a5ba575.0" spellcheck="false" />
          <label class="file-picker">
            ${icon("FileText", 17)}选择证书文件
            <input data-cert-file type="file" accept=".cer,.crt,.pem,.der,.0,application/x-x509-ca-cert,text/plain" />
          </label>
          <textarea data-cert-text spellcheck="false" placeholder="也可以直接粘贴 PEM 证书内容">${escapeHtml(state.certText)}</textarea>
          <small class="cert-hint">${state.certBase64 ? "已读取证书文件，安装时会使用文件原始字节。" : "PEM 可直接粘贴；DER 建议用文件选择。"}</small>
          <button class="install-cert" data-install-cert>${icon("ShieldPlus", 17)}安装到系统证书目录</button>
        </div>
      </div>
      <div class="cert-card">
        <div class="sub-head">
          <div>
            <h3>已安装证书</h3>
            <p>目录：${MODULE_DIR}/system/etc/security/cacerts</p>
          </div>
          <button class="icon-button" data-copy-cert-dir title="复制目录">${icon("Copy", 16)}</button>
        </div>
        <div class="cert-list">${certRows}</div>
      </div>
    </div>
  `;
}

function appList(items: string[], target: "proxy" | "bypass"): string {
  if (items.length === 0) {
    return `<div class="empty">暂无应用包名</div>`;
  }

  return items
    .map(
      (pkg) => `
        <div class="app-row">
          <span>${escapeHtml(pkg)}</span>
          <button class="icon-button" data-remove-app="${escapeHtml(pkg)}" title="移除">
            ${icon("X", 16)}
          </button>
        </div>
      `
    )
    .join("");
}

function routeList(items: string[], target: "proxy" | "direct" | "block"): string {
  if (items.length === 0) {
    return `<div class="empty">暂无域名后缀</div>`;
  }

  return items
    .map(
      (domain) => `
        <div class="app-row">
          <span>${escapeHtml(domain)}</span>
          <button class="icon-button" data-remove-route="${target}" data-value="${escapeHtml(domain)}" title="移除">
            ${icon("X", 16)}
          </button>
        </div>
      `
    )
    .join("");
}

function routePanel(): string {
  return `
    <div class="section-intro">
      <div>
        <span class="eyebrow">Routing Rules</span>
        <h3>自定义域名分流</h3>
        <p>高优先级 DOMAIN-SUFFIX 规则，直接写入 sing-box 与 mihomo 的 TUN 路由。</p>
      </div>
      <button class="scan-button" data-refresh-routes>${icon("RefreshCw", 17)}读取规则</button>
    </div>
    <form class="package-form" data-route-form>
      <input name="domain" value="${escapeHtml(state.routes.newDomain)}" placeholder="example.com" spellcheck="false" />
      <select name="target">
        <option value="proxy" ${state.routes.newTarget === "proxy" ? "selected" : ""}>走代理</option>
        <option value="direct" ${state.routes.newTarget === "direct" ? "selected" : ""}>直连</option>
        <option value="block" ${state.routes.newTarget === "block" ? "selected" : ""}>阻断</option>
      </select>
      <button type="submit">${icon("Plus", 17)}添加并应用</button>
    </form>
    <div class="list-columns route-columns">
      <div class="list-panel">
        <div class="list-title"><span>${icon("Route", 17)}</span>Proxy domains</div>
        ${routeList(state.routes.proxy, "proxy")}
      </div>
      <div class="list-panel">
        <div class="list-title"><span>${icon("Wifi", 17)}</span>Direct domains</div>
        ${routeList(state.routes.direct, "direct")}
      </div>
      <div class="list-panel">
        <div class="list-title"><span>${icon("Ban", 17)}</span>Block domains</div>
        ${routeList(state.routes.block, "block")}
      </div>
    </div>
  `;
}

function packagePicker(): string {
  if (!state.hasKsu) {
    return `
      <div class="picker-empty">
        <strong>应用扫描需要 KernelSU WebView</strong>
        <span>本地预览只展示样式；真机打开后会调用 kernelsu.listPackages/getPackagesInfo。</span>
      </div>
    `;
  }

  if (state.packages.length === 0) {
    return `
      <div class="picker-empty">
        <strong>还没有扫描应用</strong>
        <span>点“扫描用户应用”读取已安装包名和应用名。</span>
      </div>
    `;
  }

  const query = state.packageQuery.trim().toLowerCase();
  const packages = state.packages
    .filter((item) => {
      if (!query) return true;
      return item.packageName.toLowerCase().includes(query) || item.appLabel.toLowerCase().includes(query);
    })
    .slice(0, 80);

  if (packages.length === 0) {
    return `<div class="picker-empty"><strong>没有匹配应用</strong><span>换一个应用名或包名关键字。</span></div>`;
  }

  return packages
    .map(
      (item) => `
        <div class="package-row">
          <img src="ksu://icon/${escapeHtml(item.packageName)}" alt="" loading="lazy" />
          <div>
            <strong>${escapeHtml(item.appLabel || item.packageName)}</strong>
            <span>${escapeHtml(item.packageName)}</span>
          </div>
          <button class="mini-button" data-pick-app="${escapeHtml(item.packageName)}" data-pick-target="proxy">Proxy</button>
          <button class="mini-button" data-pick-app="${escapeHtml(item.packageName)}" data-pick-target="bypass">Bypass</button>
        </div>
      `
    )
    .join("");
}

function runtimeDetail(value: string): string {
  if (hasProcess(value)) return `PID ${value}`;
  if (value === "stopped") return "未运行";
  return "等待刷新";
}

function runtimeLabel(value: string, onlineLabel = "运行中"): string {
  return hasProcess(value) ? onlineLabel : value === "stopped" ? "已停止" : "待刷新";
}

function healthPill(label: string, value: string, iconName: string): string {
  const online = hasProcess(value);
  return `
    <div class="health-pill ${online ? "ok" : "warn"}">
      <span>${icon(iconName, 17)}</span>
      <div>
        <small>${label}</small>
        <strong>${escapeHtml(runtimeLabel(value))}</strong>
        <em>${escapeHtml(runtimeDetail(value))}</em>
      </div>
    </div>
  `;
}

function commandDeck(): string {
  return `
    <div class="command-deck">
      <button class="command-primary" data-run="service restart">
        ${icon("RotateCcw", 20)}
        <span>重启内核</span>
      </button>
      <button class="command-secondary" data-open-core-ui-target="metacubex">
        ${icon("ExternalLink", 18)}
        <span>Meta Cube X</span>
      </button>
      <button class="command-secondary" data-open-core-ui-target="yacd">
        ${icon("Route", 18)}
        <span>Yacd</span>
      </button>
      <button class="command-secondary" data-open-core-ui-target="zashboard">
        ${icon("Server", 18)}
        <span>zashboard</span>
      </button>
      <button class="command-secondary" data-run="sub update-all">
        ${icon("DownloadCloud", 18)}
        <span>更新订阅</span>
      </button>
      <button class="command-secondary" data-action="refresh-all">
        ${icon("RefreshCw", 18)}
        <span>刷新面板</span>
      </button>
    </div>
  `;
}

function coreUiButton(className: string): string {
  return `
    <span class="core-ui-wrap">
      <a class="${className}" data-open-core-ui href="${escapeHtml(coreUiUrl())}" title="短按打开当前内核面板，长按选择面板">
        ${icon("ExternalLink", 18)}
        <span>Meta Cube X</span>
      </a>
      <button class="core-ui-menu-button" data-core-menu-toggle title="选择内核 WebUI">${icon("ListFilter", 16)}</button>
      ${state.coreMenuOpen ? `
        <div class="core-ui-menu">
          <button data-open-core-ui-target="metacubex">${icon("ExternalLink", 16)}Meta Cube X</button>
          <button data-open-core-ui-target="yacd">${icon("Route", 16)}Yacd</button>
          <button data-open-core-ui-target="zashboard">${icon("Server", 16)}zashboard</button>
        </div>
      ` : ""}
    </span>
  `;
}

function setupPanel(): string {
  const hasAnySub = Boolean(state.subscriptions.singBox || state.subscriptions.mihomo);
  return `
    <section class="setup-panel ${hasAnySub ? "compact" : ""}">
      <div class="setup-copy">
        <span class="eyebrow">${hasAnySub ? "Quick Setup" : "First Run"}</span>
        <h3>${hasAnySub ? "快速替换订阅" : "粘贴订阅，自动完成初始配置"}</h3>
        <p>${hasAnySub ? "同时写入 sing-box 和 mihomo，更新订阅后执行自修复。适合节点失效、换机场、重装模块后的快速恢复。" : "第一次用不需要理解配置文件路径。粘贴 Clash / sing-box 订阅链接后，MagicNet 会保存到双内核、更新节点并重载规则。"}</p>
      </div>
      <form class="setup-form" data-setup-form>
        <label>
          <span>订阅 URL</span>
          <input value="${escapeHtml(state.setupUrl)}" placeholder="https://example.com/sub" spellcheck="false" autocomplete="off" />
        </label>
        <button type="submit">${icon("Zap", 17)}保存并启用</button>
      </form>
    </section>
  `;
}

function statusDrawer(): string {
  const bridgeText = state.hasKsu ? "KernelSU 执行通道已接入" : "本地预览模式，不显示假运行数据";
  const headline = state.runtime.core === "stopped" || state.runtime.core === "unknown"
    ? "TUN 控制台"
    : `${state.runtime.core} 在线`;
  const statusCaption = state.runtime.core === "unknown"
    ? "等待刷新运行状态"
    : state.runtime.core === "stopped"
      ? "没有代理内核进程"
      : `${state.runtime.core} ${runtimeDetail(state.runtime.core === "sing-box" ? state.runtime.singBox : state.runtime.mihomo)}`;
  const health = healthSummary();
  const healthText = state.health.length
    ? `${health.ok} 正常 / ${health.warn} 警告 / ${health.fail} 失败`
    : "尚未运行健康诊断";
  const core = state.runtime.core === "unknown" ? "待刷新" : state.runtime.core;
  const task = state.activeTask ? `执行中：${state.activeTask}` : "空闲";

  return `
    <section class="status-drawer ${state.statusDrawerOpen ? "open" : ""}" data-status-drawer>
      <button class="status-drawer-handle" data-status-drawer-toggle aria-expanded="${state.statusDrawerOpen}">
        <span class="${`status-dot ${state.status}`}"></span>
        <div class="drawer-title">
          <small>MagicNet Status</small>
          <strong>${escapeHtml(state.statusText)}</strong>
        </div>
        <div class="drawer-chips">
          <span>${icon("Server", 15)}<b>${escapeHtml(core)}</b></span>
          <span>${icon(state.busy ? "Activity" : "Terminal", 15)}<b>${escapeHtml(task)}</b></span>
        </div>
        <span class="drawer-chevron">${icon(state.statusDrawerOpen ? "ChevronUp" : "ChevronDown", 18)}</span>
      </button>
      ${state.statusDrawerOpen ? `
        <div class="status-drawer-panel">
          <div class="drawer-grid">
            <div class="drawer-summary">
              <span class="eyebrow">Transparent TUN Control</span>
              <h2>${escapeHtml(headline)}</h2>
              <p>${bridgeText}。模块状态只在这里查看，功能操作在下方控制页面执行。</p>
            </div>
            <div class="signal-card">
              <span class="${`status-dot ${state.status}`}"></span>
              <div>
                <small>当前状态</small>
                <strong>${escapeHtml(state.statusText)}</strong>
                <em>${escapeHtml(statusCaption)}</em>
              </div>
            </div>
            <div class="signal-card compact-signal">
              <span>${icon("Stethoscope", 18)}</span>
              <div>
                <small>健康摘要</small>
                <strong>${escapeHtml(healthText)}</strong>
                <em>${state.health.length ? "诊断来自模块 CLI" : "点击健康诊断后生成"}</em>
              </div>
            </div>
          </div>
          <div class="health-grid drawer-health">
            ${healthPill("sing-box", state.runtime.singBox, "Server")}
            ${healthPill("mihomo", state.runtime.mihomo, "Route")}
            ${healthPill("watchdog", state.runtime.watchdog, "Bell")}
            ${healthPill("fswatch", state.runtime.fswatch, "Activity")}
          </div>
          <div class="drawer-meta">
            <span>Module <code>${MODULE_DIR}</code></span>
            <span>Control <code>${escapeHtml(state.runtime.api.replace(/^https?:\/\//, ""))}</code></span>
            <span>WebUI <code>${escapeHtml(coreUiUrl())}</code></span>
          </div>
        </div>
      ` : ""}
    </section>
  `;
}

function mobileDock(): string {
  const first = tabs.slice(0, 5);
  const second = tabs.slice(5);
  return `
    <nav class="mobile-dock" aria-label="MagicNet mobile shortcuts">
      <div class="mobile-dock-strip">
        ${first.map((item) => `
          <button class="${state.activeTab === item.key ? "active" : ""}" data-tab="${item.key}">
            ${icon(item.icon, 18)}
            <span>${item.label}</span>
          </button>
        `).join("")}
        <a data-open-core-ui href="${escapeHtml(coreUiUrl())}">
          ${icon("ExternalLink", 18)}
          <span>内核</span>
        </a>
        ${second.map((item) => `
          <button class="${state.activeTab === item.key ? "active" : ""}" data-tab="${item.key}">
            ${icon(item.icon, 18)}
            <span>${item.label}</span>
          </button>
        `).join("")}
        <button data-action="refresh-all">
          ${icon("RefreshCw", 18)}
          <span>刷新</span>
        </button>
      </div>
    </nav>
  `;
}

function tabsMarkup(): string {
  return tabs
    .map(
      (item) => `
        <button class="${state.activeTab === item.key ? "active" : ""}" data-tab="${item.key}">
          ${icon(item.icon, 18)}
          <span>${item.label}</span>
        </button>
      `
    )
    .join("");
}

function tabIndex(): number {
  return tabs.findIndex((item) => item.key === state.activeTab);
}

function setActiveTabByIndex(index: number): void {
  const next = tabs[Math.max(0, Math.min(tabs.length - 1, index))];
  if (!next || next.key === state.activeTab) return;
  state.activeTab = next.key;
  state.coreMenuOpen = false;
  render();
  void refreshActiveTabData();
}

async function refreshActiveTabData(): Promise<void> {
  if (!state.hasKsu) return;
  if (state.activeTab === "control" && state.nodes.length === 0) await refreshNodes();
  if (state.activeTab === "health" && state.health.length === 0) await refreshHealth();
  if (state.activeTab === "apps") await refreshApps();
  if (state.activeTab === "routes") await refreshRoutes();
  if (state.activeTab === "block") await refreshBlocklist();
  if (state.activeTab === "subs") await refreshSubscriptions();
  if (state.activeTab === "capture") await refreshCapture();
  if (state.activeTab === "certs") await refreshCerts();
}

function adjacentTabs(): string {
  const index = tabIndex();
  const prev = tabs[index - 1];
  const next = tabs[index + 1];
  return `
    <div class="swipe-hints">
      <span>${prev ? `${icon("Route", 13)} ${escapeHtml(prev.label)}` : ""}</span>
      <strong>${escapeHtml(tabs[index]?.label || "控制")}</strong>
      <span>${next ? `${escapeHtml(next.label)} ${icon("Route", 13)}` : ""}</span>
    </div>
  `;
}

function topSummary(): string {
  const core = state.runtime.core === "unknown" ? "待刷新" : state.runtime.core;
  const task = state.activeTask ? `执行中：${state.activeTask}` : "空闲";
  return `
    <div class="top-summary">
      <div class="summary-pill ${state.status}">
        <span class="${`status-dot ${state.status}`}"></span>
        <div>
          <small>状态</small>
          <strong>${escapeHtml(state.statusText)}</strong>
        </div>
      </div>
      <div class="summary-pill">
        <span>${icon("Server", 16)}</span>
        <div>
          <small>核心</small>
          <strong>${escapeHtml(core)}</strong>
        </div>
      </div>
      <div class="summary-pill task-pill ${state.busy ? "running" : ""}">
        <span>${icon(state.busy ? "Activity" : "Terminal", 16)}</span>
        <div>
          <small>任务</small>
          <strong>${escapeHtml(task)}</strong>
        </div>
      </div>
    </div>
  `;
}

async function scanUserPackages(): Promise<void> {
  if (!state.hasKsu) {
    state.output = "应用扫描需要从 KernelSU/APatch 管理器的 WebUI 打开。";
    render();
    return;
  }

  state.busy = true;
  state.output = "正在通过 kernelsu.listPackages('user') 扫描用户应用...";
  render();

  try {
    const packageNames = kernelsu.listPackages("user");
    const packageInfo = kernelsu.getPackagesInfo(packageNames);
    state.packages = packageInfo.sort((a, b) => (a.appLabel || a.packageName).localeCompare(b.appLabel || b.packageName));
    state.output = `已扫描 ${state.packages.length} 个用户应用。`;
  } catch (error) {
    state.output = `扫描失败：${error instanceof Error ? error.message : String(error)}`;
  } finally {
    state.busy = false;
    render();
  }
}

function render(): void {
  const app = document.querySelector<HTMLDivElement>("#app");
  if (!app) return;

  const tab = state.activeTab;

  app.innerHTML = `
    <div class="shell">
      <header class="topbar">
        <div class="top-main">
          <div class="brand">
            <div class="logo">${icon("Zap", 24)}</div>
            <div>
              <h1>MagicNet</h1>
              <p>TUN module control</p>
            </div>
          </div>
        </div>
        <div class="top-actions">
          <button class="ghost-link" data-action="refresh-all">${icon("RefreshCw", 16)}刷新</button>
          <a class="ghost-link" href="${REPO}" target="_blank" rel="noreferrer">${icon("Github", 16)}GitHub</a>
          ${coreUiButton("primary-link")}
        </div>
      </header>
      ${statusDrawer()}

      <main class="layout">
        <aside class="rail">
          <nav class="tabs">
            ${tabsMarkup()}
          </nav>
          <div class="meta">
            <span>Module</span>
            <code>${MODULE_DIR}</code>
            <span>Control</span>
            <code>${escapeHtml(state.runtime.api.replace(/^https?:\/\//, ""))}</code>
          </div>
        </aside>

        <section class="workspace">
          ${adjacentTabs()}
          ${activeTabPanel(tab)}

          <div class="always-output">
            <div class="output-head">
              <span>${icon("TerminalSquare", 17)}最近输出</span>
              <code>${escapeHtml(state.lastCommand || "等待执行")}</code>
            </div>
            <pre>${escapeHtml(compactOutput(state.output, 2400))}</pre>
          </div>
        </section>
      </main>
      ${mobileDock()}
    </div>
  `;

  bindEvents();
}

function bindEvents(): void {
  document.querySelectorAll<HTMLButtonElement>("[data-tab]").forEach((button) => {
    button.addEventListener("click", () => {
      state.activeTab = button.dataset.tab as State["activeTab"];
      render();
      void refreshActiveTabData();
    });
  });

  const workspace = document.querySelector<HTMLElement>(".workspace");
  if (workspace) {
    let startX = 0;
    let startY = 0;
    workspace.addEventListener("touchstart", (event) => {
      const touch = event.touches[0];
      startX = touch.clientX;
      startY = touch.clientY;
    }, { passive: true });
    workspace.addEventListener("touchend", (event) => {
      const touch = event.changedTouches[0];
      const dx = touch.clientX - startX;
      const dy = touch.clientY - startY;
      if (Math.abs(dx) < 64 || Math.abs(dx) < Math.abs(dy) * 1.4) return;
      const nextIndex = tabIndex() + (dx < 0 ? 1 : -1);
      setActiveTabByIndex(nextIndex);
    }, { passive: true });
  }

  const statusDrawer = document.querySelector<HTMLElement>("[data-status-drawer]");
  if (statusDrawer) {
    let startY = 0;
    statusDrawer.addEventListener("touchstart", (event) => {
      startY = event.touches[0].clientY;
    }, { passive: true });
    statusDrawer.addEventListener("touchend", (event) => {
      const dy = event.changedTouches[0].clientY - startY;
      if (dy > 36 && !state.statusDrawerOpen) {
        state.statusDrawerOpen = true;
        render();
      }
      if (dy < -36 && state.statusDrawerOpen) {
        state.statusDrawerOpen = false;
        render();
      }
    }, { passive: true });
  }

  document.querySelector<HTMLButtonElement>("[data-status-drawer-toggle]")?.addEventListener("click", () => {
    state.statusDrawerOpen = !state.statusDrawerOpen;
    render();
  });

  document.querySelectorAll<HTMLButtonElement>("[data-run]").forEach((button) => {
    button.addEventListener("click", () => runAction(button.dataset.run || ""));
  });

  document.querySelector<HTMLButtonElement>("[data-singbox-disable-toggle]")?.addEventListener("click", async () => {
    const command = state.runtime.singBoxDisabled ? "core sing-box enable" : "core sing-box disable";
    await runCli(command, { label: state.runtime.singBoxDisabled ? "启用 sing-box" : "禁用 sing-box" });
    await refreshStatus(true);
    render();
  });

  document.querySelector<HTMLFormElement>("[data-restart-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const select = form.querySelector<HTMLSelectElement>("select[name='target']");
    const target = select?.value || "current";
    if (target === "sing-box" && state.runtime.singBoxDisabled) {
      state.output = "sing-box 已被 .disable_sing_box 禁用，不能重启到 sing-box。";
      render();
      return;
    }
    await runAction(`service restart ${target}`);
  });

  document.querySelectorAll<HTMLButtonElement>("[data-mode]").forEach((button) => {
    button.addEventListener("click", () => runAction(`mode ${button.dataset.mode}`));
  });

  document.querySelectorAll<HTMLButtonElement>("[data-app-mode]").forEach((button) => {
    button.addEventListener("click", async () => {
      const mode = button.dataset.appMode === "whitelist" ? "whitelist" : "blacklist";
      state.appPolicy.mode = mode;
      await runCli(`app mode ${mode}`, { refreshApps: true });
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-action='refresh-all']").forEach((button) => {
    button.addEventListener("click", async () => {
      await refreshDashboard();
    });
  });

  document.querySelectorAll<HTMLElement>("[data-open-core-ui]").forEach((element) => {
    let pressTimer = 0;
    element.addEventListener("pointerdown", () => {
      pressTimer = window.setTimeout(() => {
        state.coreMenuOpen = true;
        render();
      }, 420);
    });
    element.addEventListener("pointerup", () => {
      window.clearTimeout(pressTimer);
    });
    element.addEventListener("pointerleave", () => {
      window.clearTimeout(pressTimer);
    });
    element.addEventListener("click", (event) => {
      event.preventDefault();
      if (state.coreMenuOpen) return;
      void openCoreUi();
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-core-menu-toggle]").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.preventDefault();
      state.coreMenuOpen = !state.coreMenuOpen;
      render();
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-open-core-ui-target]").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.preventDefault();
      const target = button.dataset.openCoreUiTarget;
      state.coreMenuOpen = false;
      if (target === "metacubex" || target === "yacd" || target === "zashboard") {
        void openCoreUiTarget(target);
      }
    });
  });

  document.querySelector<HTMLButtonElement>("[data-copy-last]")?.addEventListener("click", async () => {
    if (!state.lastCommand) return;
    await navigator.clipboard?.writeText(state.lastCommand);
    if (state.hasKsu) kernelsu.toast?.("命令已复制");
  });

  document.querySelector<HTMLButtonElement>("[data-scan-packages]")?.addEventListener("click", scanUserPackages);

  document.querySelector<HTMLButtonElement>("[data-refresh-subs]")?.addEventListener("click", () => refreshSubscriptions());

  document.querySelector<HTMLButtonElement>("[data-refresh-routes]")?.addEventListener("click", () => refreshRoutes());

  document.querySelector<HTMLButtonElement>("[data-refresh-block]")?.addEventListener("click", () => refreshBlocklist());

  document.querySelector<HTMLButtonElement>("[data-refresh-nodes]")?.addEventListener("click", () => refreshNodes());

  document.querySelectorAll<HTMLButtonElement>("[data-node-use]").forEach((button) => {
    button.addEventListener("click", () => switchNode(button.dataset.nodeUse || ""));
  });

  document.querySelector<HTMLFormElement>("[data-setup-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const input = event.currentTarget.querySelector<HTMLInputElement>("input");
    state.setupUrl = input?.value || "";
    await saveSetupSubscription();
  });

  document.querySelectorAll<HTMLButtonElement>("[data-health-run]").forEach((button) => {
    button.addEventListener("click", () => refreshHealth());
  });

  document.querySelectorAll<HTMLButtonElement>("[data-support-bundle]").forEach((button) => {
    button.addEventListener("click", () => generateSupportBundle());
  });

  document.querySelectorAll<HTMLButtonElement>("[data-save-sub]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = button.dataset.saveSub === "mihomo" ? "mihomo" : "sing-box";
      const input = document.querySelector<HTMLTextAreaElement>(`[data-sub-input="${target}"]`);
      const value = input?.value.trim() || "";
      if (!/^https?:\/\/\S+$/i.test(value)) {
        state.output = "订阅链接格式不对，必须是 http(s) URL。";
        render();
        return;
      }
      await runCli(`sub set ${target} ${shellQuote(value)}`, { quiet: false });
      await refreshSubscriptions(true);
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-copy-sub]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = button.dataset.copySub === "mihomo" ? "mihomo" : "sing-box";
      const value = target === "mihomo" ? state.subscriptions.mihomo : state.subscriptions.singBox;
      await navigator.clipboard?.writeText(value);
      state.output = value ? `已复制 ${target} 订阅链接。` : `${target} 订阅链接为空。`;
      if (state.hasKsu) kernelsu.toast?.("订阅链接已复制");
      render();
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-copy-path]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = button.dataset.copyPath === "mihomo" ? "mihomo" : "sing-box";
      const path = target === "mihomo"
        ? `${MODULE_DIR}/.config/mihomo/subscription.url`
        : `${MODULE_DIR}/.config/sing-box/subscription.url`;
      await navigator.clipboard?.writeText(path);
      state.output = `已复制路径：\n${path}`;
      if (state.hasKsu) kernelsu.toast?.("路径已复制");
      render();
    });
  });

  document.querySelector<HTMLFormElement>("[data-route-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const target = String(form.get("target") || "proxy") as RouteRules["newTarget"];
    const domain = String(form.get("domain") || "").trim();
    state.routes.newDomain = domain;
    state.routes.newTarget = ["proxy", "direct", "block"].includes(target) ? target : "proxy";
    if (!/^[A-Za-z0-9*_.-]+\.[A-Za-z0-9*_.-]+$/.test(domain)) {
      state.output = "域名后缀格式不对。";
      render();
      return;
    }
    await runCli(`route add-domain ${state.routes.newTarget} ${shellQuote(domain)}`);
    state.routes.newDomain = "";
    await refreshRoutes(true);
  });

  document.querySelectorAll<HTMLButtonElement>("[data-remove-route]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = button.dataset.removeRoute || "proxy";
      const value = button.dataset.value || "";
      if (!["proxy", "direct", "block"].includes(target) || !value) return;
      await runCli(`route remove-domain ${target} ${shellQuote(value)}`);
      await refreshRoutes(true);
    });
  });

  document.querySelector<HTMLButtonElement>("[data-block-toggle]")?.addEventListener("click", async () => {
    await runCli(state.blocklist.enabled ? "block disable" : "block enable");
    await refreshBlocklist(true);
  });

  document.querySelector<HTMLButtonElement>("[data-community-toggle]")?.addEventListener("click", async () => {
    await runCli(state.blocklist.community ? "block community off" : "block community on");
    await refreshBlocklist(true);
  });

  document.querySelector<HTMLFormElement>("[data-block-url-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const input = event.currentTarget.querySelector<HTMLInputElement>("input");
    const url = input?.value.trim() || "";
    if (!/^https?:\/\/\S+$/i.test(url)) {
      state.output = "社区库 URL 格式不对，必须是 http(s) URL。";
      render();
      return;
    }
    await runCli(`block url ${shellQuote(url)}`);
    await refreshBlocklist(true);
  });

  document.querySelector<HTMLFormElement>("[data-block-add-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const input = event.currentTarget.querySelector<HTMLInputElement>("input");
    const domain = input?.value.trim() || "";
    state.blocklist.newDomain = domain;
    if (!/^[A-Za-z0-9*_.-]+\.[A-Za-z0-9*_.-]+$/.test(domain)) {
      state.output = "域名后缀格式不对。示例：malware.example.com";
      render();
      return;
    }
    await runCli(`block add-domain ${shellQuote(domain)}`);
    state.blocklist.newDomain = "";
    await refreshBlocklist(true);
  });

  document.querySelectorAll<HTMLButtonElement>("[data-remove-block]").forEach((button) => {
    button.addEventListener("click", async () => {
      const domain = button.dataset.removeBlock || "";
      if (!domain) return;
      await runCli(`block remove-domain ${shellQuote(domain)}`);
      await refreshBlocklist(true);
    });
  });

  document.querySelector<HTMLButtonElement>("[data-capture-toggle]")?.addEventListener("click", async () => {
    await runCli(state.capture.enabled ? "capture disable" : "capture enable");
    await refreshCapture(true);
  });

  document.querySelector<HTMLFormElement>("[data-capture-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const name = String(form.get("name") || "MagicNet-Capture").trim();
    const host = String(form.get("host") || "").trim();
    const port = String(form.get("port") || "").trim();
    if (!host || !/^[0-9]+$/.test(port)) {
      state.output = "抓包代理主机或端口格式不对。";
      render();
      return;
    }
    await runCli(`capture set ${shellQuote(host)} ${shellQuote(port)} ${shellQuote(name)}`);
    await refreshCapture(true);
  });

  document.querySelectorAll<HTMLFormElement>("[data-capture-add]").forEach((form) => {
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const kind = form.dataset.captureAdd === "domain" ? "domain" : "app";
      const input = form.querySelector("input");
      const value = input?.value.trim() || "";
      if (!value) return;
      if (kind === "app" && !/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(value)) {
        state.output = "App 包名格式不对。";
        render();
        return;
      }
      if (kind === "domain" && !/^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(value)) {
        state.output = "域名后缀格式不对。";
        render();
        return;
      }
      await runCli(kind === "domain" ? `capture add-domain ${shellQuote(value)}` : `capture add-app ${shellQuote(value)}`);
      await refreshCapture(true);
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-remove-capture]").forEach((button) => {
    button.addEventListener("click", async () => {
      const kind = button.dataset.removeCapture === "domain" ? "domain" : "app";
      const value = button.dataset.value || "";
      await runCli(kind === "domain" ? `capture remove-domain ${shellQuote(value)}` : `capture remove-app ${shellQuote(value)}`);
      await refreshCapture(true);
    });
  });

  document.querySelector<HTMLInputElement>("[data-cert-name]")?.addEventListener("input", (event) => {
    state.certName = event.currentTarget.value;
  });

  document.querySelector<HTMLTextAreaElement>("[data-cert-text]")?.addEventListener("input", (event) => {
    state.certText = event.currentTarget.value;
    state.certBase64 = "";
  });

  document.querySelector<HTMLInputElement>("[data-cert-file]")?.addEventListener("change", async (event) => {
    const file = event.currentTarget.files?.[0];
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    state.certName = file.name;
    state.certBase64 = bytesToBase64(bytes);
    state.certText = file.type.startsWith("text/") || /\.(pem|crt|cer|0)$/i.test(file.name)
      ? await file.text()
      : `[binary certificate: ${file.name}, ${bytes.byteLength} bytes]`;
    render();
  });

  document.querySelector<HTMLButtonElement>("[data-install-cert]")?.addEventListener("click", async () => {
    const name = state.certName.trim() || "magicnet-ca";
    const text = state.certText.trim();
    if (!text) {
      state.output = "先选择证书文件，或粘贴 PEM/DER 内容。";
      render();
      return;
    }
    const encoded = state.certBase64 || utf8ToBase64(text);
    await runCli(`cert install ${shellQuote(name)} ${shellQuote(encoded)}`);
    state.certText = "";
    state.certBase64 = "";
    await refreshCerts(true);
  });

  document.querySelector<HTMLButtonElement>("[data-refresh-certs]")?.addEventListener("click", () => refreshCerts());

  document.querySelector<HTMLButtonElement>("[data-copy-cert-dir]")?.addEventListener("click", async () => {
    const path = `${MODULE_DIR}/system/etc/security/cacerts`;
    await navigator.clipboard?.writeText(path);
    state.output = `已复制证书目录：\n${path}`;
    if (state.hasKsu) kernelsu.toast?.("证书目录已复制");
    render();
  });

  document.querySelectorAll<HTMLButtonElement>("[data-remove-cert]").forEach((button) => {
    button.addEventListener("click", async () => {
      const name = button.dataset.removeCert || "";
      await runCli(`cert remove ${shellQuote(name)}`);
      await refreshCerts(true);
    });
  });

  document.querySelector<HTMLInputElement>("[data-package-query]")?.addEventListener("input", (event) => {
    state.packageQuery = event.currentTarget.value;
    render();
  });

  document.querySelectorAll<HTMLButtonElement>("[data-pick-app]").forEach((button) => {
    button.addEventListener("click", async () => {
      const pkg = button.dataset.pickApp || "";
      const target = button.dataset.pickTarget === "bypass" ? "bypass" : "proxy";
      await runCli(`app add ${shellQuote(pkg)} ${target}`, { refreshApps: true });
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-remove-app]").forEach((button) => {
    button.addEventListener("click", async () => {
      const pkg = button.dataset.removeApp || "";
      await runCli(`app remove ${shellQuote(pkg)}`, { refreshApps: true });
    });
  });

  document.querySelector<HTMLFormElement>("[data-package-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const pkg = String(form.get("package") || "").trim();
    const target = String(form.get("target") || "proxy") === "bypass" ? "bypass" : "proxy";
    state.newPackage = pkg;
    state.newTarget = target;

    if (!/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(pkg)) {
      state.output = "包名格式不对。示例：com.android.chrome";
      render();
      return;
    }

    await runCli(`app add ${shellQuote(pkg)} ${target}`, { refreshApps: true });
    state.newPackage = "";
    render();
  });
}

if (state.hasKsu) {
  try {
    kernelsu.enableEdgeToEdge?.(true);
    kernelsu.fullScreen?.(true);
  } catch {
    state.hasKsu = false;
  }
}
async function bootstrap(): Promise<void> {
  render();
  await refreshStatus(true);
  if (!state.hasKsu) return;
  render();
}

void bootstrap();
