import {
  Activity,
  Ban,
  Bell,
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
const CORE_UI = "http://127.0.0.1:9090/ui/zashboard/#/setup?hostname=127.0.0.1&port=9090";
const REPO = "https://github.com/LIghtJUNction/MagicNet";
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

type TrafficStats = {
  connections: number;
  upload: number;
  download: number;
  memory: number;
};

type PackageInfo = {
  packageName: string;
  versionName: string;
  versionCode: number;
  appLabel: string;
  isSystem: boolean;
  uid: number;
};

type State = {
  hasKsu: boolean;
  busy: boolean;
  status: "checking" | "online" | "offline" | "local";
  statusText: string;
  runtime: RuntimeState;
  lastCommand: string;
  output: string;
  nodes: string[];
  currentNode: string;
  traffic: TrafficStats;
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
  health: HealthItem[];
  packages: PackageInfo[];
  packageQuery: string;
  newPackage: string;
  newTarget: "proxy" | "bypass";
  activeTab: "control" | "health" | "apps" | "subs" | "capture" | "certs" | "logs";
};

const state: State = {
  hasKsu: hasKsuBridge,
  busy: false,
  status: "checking",
  statusText: "检测执行通道",
  runtime: {
    core: "unknown",
    singBox: "unknown",
    mihomo: "unknown",
    watchdog: "unknown",
    fswatch: "unknown",
    api: "http://127.0.0.1:9090",
    webui: CORE_UI,
    subPath: `${MODULE_DIR}/.config/sing-box/subscription.url`
  },
  lastCommand: "",
  output: "面板已加载。通过 KernelSU WebUI 打开时，按钮会直接执行模块 CLI。",
  nodes: [],
  currentNode: "",
  traffic: {
    connections: 0,
    upload: 0,
    download: 0,
    memory: 0
  },
  appPolicy: {
    mode: "blacklist",
    proxy: ["com.android.chrome", "org.telegram.messenger"],
    bypass: ["com.miui.weather2", "com.android.providers.downloads"]
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
  health: [],
  packages: [],
  packageQuery: "",
  newPackage: "",
  newTarget: "proxy",
  activeTab: "control"
};

const actions = [
  { label: "刷新状态", hint: "读取进程与 API", icon: "RefreshCw", command: "service status" },
  { label: "重启 TUN", hint: "重新拉起内核", icon: "RotateCcw", command: "service restart", tone: "strong" },
  { label: "一键自修复", hint: "重载规则并自检", icon: "Zap", command: "repair", tone: "strong" },
  { label: "健康诊断", hint: "检查关键链路", icon: "Stethoscope", command: "health" },
  { label: "更新订阅", hint: "更新全部订阅", icon: "DownloadCloud", command: "sub update-all" },
  { label: "清空连接", hint: "关闭旧连接", icon: "Unplug", command: "api close-all" },
  { label: "重载热点", hint: "应用转发规则", icon: "Wifi", command: "hotspot reload" },
  { label: "VPN 共存", hint: "重载共存规则", icon: "ShieldCheck", command: "vpn reload" }
];

const quickModes = [
  { label: "规则", value: "rule" },
  { label: "全局", value: "global" },
  { label: "直连", value: "direct" }
];

const iconMap: Record<string, IconNode> = {
  Activity,
  Ban,
  Bell,
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

function normalizeExecResult(result: ExecResult): string {
  const stdout = result.stdout || result.out || "";
  const stderr = result.stderr || result.err || "";
  return [stdout, stderr].filter(Boolean).join("\n").trim();
}

async function runCli(args: string, options: { refreshApps?: boolean; quiet?: boolean } = {}): Promise<string> {
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

  state.busy = true;
  if (!options.quiet) {
    state.output = `$ ${command}\n执行中...`;
  }
  render();

  try {
    const result = await kernelsu.exec(command);
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
    state.busy = false;
    render();
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

async function refreshStatus(): Promise<void> {
  if (!state.hasKsu) {
    state.status = "local";
    state.statusText = "本地预览";
    render();
    return;
  }

  state.status = "checking";
  state.statusText = "读取内核状态";
  render();

  const text = await runCli("service status", { quiet: true });
  state.runtime = parseRuntimeStatus(text);
  const bothStopped = state.runtime.core === "stopped";
  state.status = bothStopped ? "offline" : "online";
  state.statusText = bothStopped ? "TUN 未运行" : `${state.runtime.core} 在线`;
  state.output = `$ su -c ${CLI} service status\n${text}`;
  render();
}

async function refreshApps(quiet = false): Promise<void> {
  const text = await runCli("app list", { quiet });
  if (state.hasKsu && text) {
    state.appPolicy = parseAppPolicy(text);
  }
  render();
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
  render();
}

async function refreshNodes(quiet = false): Promise<void> {
  const current = await runCli("node current", { quiet: true });
  const list = await runCli("node list", { quiet: true });
  if (state.hasKsu) {
    state.currentNode = current.trim();
    state.nodes = list
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    if (!quiet) {
      state.output = `当前节点：${state.currentNode || "unknown"}\n可用节点：${state.nodes.length}`;
    }
  }
  render();
}

async function switchNode(name: string): Promise<void> {
  if (!name) return;
  await runCli(`node use ${shellQuote(name)}`);
  await refreshNodes(true);
}

function parseTrafficStats(text: string): TrafficStats {
  const next = { ...state.traffic };
  for (const raw of text.split(/\r?\n/)) {
    const [key, value] = raw.trim().split("=");
    const number = Number.parseInt(value || "0", 10);
    if (!Number.isFinite(number)) continue;
    if (key === "connections") next.connections = number;
    if (key === "upload") next.upload = number;
    if (key === "download") next.download = number;
    if (key === "memory") next.memory = number;
  }
  return next;
}

async function refreshTraffic(quiet = false): Promise<void> {
  const text = await runCli("api stats", { quiet: true });
  if (state.hasKsu && text) {
    state.traffic = parseTrafficStats(text);
    if (!quiet) {
      state.output = `连接统计已刷新：${state.traffic.connections} 条连接。`;
    }
  }
  render();
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
  render();
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
  render();
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
  }
  render();
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
  hotspot: { label: "热点转发", icon: "Wifi", fix: "hotspot reload", fixLabel: "重载" },
  vpn: { label: "VPN 共存", icon: "ShieldCheck", fix: "vpn reload", fixLabel: "重载" },
  certs: { label: "系统 CA", icon: "ShieldPlus" },
  "direct-test": { label: "直连探测", icon: "Route" },
  "proxy-test": { label: "代理探测", icon: "ExternalLink", fix: "sub update-all", fixLabel: "更新订阅" }
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
          <button class="command-primary" data-run="repair" ${state.busy ? "disabled" : ""}>${icon("Zap", 18)}一键自修复</button>
          <button class="command-secondary" data-health-run ${state.busy ? "disabled" : ""}>${icon("Stethoscope", 18)}运行诊断</button>
          <button class="command-secondary" data-support-bundle ${state.busy ? "disabled" : ""}>${icon("Copy", 18)}复制支持包</button>
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
  const nodeRows = state.nodes.length
    ? state.nodes
      .map((name) => {
        const selected = name === state.currentNode;
        return `
          <button class="node-row ${selected ? "selected" : ""}" data-node-use="${escapeHtml(name)}" ${state.busy || selected ? "disabled" : ""}>
            <span>${selected ? icon("ShieldCheck", 17) : icon("Route", 17)}</span>
            <strong>${escapeHtml(name)}</strong>
            <small>${selected ? "当前出口" : "切换"}</small>
          </button>
        `;
      })
      .join("")
    : `<div class="picker-empty"><strong>还没有节点列表</strong><span>先更新订阅，再点刷新节点。列表来自 Clash API 的 proxy 策略组。</span></div>`;

  return `
    <div class="node-panel">
      <div class="node-head">
        <div>
          <span class="eyebrow">Proxy Selector</span>
          <h3>${escapeHtml(state.currentNode || "未读取当前节点")}</h3>
          <p>直接切换 TUN 出口，不需要打开内核 WebUI。</p>
        </div>
        <div class="node-actions">
          <button class="command-secondary" data-refresh-nodes ${state.busy ? "disabled" : ""}>${icon("RefreshCw", 17)}刷新节点</button>
          <button class="command-secondary" data-run="sub update-all" ${state.busy ? "disabled" : ""}>${icon("DownloadCloud", 17)}更新订阅</button>
        </div>
      </div>
      <div class="node-list">${nodeRows}</div>
    </div>
  `;
}

function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let next = value;
  let index = 0;
  while (next >= 1024 && index < units.length - 1) {
    next /= 1024;
    index += 1;
  }
  return `${next >= 10 || index === 0 ? next.toFixed(0) : next.toFixed(1)} ${units[index]}`;
}

function trafficPanel(): string {
  const items = [
    { label: "连接", value: String(state.traffic.connections), iconName: "Activity" },
    { label: "上行", value: formatBytes(state.traffic.upload), iconName: "Route" },
    { label: "下行", value: formatBytes(state.traffic.download), iconName: "DownloadCloud" },
    { label: "内存", value: formatBytes(state.traffic.memory), iconName: "Gauge" }
  ];

  return `
    <div class="traffic-panel">
      <div class="traffic-head">
        <div>
          <span class="eyebrow">Live Connections</span>
          <h3>连接与流量</h3>
          <p>从 Clash API 读取当前连接、上下行和内存占用。</p>
        </div>
        <div class="traffic-actions">
          <button class="command-secondary" data-refresh-traffic ${state.busy ? "disabled" : ""}>${icon("RefreshCw", 17)}刷新</button>
          <button class="command-secondary" data-run="api close-all" ${state.busy ? "disabled" : ""}>${icon("Unplug", 17)}清空连接</button>
        </div>
      </div>
      <div class="traffic-grid">
        ${items
          .map(
            (item) => `
              <div class="traffic-card">
                <span>${icon(item.iconName, 17)}</span>
                <small>${item.label}</small>
                <strong>${escapeHtml(item.value)}</strong>
              </div>
            `
          )
          .join("")}
      </div>
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

function capturePanel(): string {
  return `
    <div class="capture-grid">
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

function healthPill(label: string, value: string, iconName: string): string {
  const online = value !== "stopped" && value !== "unknown" && value !== "";
  return `
    <div class="health-pill ${online ? "ok" : "warn"}">
      <span>${icon(iconName, 17)}</span>
      <div>
        <small>${label}</small>
        <strong>${escapeHtml(value || "unknown")}</strong>
      </div>
    </div>
  `;
}

function commandDeck(): string {
  return `
    <div class="command-deck">
      <button class="command-primary" data-run="service restart" ${state.busy ? "disabled" : ""}>
        ${icon("RotateCcw", 20)}
        <span>重启 TUN 内核</span>
      </button>
      <button class="command-secondary" data-run="sub update-all" ${state.busy ? "disabled" : ""}>
        ${icon("DownloadCloud", 18)}
        <span>更新订阅</span>
      </button>
      <button class="command-secondary" data-action="refresh-all" ${state.busy ? "disabled" : ""}>
        ${icon("RefreshCw", 18)}
        <span>刷新状态</span>
      </button>
      <a class="command-secondary" href="${state.runtime.webui || CORE_UI}" target="_blank" rel="noreferrer">
        ${icon("ExternalLink", 18)}
        <span>内核 WebUI</span>
      </a>
    </div>
  `;
}

function setupPanel(): string {
  const hasAnySub = Boolean(state.subscriptions.singBox || state.subscriptions.mihomo);
  return `
    <section class="setup-panel ${hasAnySub ? "compact" : ""}">
      <div class="setup-copy">
        <span class="eyebrow">${hasAnySub ? "Quick Setup" : "First Run"}</span>
        <h3>${hasAnySub ? "快速替换订阅" : "粘贴订阅，自动完成初始配置"}</h3>
        <p>${hasAnySub ? "同时写入 sing-box 和 mihomo，更新订阅后执行自修复。适合节点失效、换机场、重装模块后的快速恢复。" : "第一次用不需要理解配置文件路径。粘贴 Clash / sing-box 订阅链接后，MagicNet 会保存到双内核、更新节点、重载规则并跑健康检查。"}</p>
      </div>
      <form class="setup-form" data-setup-form>
        <label>
          <span>订阅 URL</span>
          <input value="${escapeHtml(state.setupUrl)}" placeholder="https://example.com/sub" spellcheck="false" autocomplete="off" />
        </label>
        <button type="submit" ${state.busy ? "disabled" : ""}>${icon("Zap", 17)}保存并启用</button>
      </form>
    </section>
  `;
}

function overviewPanel(): string {
  const bridgeText = state.hasKsu ? "可直接执行模块命令" : "本地预览，只展示界面";
  const headline = state.runtime.core === "stopped"
    ? "TUN 已停止，点一下就能拉起。"
    : `${state.runtime.core === "unknown" ? "MagicNet" : state.runtime.core} 正在接管系统流量。`;

  return `
    <section class="overview">
      <div class="overview-main">
        <span class="eyebrow">Transparent TUN Control</span>
        <h2>${headline}</h2>
        <p>${bridgeText}。默认只走 TUN，不做 TUN 之外 fallback；核心 WebUI、订阅、抓包、证书和分应用策略集中在这个面板。</p>
        ${commandDeck()}
      </div>
      <div class="overview-side">
        <div class="signal-card">
          <span class="${`status-dot ${state.status}`}"></span>
          <div>
            <small>当前状态</small>
            <strong>${escapeHtml(state.statusText)}</strong>
          </div>
        </div>
        <div class="health-grid">
          ${healthPill("sing-box", state.runtime.singBox, "Server")}
          ${healthPill("mihomo", state.runtime.mihomo, "Route")}
          ${healthPill("watchdog", state.runtime.watchdog, "Bell")}
          ${healthPill("fswatch", state.runtime.fswatch, "Activity")}
        </div>
      </div>
    </section>
    ${setupPanel()}
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
        <div class="brand">
          <div class="logo">${icon("Zap", 24)}</div>
          <div>
            <h1>MagicNet</h1>
            <p>Android transparent TUN console</p>
          </div>
        </div>
        <div class="top-actions">
          <a class="ghost-link" href="${REPO}" target="_blank" rel="noreferrer">${icon("Github", 16)}GitHub</a>
          <a class="primary-link" href="${state.runtime.webui || CORE_UI}" target="_blank" rel="noreferrer">${icon("ExternalLink", 16)}内核 WebUI</a>
        </div>
      </header>

      <main class="layout">
        <aside class="rail">
          <div class="status-card">
            <span class="${`status-dot ${state.status}`}"></span>
            <div>
              <strong>${state.statusText}</strong>
              <small>${state.hasKsu ? "KernelSU exec 已接入" : "等待 KernelSU WebView"}</small>
            </div>
          </div>
          <nav class="tabs">
            <button class="${tab === "control" ? "active" : ""}" data-tab="control">${icon("Gauge", 18)}控制</button>
            <button class="${tab === "health" ? "active" : ""}" data-tab="health">${icon("Stethoscope", 18)}诊断</button>
            <button class="${tab === "apps" ? "active" : ""}" data-tab="apps">${icon("ListFilter", 18)}应用名单</button>
            <button class="${tab === "subs" ? "active" : ""}" data-tab="subs">${icon("DownloadCloud", 18)}订阅</button>
            <button class="${tab === "capture" ? "active" : ""}" data-tab="capture">${icon("ShieldCheck", 18)}抓包</button>
            <button class="${tab === "certs" ? "active" : ""}" data-tab="certs">${icon("ShieldPlus", 18)}证书</button>
            <button class="${tab === "logs" ? "active" : ""}" data-tab="logs">${icon("Terminal", 18)}输出</button>
          </nav>
          <div class="meta">
            <span>Module</span>
            <code>${MODULE_DIR}</code>
            <span>Control</span>
            <code>${escapeHtml(state.runtime.api.replace(/^https?:\/\//, ""))}</code>
          </div>
        </aside>

        <section class="workspace">
          ${overviewPanel()}

          <div class="tab-panel ${tab === "control" ? "show" : ""}">
            <div class="action-grid">
              ${actions
                .map(
                  (item) => `
                    <button class="action-card ${item.tone || ""}" data-run="${item.command}" ${state.busy ? "disabled" : ""}>
                      <span>${icon(item.icon, 20)}</span>
                      <strong>${item.label}</strong>
                      <small>${item.hint}</small>
                    </button>
                  `
                )
                .join("")}
            </div>
            ${nodePanel()}
            ${trafficPanel()}
            <div class="mode-panel">
              <div>
                <h3>代理模式</h3>
                <p>仅切换内核策略，网络入口保持 TUN。</p>
              </div>
              <div class="segmented">
                ${quickModes
                  .map((item) => `<button data-mode="${item.value}" ${state.busy ? "disabled" : ""}>${item.label}</button>`)
                  .join("")}
              </div>
            </div>
          </div>

          <div class="tab-panel ${tab === "health" ? "show" : ""}">
            ${healthPanel()}
          </div>

          <div class="tab-panel ${tab === "apps" ? "show" : ""}">
            <div class="policy-header">
              <div>
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
                <button class="scan-button" data-scan-packages ${state.busy ? "disabled" : ""}>${icon("RefreshCw", 17)}扫描用户应用</button>
              </div>
              <input class="package-search" data-package-query value="${escapeHtml(state.packageQuery)}" placeholder="搜索应用名或包名" />
              <div class="package-results">
                ${packagePicker()}
              </div>
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

          <div class="tab-panel ${tab === "subs" ? "show" : ""}">
            <div class="sub-toolbar">
              <button data-refresh-subs>${icon("RefreshCw", 17)}读取链接</button>
              <button data-run="sub update-all">${icon("DownloadCloud", 17)}更新 sing-box 订阅</button>
            </div>
            <div class="sub-grid">
              ${subscriptionPanel()}
            </div>
          </div>

          <div class="tab-panel ${tab === "capture" ? "show" : ""}">
            ${capturePanel()}
          </div>

          <div class="tab-panel ${tab === "certs" ? "show" : ""}">
            ${certPanel()}
          </div>

          <div class="tab-panel ${tab === "logs" ? "show" : ""}">
            <div class="log-toolbar">
              <button data-run="service logs sing-box 160">${icon("FileText", 17)}sing-box 日志</button>
              <button data-health-run>${icon("Stethoscope", 17)}健康诊断</button>
              <button data-support-bundle>${icon("Copy", 17)}支持包</button>
              <button data-copy-last>${icon("Copy", 17)}复制命令</button>
            </div>
            <pre class="terminal">${escapeHtml(state.output)}</pre>
          </div>

          <div class="always-output">
            <div class="output-head">
              <span>${icon("TerminalSquare", 17)}最近输出</span>
              <code>${escapeHtml(state.lastCommand || "等待执行")}</code>
            </div>
            <pre>${escapeHtml(state.output)}</pre>
          </div>
        </section>
      </main>
    </div>
  `;

  bindEvents();
}

function bindEvents(): void {
  document.querySelectorAll<HTMLButtonElement>("[data-tab]").forEach((button) => {
    button.addEventListener("click", () => {
      state.activeTab = button.dataset.tab as State["activeTab"];
      render();
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-run]").forEach((button) => {
    button.addEventListener("click", () => runCli(button.dataset.run || ""));
  });

  document.querySelectorAll<HTMLButtonElement>("[data-mode]").forEach((button) => {
    button.addEventListener("click", () => runCli(`mode ${button.dataset.mode}`));
  });

  document.querySelectorAll<HTMLButtonElement>("[data-app-mode]").forEach((button) => {
    button.addEventListener("click", async () => {
      const mode = button.dataset.appMode === "whitelist" ? "whitelist" : "blacklist";
      state.appPolicy.mode = mode;
      await runCli(`app mode ${mode}`, { refreshApps: true });
    });
  });

  document.querySelector<HTMLButtonElement>("[data-action='refresh-all']")?.addEventListener("click", async () => {
    await refreshStatus();
    await refreshApps(true);
  });

  document.querySelector<HTMLButtonElement>("[data-copy-last]")?.addEventListener("click", async () => {
    if (!state.lastCommand) return;
    await navigator.clipboard?.writeText(state.lastCommand);
    if (state.hasKsu) kernelsu.toast?.("命令已复制");
  });

  document.querySelector<HTMLButtonElement>("[data-scan-packages]")?.addEventListener("click", scanUserPackages);

  document.querySelector<HTMLButtonElement>("[data-refresh-subs]")?.addEventListener("click", () => refreshSubscriptions());

  document.querySelector<HTMLButtonElement>("[data-refresh-nodes]")?.addEventListener("click", () => refreshNodes());

  document.querySelectorAll<HTMLButtonElement>("[data-node-use]").forEach((button) => {
    button.addEventListener("click", () => switchNode(button.dataset.nodeUse || ""));
  });

  document.querySelector<HTMLButtonElement>("[data-refresh-traffic]")?.addEventListener("click", () => refreshTraffic());

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
  await refreshStatus();
  await refreshApps(true);
  await refreshSubscriptions(true);
  await refreshNodes(true);
  await refreshTraffic(true);
  await refreshCerts(true);
  await refreshCapture(true);
  await refreshHealth(true);
}

void bootstrap();
