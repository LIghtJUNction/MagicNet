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
  MessageCircle,
  Plus,
  Radar,
  RadioTower,
  RefreshCw,
  RotateCcw,
  Route,
  Save,
  Server,
  Settings,
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
const AUTHOR_WHISPER_URL = "https://lightjunction.github.io/lightjunction/";
const OUTPUT_RENDER_LIMIT = 6000;
const CLI_TIMEOUT_MS = 45000;
const PACKAGE_SCAN_LIMIT = 160;
const AUTO_CORE_OPEN_ENABLED_KEY = "magicnet.autoCoreOpen.enabled";
const AUTO_CORE_OPEN_TARGET_KEY = "magicnet.autoCoreOpen.target";
const CUSTOM_WEBUI_PANELS_KEY = "magicnet.customWebui.panels";
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
  transparentMode: "tun" | "tproxy";
  api: string;
  webui: string;
  subPath: string;
};

type HealthItem = {
  key: string;
  status: "ok" | "warn" | "fail" | "info";
  detail: string;
};

type SpecialAction = "open-core" | "copy-core" | "copy-support";
type AiAssistant = "chatgpt" | "gemini" | "kimi" | "qwen" | "deepseek";

type ActionItem = {
  label: string;
  hint: string;
  icon: string;
  tone?: "strong";
  command?: string;
  special?: SpecialAction;
};

type PackageInfo = {
  packageName: string;
  versionName: string;
  versionCode: number;
  appLabel: string;
  isSystem: boolean;
  uid: number;
};

type SysrouteSnapshot = {
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

type BlocklistState = {
  enabled: boolean;
  community: boolean;
  url: string;
  manual: string[];
  communityRules: string[];
  communityDomains: string[];
  allowRules: string[];
  newDomain: string;
};

type McpState = {
  enabled: boolean;
  bind: string;
  port: string;
  pid: string;
  url: string;
};

type MihomoProvider = {
  name: string;
  url: string;
};

type CoreUiTarget = "metacubex" | "yacd" | "zashboard";
type WebuiPanelKind = "online" | "local";

type WebuiPanel = {
  id: string;
  kind: WebuiPanelKind;
  name: string;
  url: string;
  downloadUrl: string;
  metadata: string;
};

type ConfigEditorTarget = "mihomo" | "sing-box";

type ConfigEditorState = {
  target: ConfigEditorTarget;
  text: string;
  originalText: string;
  loadedTarget: ConfigEditorTarget | "";
  dirty: boolean;
  lastCheck: "idle" | "ok" | "error";
  path: string;
};

type State = {
  hasKsu: boolean;
  busy: boolean;
  activeTask: string;
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
    freeFilter: boolean;
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

const state: State = {
  hasKsu: hasKsuBridge,
  busy: false,
  activeTask: "",
  coreLaunch: {
    active: false,
    label: "",
    url: ""
  },
  coreAutoOpen: loadCoreAutoOpen(),
  webuiPanels: loadCustomWebuiPanels(),
  webuiPanelForm: emptyWebuiPanel(),
  commandPhase: "idle",
  commandNotice: "",
  commandQueueDepth: 0,
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
    transparentMode: "tun",
    api: "http://127.0.0.1:9090",
    webui: CORE_UI,
    subPath: `${MODULE_DIR}/.config/sing-box/subscription.url`
  },
  lastCommand: "",
  output: hasKsuBridge
    ? "面板已加载。正在读取 MagicNet 运行状态..."
    : "本地预览模式：这里不会伪造设备数据。通过 KernelSU/APatch 模块 WebUI 打开后，所有按钮会直接调用模块 CLI。",
  appPolicy: {
    mode: "blacklist",
    proxy: [],
    bypass: []
  },
  subscriptions: {
    singBox: "",
    mihomo: "",
    singBoxUrls: [],
    mihomoProviders: [],
    freeFilter: false
  },
  backupPassword: "",
  backupPayload: "",
  restorePassword: "",
  restorePayload: "",
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
  blocklist: {
    enabled: true,
    community: true,
    url: "https://raw.githubusercontent.com/LIghtJUNction/MagicMihomo/main/ruleset/magicnet/ban.yaml",
    manual: [],
    communityRules: [],
    communityDomains: [],
    allowRules: [],
    newDomain: ""
  },
  mcp: {
    enabled: false,
    bind: "127.0.0.1",
    port: "8765",
    pid: "stopped",
    url: "http://127.0.0.1:8765/mcp"
  },
  pingtest: "",
  topology: "",
  topologyFocus: "tun",
  sysrouteSnapshot: emptySysrouteSnapshot(),
  sysroute: {
    rulePriority: "100",
    ruleTable: "main",
    routeTable: "main",
    routeDest: "default",
    routeDev: "",
    routeVia: ""
  },
  health: [],
  packages: [],
  packageQuery: "",
  newPackage: "",
  newTarget: "proxy",
  configEditor: {
    target: "mihomo",
    text: "",
    originalText: "",
    loadedTarget: "",
    dirty: false,
    lastCheck: "idle",
    path: `${MODULE_DIR}/.config/mihomo/config.yaml`
  },
  activeTab: "control"
};

const actions: { title: string; items: ActionItem[] }[] = [
  {
    title: "action.sh 覆盖",
    items: [
      { label: "更新 sing-box 订阅", hint: "对应 action.sh 的订阅更新菜单", icon: "DownloadCloud", command: "sub update", tone: "strong" },
      { label: "选择内核 WebUI", hint: "打开 Meta Cube X / Yacd / zashboard 选择框", icon: "ExternalLink", special: "open-core" },
      { label: "切换 sing-box 进程", hint: "只启动或停止 sing-box，不改禁用文件", icon: "Server", command: "service toggle sing-box" },
      { label: "切换 mihomo", hint: "启动或停止 mihomo", icon: "Route", command: "service toggle mihomo" },
      { label: "网络诊断", hint: "运行 action.sh 同源诊断", icon: "Stethoscope", command: "diagnose" },
      { label: "刷新状态描述", hint: "同步模块描述和运行状态", icon: "RefreshCw", command: "service status" }
    ]
  },
  {
    title: "生命周期",
    items: [
      { label: "启动模块服务", hint: "启动首选 TUN 内核和看门狗", icon: "Zap", command: "service start", tone: "strong" },
      { label: "停止模块服务", hint: "停止内核、watchdog 和配置监听", icon: "Unplug", command: "service stop" },
      { label: "确保内核运行", hint: "如果 TUN 内核退出就拉起", icon: "ShieldCheck", command: "service ensure" },
      { label: "重启 TUN 内核", hint: "停止后重新拉起首选内核", icon: "RotateCcw", command: "service restart", tone: "strong" },
      { label: "应用全部配置", hint: "重写分应用、抓包、黑名单和面板配置", icon: "Save", command: "config apply" },
      { label: "一键自修复", hint: "重载配置、热点和 VPN 共存", icon: "Zap", command: "repair", tone: "strong" }
    ]
  },
  {
    title: "模块维护",
    items: [
      { label: "重载热点转发", hint: "应用 tether 转发规则", icon: "Wifi", command: "hotspot reload" },
      { label: "重载 VPN 共存", hint: "应用外部 VPN 保护规则", icon: "ShieldCheck", command: "vpn reload" },
      { label: "清空旧连接", hint: "关闭 Clash API 连接表", icon: "Unplug", command: "api close-all" },
      { label: "健康检查", hint: "输出结构化模块健康状态", icon: "Stethoscope", command: "health" },
      { label: "复制诊断上下文", hint: "复制脱敏诊断信息和日志尾部", icon: "Copy", special: "copy-support" },
      { label: "复制全部入口", hint: "复制当前面板和三个内核 WebUI 地址", icon: "Link", special: "copy-core" }
    ]
  }
];

const aiAssistants: { key: AiAssistant; label: string; url: string }[] = [
  { key: "chatgpt", label: "ChatGPT", url: "https://chatgpt.com/" },
  { key: "gemini", label: "Gemini", url: "https://gemini.google.com/" },
  { key: "kimi", label: "Kimi", url: "https://www.kimi.com/" },
  { key: "qwen", label: "Qwen", url: "https://chat.qwen.ai/" },
  { key: "deepseek", label: "DeepSeek", url: "https://chat.deepseek.com/" }
];

const tabs = [
  { key: "control", label: "控制", icon: "Gauge" },
  { key: "config", label: "配置", icon: "Settings" },
  { key: "health", label: "诊断", icon: "Stethoscope" },
  { key: "topology", label: "拓扑", icon: "RadioTower" },
  { key: "apps", label: "应用", icon: "ListFilter" },
  { key: "block", label: "黑名单", icon: "Ban" },
  { key: "subs", label: "订阅", icon: "DownloadCloud" },
  { key: "capture", label: "抓包", icon: "ShieldCheck" },
  { key: "certs", label: "证书", icon: "ShieldPlus" },
  { key: "webui", label: "面板", icon: "ExternalLink" },
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
  Radar,
  RadioTower,
  RefreshCw,
  RotateCcw,
  Route,
  Save,
  Server,
  Settings,
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

function intentDataQuote(value: string): string {
  return `"${value.replace(/(["\\$`])/g, "\\$1")}"`;
}

function loadCoreAutoOpen(): State["coreAutoOpen"] {
  const savedTarget = localStorage.getItem(AUTO_CORE_OPEN_TARGET_KEY);
  const target: CoreUiTarget = savedTarget === "yacd" || savedTarget === "zashboard" ? savedTarget : "metacubex";
  return {
    enabled: localStorage.getItem(AUTO_CORE_OPEN_ENABLED_KEY) === "1",
    target,
    attempted: false
  };
}

function saveCoreAutoOpen(): void {
  localStorage.setItem(AUTO_CORE_OPEN_ENABLED_KEY, state.coreAutoOpen.enabled ? "1" : "0");
  localStorage.setItem(AUTO_CORE_OPEN_TARGET_KEY, state.coreAutoOpen.target);
}

function emptyWebuiPanel(): WebuiPanel {
  return {
    id: "",
    kind: "online",
    name: "",
    url: "",
    downloadUrl: "",
    metadata: "{\n  \"homepage\": \"\",\n  \"description\": \"\",\n  \"features\": []\n}"
  };
}

function normalizeWebuiPanel(value: Partial<WebuiPanel>): WebuiPanel | null {
  const name = String(value.name || "").trim();
  const kind: WebuiPanelKind = value.kind === "local" ? "local" : "online";
  const url = String(value.url || "").trim();
  const downloadUrl = String(value.downloadUrl || "").trim();
  const metadata = String(value.metadata || "{}").trim() || "{}";
  if (!name) return null;
  if (kind === "online" && !/^https?:\/\/\S+$/i.test(url)) return null;
  if (kind === "local" && !/^https?:\/\/\S+$/i.test(downloadUrl)) return null;
  return {
    id: String(value.id || `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`),
    kind,
    name,
    url,
    downloadUrl,
    metadata
  };
}

function loadCustomWebuiPanels(): WebuiPanel[] {
  try {
    const raw = JSON.parse(localStorage.getItem(CUSTOM_WEBUI_PANELS_KEY) || "[]");
    if (!Array.isArray(raw)) return [];
    return raw.map((item) => normalizeWebuiPanel(item)).filter((item): item is WebuiPanel => Boolean(item));
  } catch {
    return [];
  }
}

function saveCustomWebuiPanels(): void {
  localStorage.setItem(CUSTOM_WEBUI_PANELS_KEY, JSON.stringify(state.webuiPanels));
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

function hasKsuBridgeNotice(text: string): boolean {
  return text.includes("KernelSU 执行通道");
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

function enqueueCli<T>(label: string, task: () => Promise<T>, onStart?: () => void | Promise<void>): Promise<T> {
  state.commandQueueDepth += 1;
  const run = cliQueue.then(async () => {
    state.commandQueueDepth = Math.max(0, state.commandQueueDepth - 1);
    await onStart?.();
    return task();
  }, async () => {
    state.commandQueueDepth = Math.max(0, state.commandQueueDepth - 1);
    await onStart?.();
    return task();
  });
  cliQueue = run.catch(() => undefined);
  return run;
}

function beginInstantAction(label: string): void {
  state.busy = true;
  state.activeTask = label;
  state.commandPhase = "accepted";
  state.commandNotice = `已接收命令：${label}`;
  render();
}

function finishInstantAction(label: string, notice: string, output?: string): void {
  state.commandPhase = "done";
  state.commandNotice = notice;
  if (output !== undefined) state.output = output;
  if (state.activeTask === label) {
    state.busy = false;
    state.activeTask = "";
  }
  render();
}

async function runCli(args: string, options: { refreshApps?: boolean; quiet?: boolean; label?: string } = {}): Promise<string> {
  const command = `su -c ${shellQuote(`${CLI} ${args}`)}`;
  const label = options.label || args;
  state.lastCommand = command;

  if (!state.hasKsu) {
    const text = `当前浏览器没有 KernelSU 执行通道。\n\n在真机终端可执行：\n${command}`;
    if (!options.quiet) {
      state.commandPhase = "done";
      state.commandNotice = `已生成真机命令：${label}`;
      state.activeTask = "";
      state.busy = false;
      state.output = text;
      render();
    }
    return text;
  }

  if (!options.quiet) {
    const wasBusy = state.busy;
    state.busy = true;
    state.activeTask = label;
    state.commandPhase = wasBusy ? "queued" : "accepted";
    state.commandNotice = wasBusy ? `已加入队列：${label}` : `已接收命令：${label}`;
    state.output = `$ ${command}\n执行中...`;
    render();
    await nextFrame();
  }

  try {
    const result = await enqueueCli(label, async () => withTimeout(kernelsu.exec(command), CLI_TIMEOUT_MS, label), async () => {
      if (!options.quiet) {
        state.commandPhase = "running";
        state.commandNotice = `正在执行：${label}`;
        state.activeTask = label;
        render();
        await nextFrame();
      }
    });
    const text = normalizeExecResult(result);
    if (!options.quiet) {
      state.commandPhase = "done";
      state.commandNotice = `已完成：${label}`;
      state.output = `$ ${command}\n${text || "完成"}`;
    }
    if (options.refreshApps) {
      await refreshApps(true);
    }
    return text;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!options.quiet) {
      state.commandPhase = "error";
      state.commandNotice = `执行失败：${label}`;
    }
    state.output = `$ ${command}\n执行失败：${message}`;
    return state.output;
  } finally {
    if (!options.quiet && state.activeTask === label) {
      state.busy = false;
      state.activeTask = "";
      render();
    }
  }
}

async function openExternalUrl(url: string, label = "外部链接"): Promise<void> {
  state.output = `正在调用系统浏览器打开：\n${url}`;
  render();

  if (state.hasKsu) {
    const command = `su -c ${shellQuote(`am start -a android.intent.action.VIEW -d ${intentDataQuote(url)}`)}`;
    state.lastCommand = command;
    try {
      const result = await kernelsu.exec(command);
      const text = normalizeExecResult(result);
      if (!execFailed(text)) {
        state.output = `已交给系统浏览器打开：\n${url}`;
        kernelsu.toast?.(`${label} 已打开`);
        render();
        return;
      }
      state.output = `系统浏览器启动失败：\n${text}\n\n链接：\n${url}`;
      render();
      return;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      state.output = `系统浏览器启动失败：${message}\n\n链接：\n${url}`;
      render();
      return;
    }
  }

  window.open(url, "_blank", "noopener,noreferrer");
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
    transparentMode: state.runtime.transparentMode,
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
    if (line.startsWith("Transparent:")) {
      const mode = line.slice("Transparent:".length).trim();
      next.transparentMode = mode === "tproxy" ? "tproxy" : "tun";
    }
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

function parseMcpStatus(text: string): McpState {
  const next: McpState = { ...state.mcp };
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("enabled=")) next.enabled = line.slice("enabled=".length) !== "0";
    if (line.startsWith("bind=")) next.bind = line.slice("bind=".length);
    if (line.startsWith("port=")) next.port = line.slice("port=".length);
    if (line.startsWith("pid=")) next.pid = line.slice("pid=".length);
    if (line.startsWith("url=")) next.url = line.slice("url=".length);
  }
  if (!next.url) next.url = `http://${next.bind}:${next.port}/mcp`;
  return next;
}

function emptySysrouteSnapshot(): SysrouteSnapshot {
  return {
    generatedAt: "",
    interfaces: [],
    addresses: [],
    rules: [],
    mainRoutes: [],
    defaultRoutes: [],
    tunRoutes: [],
    allRoutes: [],
    outputGuards: [],
    notes: [],
    raw: ""
  };
}

function parseSysrouteSnapshot(text: string): SysrouteSnapshot {
  const snapshot = emptySysrouteSnapshot();
  snapshot.raw = text;
  let section = "";

  const pushLine = (line: string) => {
    if (!line.trim()) return;
    if (line.startsWith("generated_at=")) {
      snapshot.generatedAt = line.slice("generated_at=".length).trim();
      return;
    }
    if (line.startsWith("#")) return;
    if (line.startsWith("## ")) {
      section = line.slice(3).trim();
      return;
    }
    if (section === "interfaces") snapshot.interfaces.push(line);
    if (section === "addresses") snapshot.addresses.push(line);
    if (section === "policy-rules") snapshot.rules.push(line);
    if (section === "main-routes") snapshot.mainRoutes.push(line);
    if (section === "default-routes") snapshot.defaultRoutes.push(line);
    if (section === "tun-routes") snapshot.tunRoutes.push(line);
    if (section === "all-routes") snapshot.allRoutes.push(line);
    if (section === "netfilter-output") snapshot.outputGuards.push(line);
    if (section === "notes") snapshot.notes.push(line);
  };

  text.split(/\r?\n/).forEach(pushLine);
  return snapshot;
}

async function refreshMcp(quiet = false): Promise<void> {
  const text = await runCli("mcp status", { quiet });
  if (state.hasKsu && text) {
    state.mcp = parseMcpStatus(text);
  }
  if (!quiet) render();
}

type CoreOpenTarget = CoreUiTarget | `custom:${string}`;

async function openCoreUi(): Promise<void> {
  await openCoreUiTarget("metacubex");
}

function findCustomWebuiPanel(target: CoreOpenTarget): WebuiPanel | undefined {
  if (!target.startsWith("custom:")) return undefined;
  return state.webuiPanels.find((panel) => panel.id === target.slice("custom:".length));
}

function coreUiTargetUrl(target: CoreOpenTarget): string {
  const custom = findCustomWebuiPanel(target);
  if (custom) return custom.kind === "online" ? custom.url : `${state.runtime.api}/ui/`;
  if (target === "yacd") return "https://yacd.metacubex.one/?hostname=127.0.0.1&port=9090&secret=";
  if (target === "zashboard") return `${state.runtime.api}/ui/`;
  return `${state.runtime.api}/ui/cubex/`;
}

function coreUiTargetLabel(target: CoreOpenTarget): string {
  const custom = findCustomWebuiPanel(target);
  if (custom) return custom.name;
  if (target === "yacd") return "Yacd";
  if (target === "zashboard") return "zashboard";
  return "Meta Cube X";
}

async function openCoreUiTarget(target: CoreOpenTarget): Promise<void> {
  const url = coreUiTargetUrl(target);
  const label = coreUiTargetLabel(target);
  if (!state.hasKsu) {
    state.output = "当前浏览器没有 KernelSU 执行通道，无法确认内核 WebUI 是否在线。";
    render();
    return;
  }

  state.coreLaunch = { active: true, label, url };
  state.commandNotice = `正在打开 ${label}`;
  state.output = `正在准备进入 ${label}：\n${url}\n\n正在确认 Clash API 可用，请稍等。`;
  render();
  await nextFrame();

  const text = await runCli("api groups", { quiet: true });
  if (!text || execFailed(text)) {
    state.coreLaunch = { active: false, label: "", url: "" };
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

  state.output = `正在进入 ${label}：\n${url}\n\n如果几秒后仍停留在这里，请返回后点“复制全部入口”。`;
  render();
  window.setTimeout(() => {
    window.location.assign(url);
  }, 260);
}

async function maybeAutoOpenCoreUi(): Promise<void> {
  if (!state.hasKsu || !state.coreAutoOpen.enabled || state.coreAutoOpen.attempted) return;
  state.coreAutoOpen.attempted = true;

  if (state.runtime.core !== "sing-box" && state.runtime.core !== "mihomo") {
    state.output = "已启用自动进入内核 WebUI，但当前内核状态不正常，因此不会自动跳转。";
    render();
    return;
  }

  await openCoreUiTarget(state.coreAutoOpen.target);
}

async function runAction(command: string): Promise<void> {
  const text = await runCli(command, { label: command });
  const shouldRefreshStatus = /^(service|repair|mode|hotspot|vpn|config|transparent|api)\b/.test(command);
  const shouldRefreshHealth = /^(health|repair|hotspot|vpn|config|transparent|capture|block|app|cert)\b/.test(command);
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

  if (shouldRefreshStatus) {
    await refreshStatus(true);
  }
  if (/^(sub|setup)\b/.test(command)) {
    await refreshSubscriptions(true);
  }
  if (/^app\b/.test(command)) await refreshApps(true);
  if (/^block\b/.test(command)) {
    await refreshBlocklist(true);
  }
  if (/^capture\b/.test(command)) await refreshCapture(true);
  if (/^cert\b/.test(command)) await refreshCerts(true);
  if (/^mcp\b/.test(command)) await refreshMcp(true);
  if (shouldRefreshHealth) await refreshHealth(true);
  render();
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
    await refreshMcp(true);
    if (state.activeTab === "subs") {
      await refreshSubscriptions(true);
    } else if (state.activeTab === "apps") {
      await refreshApps(true);
    } else if (state.activeTab === "block") {
      await refreshBlocklist(true);
    } else if (state.activeTab === "capture") {
      await refreshCapture(true);
    } else if (state.activeTab === "certs") {
      await refreshCerts(true);
    } else if (state.activeTab === "health") {
      await refreshHealth(true);
    } else if (state.activeTab === "config") {
      await refreshConfigEditorPath(true);
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

function parseBlocklist(text: string): BlocklistState {
  const next: BlocklistState = { ...state.blocklist, manual: [], communityRules: [], communityDomains: [], allowRules: [] };
  let section: "manual" | "communityRules" | "communityDomains" | "allowRules" | null = null;

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
    if (line === "community rules:") {
      section = "communityRules";
      continue;
    }
    if (line === "community domain suffixes:") {
      section = "communityDomains";
      continue;
    }
    if (line === "local allow rules:") {
      section = "allowRules";
      continue;
    }
    if (section === "manual") next.manual.push(line);
    if (section === "communityRules") next.communityRules.push(line);
    if (section === "communityDomains") next.communityDomains.push(line);
    if (section === "allowRules") next.allowRules.push(line);
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
  const next: State["subscriptions"] = { ...state.subscriptions, singBoxUrls: [], mihomoProviders: [] };
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (/^sing-box\.\d+=/.test(line)) {
      next.singBoxUrls.push(line.replace(/^sing-box\.\d+=/, ""));
      continue;
    }
    if (/^mihomo\.[A-Za-z0-9_-]+=/.test(line)) {
      const match = line.match(/^mihomo\.([A-Za-z0-9_-]+)=(.*)$/);
      if (match) next.mihomoProviders.push({ name: match[1], url: match[2] });
      continue;
    }
    if (line.startsWith("sing-box=")) next.singBox = line.slice("sing-box=".length);
    if (line.startsWith("mihomo=")) next.mihomo = line.slice("mihomo=".length);
    if (line.startsWith("free-filter=")) next.freeFilter = line.slice("free-filter=".length).trim() === "1";
  }
  if (next.singBoxUrls.length === 0 && next.singBox) next.singBoxUrls = [next.singBox];
  return next;
}

async function refreshSubscriptions(quiet = false): Promise<void> {
  const text = await runCli("sub list", { quiet });
  if (state.hasKsu && text) {
    state.subscriptions = parseSubscriptions(text);
  }
  if (!quiet) render();
}

async function exportBackup(): Promise<void> {
  const password = state.backupPassword.trim();
  const text = await runCli(`backup export ${password ? shellQuote(password) : ""}`.trim(), { label: "导出配置" });
  if (text && !execFailed(text)) {
    state.backupPayload = text.trim();
    await navigator.clipboard?.writeText(state.backupPayload);
    state.commandNotice = "配置备份已导出并复制";
    if (state.hasKsu) kernelsu.toast?.("备份已复制");
  }
  render();
}

async function restoreBackup(): Promise<void> {
  const password = state.restorePassword.trim();
  const payload = state.restorePayload.trim();
  if (!payload) {
    state.output = "请先粘贴 base64 备份内容。";
    render();
    return;
  }
  await runCli(`backup restore ${password ? shellQuote(password) : "-"} ${shellQuote(payload)}`, { label: "恢复配置" });
  await refreshSubscriptions(true);
  await refreshApps(true);
  await refreshBlocklist(true);
  await refreshCapture(true);
  await refreshMcp(true);
  await refreshHealth(true);
  render();
}

function configEditorPath(target: ConfigEditorTarget): string {
  return target === "mihomo"
    ? `${MODULE_DIR}/.config/mihomo/config.yaml`
    : `${MODULE_DIR}/.config/sing-box/config.json`;
}

function configEditorLabel(target = state.configEditor.target): string {
  return target === "mihomo" ? "mihomo config.yaml" : "sing-box config.json";
}

async function refreshConfigEditorPath(quiet = false): Promise<void> {
  state.configEditor.path = configEditorPath(state.configEditor.target);
  if (!state.hasKsu) {
    if (!quiet) render();
    return;
  }
  const text = await runCli(`config-editor path ${state.configEditor.target}`, { quiet: true, label: "配置路径" });
  if (text && !execFailed(text) && !hasKsuBridgeNotice(text)) {
    state.configEditor.path = text.trim();
  }
  if (!quiet) render();
}

async function loadConfigEditor(): Promise<void> {
  const target = state.configEditor.target;
  const text = await runCli(`config-editor get ${target}`, { label: `加载 ${configEditorLabel(target)}` });
  if (text && !execFailed(text) && !hasKsuBridgeNotice(text)) {
    state.configEditor.text = text;
    state.configEditor.originalText = text;
    state.configEditor.loadedTarget = target;
    state.configEditor.dirty = false;
    state.configEditor.lastCheck = "idle";
    await refreshConfigEditorPath(true);
  }
  render();
}

async function saveConfigEditor(): Promise<void> {
  const target = state.configEditor.target;
  const text = state.configEditor.text;
  if (!text.trim()) {
    state.output = "配置内容为空，已阻止保存。";
    state.configEditor.lastCheck = "error";
    render();
    return;
  }
  const encoded = bytesToBase64(new TextEncoder().encode(text));
  const result = await runCli(`config-editor save ${target} ${shellQuote(encoded)}`, { label: `校验并保存 ${configEditorLabel(target)}` });
  if (result && !execFailed(result)) {
    state.configEditor.loadedTarget = target;
    state.configEditor.originalText = text;
    state.configEditor.dirty = false;
    state.configEditor.lastCheck = "ok";
    await refreshStatus(true);
    await refreshHealth(true);
  } else {
    state.configEditor.lastCheck = "error";
  }
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

async function refreshPingtest(): Promise<void> {
  const text = await runCli("pingtest", { label: "连通性测试" });
  state.pingtest = text;
  state.activeTab = "health";
  render();
}

async function refreshTopology(quiet = false): Promise<void> {
  const text = await runCli("topology", { quiet, label: "网络拓扑" });
  state.topology = text;
  if (state.hasKsu) {
    const routeText = await runCli("sysroute snapshot", { quiet: true, label: "系统路由表" });
    if (routeText) state.sysrouteSnapshot = parseSysrouteSnapshot(routeText);
  }
  if (!quiet) {
    state.activeTab = "topology";
    render();
  }
}

async function refreshSysroute(quiet = false): Promise<void> {
  const text = await runCli("sysroute snapshot", { quiet, label: "系统路由表" });
  if (text) {
    state.sysrouteSnapshot = parseSysrouteSnapshot(text);
    state.topology = text;
  }
  if (!quiet) {
    state.activeTab = "topology";
    render();
  }
}

async function generateDiagnosticContext(label = "复制诊断上下文"): Promise<string> {
  const text = await runCli("support bundle", { label });
  if (text) {
    const context = [
      "请帮我诊断 MagicNet Android root 透明代理模块问题。",
      "重点看 TUN 内核、Clash API、订阅、VPN 共存、热点转发、分应用、抓包规则和日志错误。",
      "下面是 MagicNet 脱敏诊断上下文：",
      "",
      text,
      state.pingtest ? "\n连通性测试：\n" : "",
      state.pingtest
    ].join("\n");
    await navigator.clipboard?.writeText(context);
    state.commandNotice = "诊断上下文已复制";
    if (state.hasKsu) kernelsu.toast?.("诊断上下文已复制");
    return context;
  }
  return "";
}

async function copyCoreEntries(label = "复制全部入口"): Promise<void> {
  beginInstantAction(label);
  const text = state.hasKsu ? await runCli("api ui all", { quiet: true }) : "";
  const fallback = [
    `current=${coreUiUrl()}`,
    `metacubex=${coreUiTargetUrl("metacubex")}`,
    `yacd=${coreUiTargetUrl("yacd")}`,
    `zashboard=${coreUiTargetUrl("zashboard")}`
  ].join("\n");
  const value = text && !execFailed(text) && !hasKsuBridgeNotice(text) ? text : fallback;
  await navigator.clipboard?.writeText(value);
  if (state.hasKsu) kernelsu.toast?.("WebUI 入口已复制");
  finishInstantAction(label, "已复制全部 WebUI 入口", `已复制全部 WebUI 入口：\n${value}`);
}

function utf8ToBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary);
}

const healthLabels: Record<string, { label: string; icon: string; fix?: string; fixLabel?: string; explain: string }> = {
  core: { label: "TUN 内核", icon: "Server", fix: "service restart", fixLabel: "重启", explain: "透明代理的核心进程负责创建 TUN 入站、加载规则和转发流量。排查时先看进程是否存在，再看内核日志是否有配置解析、权限或端口冲突错误。" },
  tun: { label: "TUN 网卡", icon: "RadioTower", fix: "service restart", fixLabel: "重启", explain: "TUN 网卡是系统流量进入代理内核的入口。异常通常来自权限、路由表、VPN 共存或内核未完成启动。排查方法是确认接口存在、路由指向正确、内核日志无 bind/tun 错误。" },
  watchdog: { label: "看门狗", icon: "Bell", fix: "service restart", fixLabel: "重启服务", explain: "看门狗负责在内核退出后拉起服务。它不替代配置修复，只保证异常退出后能恢复。排查时看 watchdog 是否运行、重启次数和最近日志。" },
  fswatch: { label: "配置监听", icon: "Activity", fix: "service restart", fixLabel: "重启服务", explain: "配置监听用于发现订阅、黑名单、抓包和应用名单变化后触发应用配置。异常时可能导致用户改了配置但内核没有热更新。" },
  api: { label: "Clash API", icon: "Gauge", fix: "service restart", fixLabel: "重启", explain: "Clash API 是管理面板和内核 WebUI 的控制接口。内核 WebUI 打不开时，先检查 127.0.0.1:9090 是否可用，再判断是 API 未启动还是 WebUI 静态资源问题。" },
  "sing-box-sub": { label: "sing-box 订阅", icon: "DownloadCloud", fix: "sub update-all", fixLabel: "更新", explain: "sing-box 订阅会被转换成出站节点配置。异常通常是订阅 URL 无效、网络不可达、格式不兼容或生成配置失败。" },
  "mihomo-sub": { label: "mihomo 订阅", icon: "DownloadCloud", explain: "mihomo 使用 proxy-providers 管理订阅。检查时重点看 provider URL、下载结果、节点数量和配置 reload 是否成功。" },
  capture: { label: "抓包规则", icon: "ShieldCheck", fix: "capture apply", fixLabel: "应用", explain: "抓包规则把指定 App 或域名导向电脑上的 HTTP 抓包代理。排查时确认电脑 IP/端口可达、目标 App/域名命中规则、内核已经重载配置。" },
  blocklist: { label: "联 ban 黑名单", icon: "Ban", fix: "block update", fixLabel: "更新", explain: "联 ban 黑名单把社区恶意域名规则注入 mihomo 和 sing-box。排查时确认社区库下载成功、本地排除规则没有误放行、内核配置已应用。" },
  hotspot: { label: "热点转发", icon: "Wifi", fix: "hotspot reload", fixLabel: "重载", explain: "热点转发处理手机共享网络时的 NAT 和转发链路。异常时热点设备可能无法走透明代理或无法联网，排查 iptables/tether 规则和当前上游接口。" },
  vpn: { label: "VPN 共存", icon: "ShieldCheck", fix: "vpn reload", fixLabel: "重载", explain: "VPN 共存用于避免外部 VPN、TUN、路由规则互相抢流量。异常时可能出现流量回环或不可达，排查路由优先级、保护规则和外部 VPN 状态。" },
  certs: { label: "系统 CA", icon: "ShieldPlus", explain: "系统 CA 通过模块 systemless 覆盖到 Android 证书目录。抓 HTTPS 包时需要证书正确安装并重启生效，部分 App 仍可能有证书固定。" }
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

function healthExplainText(key: string, status: string, detail: string): string {
  const meta = healthLabels[key] || {
    label: key,
    icon: "Stethoscope",
    explain: "这是 MagicNet 健康诊断中的一个模块检查项。排查时先看当前状态和详细输出，再结合最近输出中的 CLI 结果判断是否需要重启或重新应用配置。"
  };
  return [
    `诊断项：${meta.label}`,
    `当前状态：${status}`,
    `当前详情：${detail || "无额外详情"}`,
    "",
    "概念和原理：",
    meta.explain,
    "",
    "技术排查方法：",
    "1. 先运行健康诊断确认状态是否复现。",
    "2. 查看最近输出和对应内核日志，定位是配置、进程、API、路由还是网络问题。",
    "3. 对有修复按钮的项目，先使用面板动作重载或重启；仍失败再复制诊断上下文询问 AI 或提交 issue。"
  ].join("\n");
}

function healthPanel(): string {
  const summary = healthSummary();
  const aiButtons = aiAssistants
    .map((item) => `
      <button class="ai-assist-card" data-ask-ai="${item.key}">
        <span>${icon("ExternalLink", 16)}</span>
        <strong>${item.label}</strong>
        <small>复制上下文后打开</small>
      </button>
    `)
    .join("");
  const items = state.health.length
    ? state.health
      .map((item) => {
        const meta = healthLabels[item.key] || { label: item.key, icon: "Stethoscope", explain: "" };
        return `
          <div class="health-row ${item.status}">
            <span class="health-mark">${icon(meta.icon, 18)}</span>
            <div>
              <strong>${escapeHtml(meta.label)}</strong>
              <small>${escapeHtml(item.detail || item.status)}</small>
            </div>
            <span class="health-state">${item.status}</span>
            <button class="health-detail-button" data-health-detail="${escapeHtml(item.key)}">${icon("FileText", 15)}详情</button>
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
          <button class="command-secondary" data-pingtest>${icon("RadioTower", 18)}连通性测试</button>
          <button class="command-secondary" data-support-bundle>${icon("Copy", 18)}复制诊断上下文</button>
        </div>
      </div>
      <div class="ai-assist-panel">
        <div>
          <span class="eyebrow">Ask With Context</span>
          <h3>带诊断上下文询问 AI</h3>
          <p>先复制 MagicNet 脱敏诊断上下文，再用系统浏览器打开外部 AI。登录态留在系统浏览器，不在模块 WebView 里硬跳。</p>
        </div>
        <div class="ai-assist-actions">${aiButtons}</div>
      </div>
      <div class="pingtest-panel">
        <div>
          <span class="eyebrow">Connectivity</span>
          <h3>国内外站点连通性</h3>
          <p>测试 Baidu、Bilibili、Google、ChatGPT、GitHub。ICMP ping 被拦截时以 HTTP 结果为准。</p>
        </div>
        <pre>${escapeHtml(state.pingtest || "还没有测试结果。点击“连通性测试”开始。")}</pre>
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

function compactLines(lines: string[], limit = 8): string {
  const visible = lines.filter(Boolean).slice(0, limit);
  if (!visible.length) return `<div class="route-empty">没有读取到数据</div>`;
  const more = lines.length > limit ? `<small>还有 ${lines.length - limit} 行，下面原始输出里可看完整内容。</small>` : "";
  return `
    <div class="sysroute-lines">
      ${visible.map((line) => `<code>${escapeHtml(line)}</code>`).join("")}
      ${more}
    </div>
  `;
}

function routeDevFromLine(line: string): string {
  const match = line.match(/(?:^|\s)dev\s+([^\s]+)/);
  return match?.[1] || "";
}

function routePriority(line: string): string {
  const match = line.match(/^([0-9]+):/);
  return match?.[1] || "";
}

function routeRiskItems(snapshot: SysrouteSnapshot): string[] {
  const risks: string[] = [];
  if (snapshot.rules.some((line) => /^0:/.test(line) || /^1:/.test(line))) {
    risks.push("检测到 priority 0/1 级别规则。Android、VPN、厂商网络服务也会使用高优先级，编辑前先确认回滚路径。");
  }
  const defaultPhys = snapshot.defaultRoutes.some((line) => {
    const dev = routeDevFromLine(line);
    return dev && !/tun|utun|magicnet|lo/i.test(dev);
  });
  if (defaultPhys) risks.push("默认路由仍指向物理网卡。这不一定是错，TUN 透明代理通常依赖策略路由和内核保护规则共同生效。");
  if (snapshot.outputGuards.some((line) => /\b(REJECT|DROP)\b/.test(line)) && !snapshot.outputGuards.some((line) => /owner|uid/i.test(line))) {
    risks.push("OUTPUT 链存在拒绝规则但没看到 UID 放行信息，误配可能导致内核自身也无法出网。");
  }
  if (!snapshot.tunRoutes.length || snapshot.tunRoutes.some((line) => /no TUN related/.test(line))) {
    risks.push("没有看到明显 TUN 路由。若内核已在线但这里为空，需要结合内核配置和 ip rule 判断流量入口。");
  }
  return risks;
}

function sysrouteOverview(): string {
  const snapshot = state.sysrouteSnapshot;
  const defaultDev = snapshot.defaultRoutes.map(routeDevFromLine).filter(Boolean)[0] || "未知";
  const tunDevs = Array.from(new Set([
    ...snapshot.tunRoutes.map(routeDevFromLine),
    ...snapshot.addresses.map((line) => line.match(/^[0-9]+:\s+([^ ]+)/)?.[1] || "")
  ].filter((dev) => /tun|utun|magicnet/i.test(dev)))).slice(0, 4);
  const highRules = snapshot.rules
    .map((line) => ({ priority: Number(routePriority(line) || "999999"), line }))
    .filter((item) => item.priority < 1000)
    .slice(0, 3);
  const risks = routeRiskItems(snapshot);

  return `
    <section class="sysroute-overview">
      <div class="sysroute-card accent">
        <span>${icon("Radar", 18)}</span>
        <strong>${snapshot.rules.length || 0}</strong>
        <small>策略路由规则</small>
      </div>
      <div class="sysroute-card">
        <span>${icon("Route", 18)}</span>
        <strong>${escapeHtml(defaultDev)}</strong>
        <small>默认出口 dev</small>
      </div>
      <div class="sysroute-card">
        <span>${icon("RadioTower", 18)}</span>
        <strong>${escapeHtml(tunDevs.join(", ") || "未发现")}</strong>
        <small>TUN 相关接口</small>
      </div>
      <div class="sysroute-card ${risks.length ? "warn" : ""}">
        <span>${icon(risks.length ? "ShieldPlus" : "ShieldCheck", 18)}</span>
        <strong>${risks.length ? `${risks.length} 项` : "正常"}</strong>
        <small>风险提示</small>
      </div>
      <div class="sysroute-detail-card">
        <h4>高优先级规则</h4>
        ${compactLines(highRules.map((item) => item.line), 4)}
      </div>
      <div class="sysroute-detail-card ${risks.length ? "warn" : ""}">
        <h4>编辑前判断</h4>
        ${risks.length ? `<ul>${risks.map((risk) => `<li>${escapeHtml(risk)}</li>`).join("")}</ul>` : `<p>没有发现明显高危路由特征。仍建议每次只改一条，然后立即刷新验证。</p>`}
      </div>
    </section>
  `;
}

const topologyConcepts: Record<string, { title: string; body: string }> = {
  app: { title: "客户端 App", body: "App 发出的 TCP/UDP 流量先进入 Android 网络栈。透明代理的关键是让 App 不需要知道代理存在，由系统路由把流量导向 TUN。" },
  route: { title: "Android 路由表", body: "路由表决定流量下一跳。MagicNet 需要让目标流量进入 TUN，同时避免热点、局域网和外部 VPN 出现回环。" },
  tun: { title: "TUN 虚拟网卡", body: "TUN 是用户态代理内核接收系统流量的虚拟网卡。它不像普通 HTTP 代理暴露给 App，因此透明度更高。" },
  core: { title: "sing-box / mihomo 内核", body: "内核读取订阅、规则、分应用和抓包配置，决定每条连接走代理、直连、阻断或抓包代理。" },
  upstream: { title: "上游网络", body: "上游可以是 Wi-Fi/蜂窝网络、代理节点、电脑抓包代理或热点转发后的出口。最终路径取决于内核规则和系统路由。" },
  hotspot: { title: "热点与转发", body: "热点客户端的流量会经过 tether 转发和 NAT。MagicNet 需要把这部分流量正确转入或绕过 TUN，避免只能手机本机生效。" },
  vpn: { title: "外部 VPN 共存", body: "外部 VPN 也会改路由和 TUN。共存规则的目标是避免 MagicNet 和外部 VPN 抢默认路由，造成流量回环或断流。" }
};

function topologyPanel(): string {
  const focus = topologyConcepts[state.topologyFocus] || topologyConcepts.tun;
  const snapshot = state.sysrouteSnapshot;
  const nodes = [
    ["app", 10, 42],
    ["route", 24, 42],
    ["tun", 40, 42],
    ["core", 58, 42],
    ["upstream", 78, 42],
    ["hotspot", 24, 72],
    ["vpn", 48, 18]
  ] as const;
  return `
    <div class="section-intro">
      <div>
        <span class="eyebrow">Network Topology</span>
        <h3>透明代理网络拓扑</h3>
        <p>把虚拟网卡、策略路由、TUN、热点转发和 VPN 共存画成可点选路径。路由表来自真实设备，可手动刷新和谨慎编辑。</p>
      </div>
      <div class="section-actions">
        <button class="command-secondary" data-refresh-topology>${icon("RefreshCw", 17)}刷新拓扑</button>
        <button class="command-primary" data-refresh-sysroute>${icon("Radar", 17)}刷新路由表</button>
      </div>
    </div>
    <div class="topology-layout">
      <section class="topology-map">
        <svg viewBox="0 0 100 90" role="img" aria-label="MagicNet network topology">
          <path class="topology-line" d="M16 42 H76" />
          <path class="topology-line dashed" d="M24 68 V47" />
          <path class="topology-line dashed" d="M49 22 V37" />
          ${nodes.map(([key, x, y]) => `
            <g class="topology-node ${state.topologyFocus === key ? "active" : ""}" data-topology-node="${key}" transform="translate(${x} ${y})">
              <circle r="6"></circle>
              <text y="15">${escapeHtml(topologyConcepts[key].title)}</text>
            </g>
          `).join("")}
        </svg>
      </section>
      <section class="topology-explain">
        <span class="eyebrow">Concept</span>
        <h3>${escapeHtml(focus.title)}</h3>
        <p>${escapeHtml(focus.body)}</p>
        <button class="command-secondary" data-copy-topology-explain>${icon("Copy", 17)}复制解说</button>
      </section>
    </div>
    <section class="route-editor">
      <div>
        <span class="eyebrow">System Route Workbench</span>
        <h3>系统路由表可视化与手动编辑</h3>
        <p>这里编辑 Android Linux 底层 <code>ip rule</code> / <code>ip route</code>。它不是代理分流配置，也不会自动写入全局防漏墙。每次只改一条，改完立即刷新。</p>
      </div>
      ${sysrouteOverview()}
      <form class="route-editor-form" data-sysroute-rule-form>
        <label><span>priority</span><input name="priority" value="${escapeHtml(state.sysroute.rulePriority)}" inputmode="numeric" /></label>
        <label><span>lookup table</span><input name="table" value="${escapeHtml(state.sysroute.ruleTable)}" placeholder="main 或 100" /></label>
        <button type="submit">${icon("Plus", 17)}添加 ip rule</button>
        <button type="button" data-sysroute-del-rule>${icon("X", 17)}删除 priority</button>
      </form>
      <form class="route-editor-form" data-sysroute-route-form>
        <label><span>table</span><input name="table" value="${escapeHtml(state.sysroute.routeTable)}" placeholder="main 或 100" /></label>
        <label><span>dest</span><input name="dest" value="${escapeHtml(state.sysroute.routeDest)}" placeholder="default 或 0.0.0.0/0" /></label>
        <label><span>dev</span><input name="dev" value="${escapeHtml(state.sysroute.routeDev)}" placeholder="tun0 / wlan0" /></label>
        <label><span>via 可空</span><input name="via" value="${escapeHtml(state.sysroute.routeVia)}" placeholder="192.168.1.1" /></label>
        <button type="submit">${icon("Plus", 17)}添加 route</button>
        <button type="button" data-sysroute-del-route>${icon("X", 17)}删除 route</button>
      </form>
      <div class="route-editor-note">
        <strong>关于网上说的“锁死路由”</strong>
        <span>把规则抢到 priority 0 或直接 DROP 物理网卡，确实可能防漏，但也可能让 Android 网络服务、外部 VPN、热点和内核自身出网一起断掉。MagicNet 只提供手动编辑和证据展示，不做不可回滚的一键锁死。</span>
      </div>
    </section>
    <section class="sysroute-grid">
      <div class="sysroute-detail-card">
        <h4>policy rules</h4>
        ${compactLines(snapshot.rules, 10)}
      </div>
      <div class="sysroute-detail-card">
        <h4>default routes</h4>
        ${compactLines(snapshot.defaultRoutes, 8)}
      </div>
      <div class="sysroute-detail-card">
        <h4>TUN routes</h4>
        ${compactLines(snapshot.tunRoutes, 8)}
      </div>
      <div class="sysroute-detail-card">
        <h4>OUTPUT guard</h4>
        ${compactLines(snapshot.outputGuards, 8)}
      </div>
    </section>
    <div class="pingtest-panel">
      <div>
        <span class="eyebrow">Device Evidence</span>
        <h3>完整原始输出</h3>
        <p>${snapshot.generatedAt ? `路由快照：${escapeHtml(snapshot.generatedAt)}` : "来自模块 CLI 的接口、路由、转发和监听摘要。"}</p>
      </div>
      <pre>${escapeHtml(snapshot.raw || state.topology || "还没有读取拓扑。点击“刷新路由表”开始。")}</pre>
    </div>
  `;
}

function mcpPanel(): string {
  const running = state.mcp.pid && state.mcp.pid !== "stopped";
  const url = state.mcp.url || `http://${state.mcp.bind}:${state.mcp.port}/mcp`;
  return `
    <section class="runtime-control mcp-control">
      <div class="runtime-toggle">
        <div>
          <span class="eyebrow">MCP Streamable HTTP</span>
          <h3>本地 MCP 控制服务器</h3>
          <p>${running ? `运行中：pid ${escapeHtml(state.mcp.pid)}` : "未运行。默认只监听 127.0.0.1，适合 ADB 端口转发后由 Codex/Claude 调用。"}</p>
          <code>${escapeHtml(url)}</code>
        </div>
        <button class="toggle ${running ? "on" : ""}" data-mcp-toggle>
          ${running ? "关闭 MCP" : "开启 MCP"}
        </button>
      </div>
      <div class="support-actions compact-actions">
        <button class="command-secondary" data-refresh-mcp>${icon("RefreshCw", 17)}刷新 MCP</button>
        <button class="command-secondary" data-copy-mcp>${icon("Copy", 17)}复制 MCP URL</button>
      </div>
    </section>
  `;
}

function activeTabPanel(tab: State["activeTab"]): string {
  if (tab === "control") {
    const restartSingBoxDisabled = state.runtime.singBoxDisabled ? "disabled" : "";
    const specialLabels: Record<SpecialAction, string> = {
      "open-core": "选择内核 WebUI",
      "copy-core": "复制全部入口",
      "copy-support": "复制诊断上下文"
    };
    const renderAction = (item: ActionItem) => {
      const taskLabel = item.command || (item.special ? specialLabels[item.special] : "");
      const active = Boolean(taskLabel && state.activeTask === taskLabel);
      const actionAttr = item.command
        ? `data-run="${escapeHtml(item.command)}"`
        : `data-special-action="${escapeHtml(item.special || "")}"`;
      return `
        <button class="action-card ${item.tone || ""} ${active ? "running" : ""}" ${actionAttr}>
          <span>${icon(item.icon, 20)}</span>
          <strong>${escapeHtml(item.label)}</strong>
          <small>${active ? "正在执行，稍等返回结果" : escapeHtml(item.hint)}</small>
        </button>
      `;
    };
    return `
      <div class="tab-panel show">
        ${commandFeedback()}
        <div class="control-quick">
          ${commandDeck()}
        </div>
        <section class="runtime-control transparent-control">
          <div class="runtime-toggle">
            <div>
              <span class="eyebrow">Transparent Mode</span>
              <h3>透明代理入口模式</h3>
              <p>${state.runtime.transparentMode === "tproxy" ? "当前为 TProxy。适合需要 Linux transparent proxy 入站的实验场景；默认推荐 TUN。" : "当前为 TUN。默认模式，移动端兼容性和可控性最好。"}</p>
            </div>
            <div class="segmented">
              <button class="${state.runtime.transparentMode === "tun" ? "selected" : ""}" data-transparent-mode="tun">TUN</button>
              <button class="${state.runtime.transparentMode === "tproxy" ? "selected" : ""}" data-transparent-mode="tproxy">TProxy</button>
            </div>
          </div>
          <div class="runtime-toggle compact-runtime-note">
            <div>
              <span class="eyebrow">Apply Behavior</span>
              <h3>切换后重启内核</h3>
              <p>保存会先重写双内核入站配置并应用路由规则。若当前内核没有热重载入站，请执行“重启当前内核”。</p>
            </div>
            <button class="command-secondary" data-run="transparent apply">${icon("Save", 17)}重新应用</button>
          </div>
        </section>
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
        ${mcpPanel()}
        ${coreAutoOpenPanel()}
        ${supportAccessPanel()}
        <div class="control-groups">
          ${actions
            .map(
              (group) => `
                <section class="control-group">
                  <div class="control-group-head">
                    <h3>${escapeHtml(group.title)}</h3>
                  </div>
                  <div class="action-grid">
                    ${group.items.map(renderAction).join("")}
                  </div>
                </section>
              `
            )
            .join("")}
        </div>
      </div>
    `;
  }

  if (tab === "config") return `<div class="tab-panel show">${configEditorPanel()}</div>`;
  if (tab === "health") return `<div class="tab-panel show">${healthPanel()}</div>`;
  if (tab === "topology") return `<div class="tab-panel show">${topologyPanel()}</div>`;

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

  if (tab === "block") return `<div class="tab-panel show">${blocklistPanel()}</div>`;
  if (tab === "subs") return `<div class="tab-panel show">${subscriptionsSection()}</div>`;
  if (tab === "capture") return `<div class="tab-panel show">${capturePanel()}</div>`;
  if (tab === "certs") return `<div class="tab-panel show">${certPanel()}</div>`;
  if (tab === "webui") return `<div class="tab-panel show">${webuiConfigPanel()}</div>`;

  return `
    <div class="tab-panel show">
      <div class="log-toolbar">
        <button data-run="service logs sing-box 160">${icon("FileText", 17)}sing-box 日志</button>
        <button data-run="service logs mihomo 160">${icon("FileText", 17)}mihomo 日志</button>
        <button data-run="service status">${icon("RefreshCw", 17)}状态快照</button>
        <button data-health-run>${icon("Stethoscope", 17)}健康诊断</button>
        <button data-support-bundle>${icon("Copy", 17)}诊断上下文</button>
        <button data-copy-last>${icon("Copy", 17)}复制命令</button>
      </div>
      <pre class="terminal">${escapeHtml(compactOutput(state.output))}</pre>
    </div>
  `;
}

function supportAccessPanel(): string {
  return `
    <section class="support-access">
      <div class="support-copy">
        <span class="eyebrow">Support & Links</span>
        <h3>入口和诊断上下文</h3>
        <p>遇到打不开内核面板、规则未生效、VPN 共存异常时，先复制诊断上下文；需要换面板时复制全部 WebUI 入口。</p>
      </div>
      <div class="support-actions">
        <button class="command-secondary" data-support-bundle>${icon("Copy", 17)}复制诊断上下文</button>
        <button class="command-secondary" data-copy-core-entries>${icon("Link", 17)}复制全部入口</button>
        <button class="command-secondary" data-open-external-url="${escapeHtml(REPO)}" data-open-external-label="GitHub">${icon("Github", 17)}GitHub</button>
      </div>
    </section>
  `;
}

function coreAutoOpenPanel(): string {
  return `
    <section class="runtime-control">
      <div class="runtime-toggle">
        <div>
          <span class="eyebrow">Launch Behavior</span>
          <h3>运行配置自动进入内核 WebUI</h3>
          <p>${state.coreAutoOpen.enabled ? "已开启。管理面板启动后会先检查内核/API，正常时显示加载过渡并自动进入内核 WebUI；返回动作可退出内核 WebUI。" : "默认关闭。开启后只在内核和 Clash API 正常时自动跳转，异常时会留在管理页。"}</p>
        </div>
        <button class="toggle ${state.coreAutoOpen.enabled ? "on" : ""}" data-auto-core-toggle>
          ${state.coreAutoOpen.enabled ? "已开启" : "开启自动进入"}
        </button>
      </div>
      <form class="restart-form" data-auto-core-form>
        <label>
          <span>默认内核面板</span>
          <select name="target">
            <option value="metacubex" ${state.coreAutoOpen.target === "metacubex" ? "selected" : ""}>Meta Cube X</option>
            <option value="yacd" ${state.coreAutoOpen.target === "yacd" ? "selected" : ""}>Yacd</option>
            <option value="zashboard" ${state.coreAutoOpen.target === "zashboard" ? "selected" : ""}>zashboard</option>
          </select>
        </label>
        <button type="submit">${icon("Save", 17)}保存</button>
      </form>
    </section>
  `;
}

function commandFeedback(): string {
  const message = state.commandNotice || (state.hasKsu ? "命令会在点击后立即进入队列，执行结果显示在输出页。" : "本地预览模式会显示可复制命令，不执行 root 操作。");
  const phaseLabel = {
    idle: "空闲",
    accepted: "已接收",
    queued: "排队",
    running: "执行中",
    done: "完成",
    error: "失败"
  }[state.commandPhase];
  const detail = state.commandQueueDepth > 0
    ? `队列中 ${state.commandQueueDepth} 个任务`
    : state.activeTask
      ? state.activeTask
      : "无等待任务";

  return `
    <section class="command-feedback ${state.commandPhase}">
      <div>
        <span>${icon(state.commandPhase === "error" ? "Ban" : state.commandPhase === "running" ? "Activity" : "Terminal", 17)}</span>
        <div>
          <small>${phaseLabel}</small>
          <strong>${escapeHtml(message)}</strong>
        </div>
      </div>
      <code>${escapeHtml(detail)}</code>
    </section>
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

function blockRuleList(items: string[]): string {
  if (items.length === 0) {
    return `<div class="empty">暂无社区规则</div>`;
  }

  return items
    .slice(0, 160)
    .map(
      (rule) => `
        <div class="app-row">
          <span>${escapeHtml(rule)}</span>
          <button class="icon-button" data-allow-block-rule="${escapeHtml(rule)}" title="本地排除">${icon("X", 16)}</button>
        </div>
      `
    )
    .join("");
}

function localAllowList(items: string[]): string {
  if (items.length === 0) {
    return `<div class="empty">暂无本地排除</div>`;
  }

  return items
    .slice(0, 80)
    .map(
      (rule) => `
        <div class="app-row">
          <span>${escapeHtml(rule)}</span>
          <button class="icon-button" data-unallow-block-rule="${escapeHtml(rule)}" title="恢复阻断">${icon("Plus", 16)}</button>
        </div>
      `
    )
    .join("");
}

function blockIssueUrl(): string {
  const additions = state.blocklist.manual.map((domain) => `+ DOMAIN-SUFFIX,${domain}`);
  const removals = state.blocklist.allowRules.map((rule) => `- ${rule}`);
  const diff = [
    "--- remote ban.yaml",
    "+++ requested ban.yaml",
    ...removals,
    ...additions
  ].join("\n");
  const body = [
    "### MagicNet 联 ban 黑名单变更请求",
    "",
    "请人工审核以下远程社区库变更。设备本地已通过 MagicNet 面板临时应用。",
    "",
    "```diff",
    diff,
    "```",
    "",
    "### 来源",
    "",
    `- 当前社区库 URL: ${state.blocklist.url}`,
    "- 请确认域名归属、误杀风险和安全影响后再合并。"
  ].join("\n");
  const params = new URLSearchParams({
    title: "联 ban 黑名单变更请求",
    body
  });
  return `${REPO}/issues/new?${params.toString()}`;
}

function webuiAdaptIssueUrl(panel?: WebuiPanel): string {
  const body = [
    "### 内核 WebUI 适配申请",
    "",
    `- 面板名称: ${panel?.name || ""}`,
    `- 面板类型: ${panel?.kind === "local" ? "本地面板" : "在线面板"}`,
    `- 在线入口 URL: ${panel?.url || ""}`,
    `- 本地下载 URL: ${panel?.downloadUrl || ""}`,
    "",
    "### 面板元数据",
    "",
    "```json",
    panel?.metadata || "{\n  \"homepage\": \"\",\n  \"description\": \"\",\n  \"features\": []\n}",
    "```",
    "",
    "### 审核要求",
    "",
    "- 请人工确认面板来源、授权、兼容 Clash API 的程度和移动端可用性。",
    "- 审核通过后可内置到 MagicNet 的内核 WebUI 选择菜单。"
  ].join("\n");
  const params = new URLSearchParams({
    title: `申请适配内核 WebUI：${panel?.name || "新面板"}`,
    body
  });
  return `${REPO}/issues/new?${params.toString()}`;
}

function redactConfigLine(line: string): string {
  let next = line;
  next = next.replace(/https?:\/\/[^\s"'<>]+/gi, "<redacted-url>");
  next = next.replace(/\b(bearer|token|secret|password|passwd|apikey|api_key|key)\b(\s*[:=]\s*)(["']?)[^"',\s}]+/gi, "$1$2$3<redacted>");
  next = next.replace(/(["']?(?:url|download-url|subscription|proxy-provider)["']?\s*[:=]\s*)(["']?)[^"',\s}]+/gi, "$1$2<redacted>");
  return next;
}

function diffLines(before: string, after: string, maxLines = 220): string[] {
  const oldLines = before.split(/\r?\n/);
  const newLines = after.split(/\r?\n/);
  const rows: string[] = [];
  const max = Math.max(oldLines.length, newLines.length);
  for (let index = 0; index < max; index += 1) {
    const oldLine = oldLines[index] ?? "";
    const newLine = newLines[index] ?? "";
    if (oldLine === newLine) continue;
    rows.push(`@@ line ${index + 1} @@`);
    if (oldLines[index] !== undefined) rows.push(`- ${redactConfigLine(oldLine)}`);
    if (newLines[index] !== undefined) rows.push(`+ ${redactConfigLine(newLine)}`);
    if (rows.length >= maxLines) {
      rows.push(`... diff too large, truncated at ${maxLines} lines ...`);
      break;
    }
  }
  return rows.length ? rows : ["# no diff"];
}

function configDiffIssueUrl(): string {
  const target = configEditorLabel(state.configEditor.target);
  const diff = diffLines(state.configEditor.originalText, state.configEditor.text).join("\n");
  const body = [
    "### MagicNet 配置变更建议",
    "",
    "请放心，已经过滤敏感信息，不会将您的订阅上传，但是还是建议你在确认创建之前检查一遍。",
    "",
    `- 配置目标: ${target}`,
    `- 文件路径: ${state.configEditor.path || configEditorPath(state.configEditor.target)}`,
    "",
    "```diff",
    diff,
    "```",
    "",
    "### 说明",
    "",
    "- 这是从 MagicNet 管理面板生成的脱敏配置 diff。",
    "- 请维护者人工判断是否适合合入源码仓库默认配置或脚本逻辑。"
  ].join("\n");
  const params = new URLSearchParams({
    title: `配置变更建议：${target}`,
    body
  });
  return `${REPO}/issues/new?${params.toString()}`;
}

function blocklistPanel(): string {
  const communityCount = state.blocklist.communityRules.length || state.blocklist.communityDomains.length;
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
        <button class="command-secondary" data-open-block-issue>${icon("Github", 17)}创建变更 Issue</button>
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
            <p>当前缓存 ${communityCount} 条；点 X 会加入本地排除并立即从内核阻断规则移除。</p>
          </div>
        </div>
        <div class="list-panel flush community-list">${blockRuleList(state.blocklist.communityRules.length ? state.blocklist.communityRules : state.blocklist.communityDomains.map((domain) => `DOMAIN-SUFFIX,${domain}`))}</div>
      </section>
      <section class="capture-card wide">
        <div class="sub-head">
          <div>
            <h3>本地排除</h3>
            <p>这些规则暂时不参与阻断。要改远程社区库，请创建变更 Issue 交给人工审核。</p>
          </div>
        </div>
        <div class="list-panel flush">${localAllowList(state.blocklist.allowRules)}</div>
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

function subscriptionsSection(): string {
  const configured = Number(Boolean(state.subscriptions.singBox)) + Number(Boolean(state.subscriptions.mihomo));
  const singBoxValue = state.subscriptions.singBoxUrls.join("\n");
  const mihomoCards = state.subscriptions.mihomoProviders.length
    ? state.subscriptions.mihomoProviders
      .map((provider) => `
        <div class="sub-card">
          <div class="sub-head">
            <div>
              <h3>mihomo / ${escapeHtml(provider.name)}</h3>
              <p>对应 config.yaml 的 proxy-provider：${escapeHtml(provider.name)}</p>
            </div>
            <button class="icon-button" data-copy-sub="mihomo:${escapeHtml(provider.name)}" title="复制订阅链接">${icon("Copy", 16)}</button>
          </div>
          <textarea data-mihomo-provider="${escapeHtml(provider.name)}" spellcheck="false" placeholder="https://example.com/sub">${escapeHtml(provider.url)}</textarea>
          <div class="sub-actions">
            <button data-save-mihomo-provider="${escapeHtml(provider.name)}">${icon("Save", 17)}保存 provider</button>
            <code>${MODULE_DIR}/.config/mihomo/config.yaml</code>
          </div>
        </div>
      `)
      .join("")
    : `<div class="sub-card"><div class="picker-empty"><strong>未读取到 mihomo provider</strong><span>请确认 config.yaml 中存在 proxy-providers。</span></div></div>`;
  const subscriptionCards = `
    <div class="sub-card">
      <div class="sub-head">
        <div>
          <h3>sing-box 多订阅</h3>
          <p>一行一个订阅链接。sing-box 更新时会逐条下载并合并可用节点。</p>
        </div>
        <button class="icon-button" data-copy-sub="sing-box" title="复制订阅链接">${icon("Copy", 16)}</button>
      </div>
      <textarea data-singbox-subs spellcheck="false" placeholder="https://example.com/sub-a\nhttps://example.com/sub-b">${escapeHtml(singBoxValue)}</textarea>
      <div class="sub-actions">
        <button data-save-singbox-subs>${icon("Save", 17)}保存 sing-box 多订阅</button>
        <button data-copy-path="sing-box">${icon("Copy", 17)}复制路径</button>
        <code>${MODULE_DIR}/.config/sing-box/subscription.url</code>
      </div>
    </div>
    ${mihomoCards}
  `;
  return `
    <div class="section-intro">
      <div>
        <span class="eyebrow">Subscriptions & Backup</span>
        <h3>订阅链接与配置备份</h3>
        <p>已保存订阅 ${configured}/2。备份会包含订阅链接、分应用名单、黑名单、本地排除、抓包、免费节点过滤和 MCP 设置。</p>
      </div>
      <div class="section-actions">
        <button class="command-secondary" data-refresh-subs>${icon("RefreshCw", 17)}刷新状态</button>
        <button class="command-primary" data-run="sub update-all">${icon("DownloadCloud", 17)}用已保存订阅更新</button>
      </div>
    </div>
    <div class="sub-grid">
      <div class="sub-card policy-card ${state.subscriptions.freeFilter ? "enabled" : ""}">
        <div class="sub-head">
          <div>
            <h3>过滤免费节点</h3>
            <p>开启后 mihomo 策略组只使用 premium provider，保留免费 provider 配置但不参与默认选择。</p>
          </div>
          <button class="toggle ${state.subscriptions.freeFilter ? "on" : ""}" data-filter-free-toggle>
            ${state.subscriptions.freeFilter ? "已开启" : "已关闭"}
          </button>
        </div>
        <div class="policy-strip">
          <span>${icon("ShieldCheck", 16)}优先稳定节点</span>
          <span>${icon("Settings", 16)}不删除订阅</span>
          <span>${icon("FileText", 16)}状态进入备份</span>
        </div>
      </div>
      ${subscriptionCards}
      <div class="sub-card">
        <div class="sub-head">
          <div>
            <h3>导出配置</h3>
            <p>安全密码可留空。导出结果是 base64 文本，会自动复制到剪贴板。</p>
          </div>
        </div>
        <input class="package-search" data-backup-password value="${escapeHtml(state.backupPassword)}" type="password" placeholder="安全密码（可留空）" autocomplete="new-password" />
        <div class="sub-actions">
          <button data-export-backup>${icon("Save", 17)}导出配置</button>
          <button data-copy-backup>${icon("Copy", 17)}复制备份</button>
        </div>
        <textarea readonly spellcheck="false" placeholder="导出的 base64 备份会显示在这里">${escapeHtml(state.backupPayload)}</textarea>
      </div>
      <div class="sub-card">
        <div class="sub-head">
          <div>
            <h3>恢复配置</h3>
            <p>粘贴 base64 备份内容。若导出时设置了安全密码，恢复时必须填写相同密码。</p>
          </div>
        </div>
        <input class="package-search" data-restore-password value="${escapeHtml(state.restorePassword)}" type="password" placeholder="安全密码（可留空）" autocomplete="new-password" />
        <textarea data-restore-payload spellcheck="false" placeholder="粘贴 base64 备份内容">${escapeHtml(state.restorePayload)}</textarea>
        <div class="sub-actions">
          <button data-restore-backup>${icon("DownloadCloud", 17)}恢复配置</button>
        </div>
      </div>
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

function webuiConfigPanel(): string {
  const panels = state.webuiPanels.length
    ? state.webuiPanels.map((panel) => `
      <div class="webui-panel-row">
        <div>
          <strong>${escapeHtml(panel.name)}</strong>
          <span>${panel.kind === "local" ? "本地面板" : "在线面板"}</span>
          <code>${escapeHtml(panel.kind === "local" ? panel.downloadUrl : panel.url)}</code>
        </div>
        ${panel.kind === "local" ? `<button class="mini-button" data-install-webui="${escapeHtml(panel.id)}">${icon("DownloadCloud", 15)}安装</button>` : ""}
        <button class="mini-button" data-open-custom-webui="${escapeHtml(panel.id)}">${icon("ExternalLink", 15)}打开</button>
        <button class="mini-button" data-adapt-webui="${escapeHtml(panel.id)}">${icon("Github", 15)}申请</button>
        <button class="mini-button danger" data-remove-webui="${escapeHtml(panel.id)}">${icon("X", 15)}移除</button>
      </div>
    `).join("")
    : `<div class="picker-empty"><strong>还没有自定义内核 WebUI</strong><span>添加在线面板或本地面板后，会出现在“选择内核 WebUI”菜单里。</span></div>`;

  return `
    <div class="section-intro">
      <div>
        <span class="eyebrow">Core WebUI Catalog</span>
        <h3>内核 WebUI 配置</h3>
        <p>在线面板直接打开外部入口；本地面板会下载 zip、安装到模块目录，并复用当前 Clash API 入口。适配申请会用系统浏览器创建 GitHub Issue。</p>
      </div>
      <button class="command-secondary" data-adapt-webui>${icon("Github", 17)}申请适配新面板</button>
    </div>
    <form class="webui-config-form" data-webui-panel-form>
      <label>
        <span>面板类型</span>
        <select name="kind">
          <option value="online" ${state.webuiPanelForm.kind === "online" ? "selected" : ""}>在线面板</option>
          <option value="local" ${state.webuiPanelForm.kind === "local" ? "selected" : ""}>本地面板</option>
        </select>
      </label>
      <label>
        <span>面板名字</span>
        <input name="name" value="${escapeHtml(state.webuiPanelForm.name)}" placeholder="例如：Meta Cube X" />
      </label>
      <label>
        <span>在线入口 URL</span>
        <input name="url" value="${escapeHtml(state.webuiPanelForm.url)}" placeholder="https://example.com/?hostname=127.0.0.1&port=9090" />
      </label>
      <label>
        <span>本地下载 URL</span>
        <input name="downloadUrl" value="${escapeHtml(state.webuiPanelForm.downloadUrl)}" placeholder="https://github.com/owner/panel/releases/latest/download/dist.zip" />
      </label>
      <label class="wide">
        <span>面板元数据 JSON</span>
        <textarea name="metadata" spellcheck="false">${escapeHtml(state.webuiPanelForm.metadata)}</textarea>
      </label>
      <button type="submit">${icon("Save", 17)}保存面板</button>
    </form>
    <div class="webui-panel-list">
      ${panels}
    </div>
  `;
}

function configEditorPanel(): string {
  const editor = state.configEditor;
  const targetLabel = configEditorLabel(editor.target);
  const saveState = editor.lastCheck === "ok"
    ? "上次校验通过并已保存"
    : editor.lastCheck === "error"
      ? "上次校验失败，真实配置未被替换"
      : editor.dirty
        ? "有未保存修改"
        : editor.loadedTarget
          ? "已加载"
          : "尚未加载";
  return `
    <div class="section-intro config-intro">
      <div>
        <span class="eyebrow">Validated Config Editor</span>
        <h3>配置编辑器</h3>
        <p>只编辑内核真实配置文件。保存时先调用模块 CLI 和内核自带检查命令，校验失败不会替换原文件。</p>
      </div>
      <div class="section-actions">
        <button class="command-secondary" data-load-config>${icon("RefreshCw", 17)}加载配置</button>
        <button class="command-primary" data-save-config>${icon("Save", 17)}校验并保存</button>
        <button class="command-secondary" data-config-diff-issue>${icon("Github", 17)}创建 Diff Issue</button>
      </div>
    </div>
    <section class="config-editor-shell">
      <div class="config-editor-toolbar">
        <div class="segmented">
          <button class="${editor.target === "mihomo" ? "selected" : ""}" data-config-target="mihomo">mihomo</button>
          <button class="${editor.target === "sing-box" ? "selected" : ""}" data-config-target="sing-box">sing-box</button>
        </div>
        <div class="config-status ${editor.lastCheck}">
          <span>${icon(editor.lastCheck === "error" ? "Ban" : editor.lastCheck === "ok" ? "ShieldCheck" : "FileText", 16)}</span>
          <strong>${escapeHtml(targetLabel)}</strong>
          <small>${escapeHtml(saveState)}</small>
        </div>
        <button class="command-secondary" data-copy-config-path>${icon("Copy", 16)}复制路径</button>
      </div>
      <div class="config-path-row">
        <span>文件路径</span>
        <code>${escapeHtml(editor.path || configEditorPath(editor.target))}</code>
      </div>
      <textarea class="config-editor-textarea" data-config-editor spellcheck="false" placeholder="点击“加载配置”读取 ${escapeHtml(targetLabel)}">${escapeHtml(editor.text)}</textarea>
      <div class="config-editor-foot">
        <span>${editor.text ? `${editor.text.length} 字符` : "未加载内容"}</span>
        <span>保存流程：base64 传输 -> 临时文件 -> 内核校验 -> 原子替换 -> 应用运行时覆盖。Diff Issue 会先脱敏 URL/token/password。</span>
      </div>
    </section>
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
      <button class="command-primary ${state.activeTask === "service restart" ? "running" : ""}" data-run="service restart">
        ${icon("RotateCcw", 20)}
        <span>${state.activeTask === "service restart" ? "重启中" : "重启内核"}</span>
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
      <button class="command-secondary ${state.activeTask === "sub update-all" ? "running" : ""}" data-run="sub update-all">
        ${icon("DownloadCloud", 18)}
        <span>${state.activeTask === "sub update-all" ? "更新中" : "更新订阅"}</span>
      </button>
      <button class="command-secondary ${state.activeTask === "刷新面板" ? "running" : ""}" data-action="refresh-all">
        ${icon("RefreshCw", 18)}
        <span>${state.activeTask === "刷新面板" ? "刷新中" : "刷新面板"}</span>
      </button>
    </div>
  `;
}

function coreUiButton(className: string): string {
  const customButtons = state.webuiPanels
    .map((panel) => `<button data-open-core-ui-target="custom:${escapeHtml(panel.id)}">${icon(panel.kind === "local" ? "DownloadCloud" : "ExternalLink", 16)}${escapeHtml(panel.name)}</button>`)
    .join("");
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
          ${customButtons}
          <button data-adapt-webui>${icon("Github", 16)}申请适配面板</button>
        </div>
      ` : ""}
    </span>
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
  const task = state.commandNotice || (state.activeTask ? `执行中：${state.activeTask}` : "空闲");

  return `
    <section class="status-drawer ${state.statusDrawerOpen ? "open" : ""}" data-status-drawer>
      <button class="status-drawer-handle" data-status-drawer-toggle data-status-drawer-handle aria-expanded="${state.statusDrawerOpen}">
        <span class="${`status-dot ${state.status}`}"></span>
        <div class="drawer-title">
          <small>MagicNet Status</small>
          <strong>${escapeHtml(state.statusText)}</strong>
        </div>
        <div class="drawer-chips" data-drawer-scroll>
          <span>${icon("Server", 15)}<b>${escapeHtml(core)}</b></span>
          <span>${icon(state.busy ? "Activity" : "Terminal", 15)}<b>${escapeHtml(task)}</b></span>
        </div>
        <span class="drawer-chevron">${icon(state.statusDrawerOpen ? "ChevronUp" : "ChevronDown", 18)}</span>
      </button>
      ${state.statusDrawerOpen ? `
        <div class="status-drawer-panel" data-drawer-scroll>
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
            <span>Queue <code>${escapeHtml(state.commandQueueDepth ? `${state.commandQueueDepth} waiting` : state.commandPhase)}</code></span>
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

function coreLaunchOverlay(): string {
  if (!state.coreLaunch.active) return "";
  return `
    <div class="core-launch-overlay" role="status" aria-live="polite">
      <div class="core-launch-panel">
        <div class="core-launch-spinner" aria-hidden="true"></div>
        <div>
          <span class="eyebrow">Opening Core WebUI</span>
          <h3>正在进入 ${escapeHtml(state.coreLaunch.label)}</h3>
          <p>正在确认本地 Clash API 并加载内核面板。第一次打开可能需要几秒，请耐心等待。</p>
          <code>${escapeHtml(state.coreLaunch.url)}</code>
        </div>
      </div>
    </div>
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
  if (state.activeTab === "control") await refreshMcp();
  if (state.activeTab === "config") await refreshConfigEditorPath();
  if (state.activeTab === "health" && state.health.length === 0) await refreshHealth();
  if (state.activeTab === "topology" && !state.topology) await refreshTopology();
  if (state.activeTab === "apps") await refreshApps();
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
    const packageNames = kernelsu.listPackages("user").slice(0, PACKAGE_SCAN_LIMIT);
    state.output = `已读取 ${packageNames.length} 个用户应用包名，正在分批读取名称。图标使用 ksu://icon 原生协议懒加载。`;
    render();
    await nextFrame();
    const packageInfo: PackageInfo[] = [];
    const batchSize = 40;
    for (let index = 0; index < packageNames.length; index += batchSize) {
      const batch = packageNames.slice(index, index + batchSize);
      packageInfo.push(...kernelsu.getPackagesInfo(batch));
      state.output = `正在读取应用详情：${Math.min(index + batch.length, packageNames.length)}/${packageNames.length}`;
      render();
      await nextFrame();
    }
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
          <button class="ghost-link whisper-link" data-open-external-url="${AUTHOR_WHISPER_URL}" data-open-external-label="悄悄话">${icon("MessageCircle", 16)}和作者说悄悄话</button>
          <button class="ghost-link" data-open-external-url="${escapeHtml(REPO)}" data-open-external-label="GitHub">${icon("Github", 16)}GitHub</button>
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
      ${coreLaunchOverlay()}
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

  const statusDrawerHandle = document.querySelector<HTMLElement>("[data-status-drawer-handle]");
  if (statusDrawerHandle) {
    let startY = 0;
    statusDrawerHandle.addEventListener("touchstart", (event) => {
      if ((event.target as HTMLElement | null)?.closest("[data-drawer-scroll]")) return;
      startY = event.touches[0].clientY;
    }, { passive: true });
    statusDrawerHandle.addEventListener("touchend", (event) => {
      if ((event.target as HTMLElement | null)?.closest("[data-drawer-scroll]")) return;
      const dy = event.changedTouches[0].clientY - startY;
      if (dy > 64 && !state.statusDrawerOpen) {
        state.statusDrawerOpen = true;
        render();
      }
      if (dy < -120 && state.statusDrawerOpen) {
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

  document.querySelectorAll<HTMLButtonElement>("[data-transparent-mode]").forEach((button) => {
    button.addEventListener("click", async () => {
      const mode = button.dataset.transparentMode === "tproxy" ? "tproxy" : "tun";
      if (mode === state.runtime.transparentMode) return;
      await runCli(`transparent set ${mode}`, { label: `切换透明模式到 ${mode}` });
      await refreshStatus(true);
      render();
    });
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

  document.querySelector<HTMLButtonElement>("[data-mcp-toggle]")?.addEventListener("click", async () => {
    const running = state.mcp.pid && state.mcp.pid !== "stopped";
    await runCli(running ? "mcp disable" : "mcp enable", { label: running ? "关闭 MCP" : "开启 MCP" });
    await refreshMcp(true);
    render();
  });

  document.querySelector<HTMLButtonElement>("[data-refresh-mcp]")?.addEventListener("click", () => refreshMcp());

  document.querySelector<HTMLButtonElement>("[data-auto-core-toggle]")?.addEventListener("click", () => {
    state.coreAutoOpen.enabled = !state.coreAutoOpen.enabled;
    state.coreAutoOpen.attempted = false;
    saveCoreAutoOpen();
    state.output = state.coreAutoOpen.enabled
      ? "已开启自动进入内核 WebUI。下次打开管理面板时，会在内核/API 正常后自动跳转；返回动作可退出内核 WebUI。"
      : "已关闭自动进入内核 WebUI。";
    render();
  });

  document.querySelector<HTMLFormElement>("[data-auto-core-form]")?.addEventListener("submit", (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const target = String(form.get("target") || "metacubex");
    state.coreAutoOpen.target = target === "yacd" || target === "zashboard" ? target : "metacubex";
    state.coreAutoOpen.attempted = false;
    saveCoreAutoOpen();
    state.output = `已保存默认内核面板：${coreUiTargetLabel(state.coreAutoOpen.target)}。`;
    render();
  });

  document.querySelector<HTMLButtonElement>("[data-copy-mcp]")?.addEventListener("click", async () => {
    const url = state.mcp.url || `http://${state.mcp.bind}:${state.mcp.port}/mcp`;
    await navigator.clipboard?.writeText(url);
    state.output = `已复制 MCP URL：\n${url}\n\n如需从电脑访问，请使用 ADB 端口转发：adb forward tcp:${state.mcp.port} tcp:${state.mcp.port}`;
    if (state.hasKsu) kernelsu.toast?.("MCP URL 已复制");
    render();
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

  document.querySelectorAll<HTMLButtonElement>("[data-config-target]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = button.dataset.configTarget === "sing-box" ? "sing-box" : "mihomo";
      if (state.configEditor.dirty && state.configEditor.target !== target) {
        state.output = "当前配置有未保存修改。请先保存，或重新加载后再切换目标。";
        render();
        return;
      }
      state.configEditor.target = target;
      state.configEditor.text = state.configEditor.loadedTarget === target ? state.configEditor.text : "";
      state.configEditor.lastCheck = "idle";
      state.configEditor.path = configEditorPath(target);
      await refreshConfigEditorPath(true);
      render();
    });
  });

  document.querySelector<HTMLTextAreaElement>("[data-config-editor]")?.addEventListener("input", (event) => {
    state.configEditor.text = event.currentTarget.value;
    state.configEditor.dirty = true;
    state.configEditor.lastCheck = "idle";
  });

  document.querySelector<HTMLButtonElement>("[data-load-config]")?.addEventListener("click", () => loadConfigEditor());

  document.querySelector<HTMLButtonElement>("[data-save-config]")?.addEventListener("click", () => saveConfigEditor());

  document.querySelector<HTMLButtonElement>("[data-config-diff-issue]")?.addEventListener("click", async () => {
    if (!state.configEditor.text.trim()) {
      state.output = "请先加载或填写配置，再创建 Diff Issue。";
      render();
      return;
    }
    state.output = "请放心，已经过滤敏感信息，不会将您的订阅上传，但是还是建议你在确认创建之前检查一遍。\n\n正在打开系统浏览器创建 GitHub Issue。";
    render();
    await openExternalUrl(configDiffIssueUrl(), "配置 Diff Issue");
  });

  document.querySelector<HTMLButtonElement>("[data-copy-config-path]")?.addEventListener("click", async () => {
    const path = state.configEditor.path || configEditorPath(state.configEditor.target);
    await navigator.clipboard?.writeText(path);
    state.output = `已复制配置路径：\n${path}`;
    if (state.hasKsu) kernelsu.toast?.("配置路径已复制");
    render();
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
      if (target === "metacubex" || target === "yacd" || target === "zashboard" || target?.startsWith("custom:")) {
        void openCoreUiTarget(target as CoreOpenTarget);
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

  document.querySelector<HTMLButtonElement>("[data-refresh-block]")?.addEventListener("click", () => refreshBlocklist());

  document.querySelector<HTMLFormElement>("[data-webui-panel-form]")?.addEventListener("submit", (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const metadata = String(form.get("metadata") || "{}");
    try {
      JSON.parse(metadata);
    } catch {
      state.output = "面板元数据必须是合法 JSON。";
      render();
      return;
    }
    const panel = normalizeWebuiPanel({
      kind: String(form.get("kind") || "online") === "local" ? "local" : "online",
      name: String(form.get("name") || ""),
      url: String(form.get("url") || ""),
      downloadUrl: String(form.get("downloadUrl") || ""),
      metadata
    });
    if (!panel) {
      state.output = "面板配置不完整：在线面板需要入口 URL，本地面板需要下载 URL。";
      render();
      return;
    }
    state.webuiPanels = [...state.webuiPanels, panel];
    state.webuiPanelForm = emptyWebuiPanel();
    saveCustomWebuiPanels();
    state.output = `已保存内核 WebUI 面板：${panel.name}`;
    render();
  });

  document.querySelectorAll<HTMLButtonElement>("[data-open-custom-webui]").forEach((button) => {
    button.addEventListener("click", () => {
      const id = button.dataset.openCustomWebui || "";
      if (id) void openCoreUiTarget(`custom:${id}`);
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-install-webui]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.installWebui || "";
      const panel = state.webuiPanels.find((item) => item.id === id && item.kind === "local");
      if (!panel) return;
      await runCli(`webui install-local ${shellQuote(panel.downloadUrl)} ${shellQuote(panel.name)}`, { label: `安装 ${panel.name}` });
      await refreshStatus(true);
      state.output += `\n\n安装完成后请点“选择内核 WebUI”里的 zashboard / 本地入口查看。`;
      render();
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-remove-webui]").forEach((button) => {
    button.addEventListener("click", () => {
      const id = button.dataset.removeWebui || "";
      state.webuiPanels = state.webuiPanels.filter((panel) => panel.id !== id);
      saveCustomWebuiPanels();
      state.output = "已移除自定义内核 WebUI 面板。";
      render();
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-adapt-webui]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.adaptWebui || "";
      const panel = state.webuiPanels.find((item) => item.id === id);
      await openExternalUrl(webuiAdaptIssueUrl(panel), "WebUI 适配 Issue");
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-health-run]").forEach((button) => {
    button.addEventListener("click", () => refreshHealth());
  });

  document.querySelectorAll<HTMLButtonElement>("[data-pingtest]").forEach((button) => {
    button.addEventListener("click", () => refreshPingtest());
  });

  document.querySelectorAll<HTMLButtonElement>("[data-health-detail]").forEach((button) => {
    button.addEventListener("click", async () => {
      const key = button.dataset.healthDetail || "";
      const item = state.health.find((entry) => entry.key === key);
      const text = healthExplainText(key, item?.status || "info", item?.detail || "");
      await navigator.clipboard?.writeText(text);
      state.output = `${text}\n\n已复制这段解说。`;
      if (state.hasKsu) kernelsu.toast?.("诊断详情已复制");
      render();
    });
  });

  document.querySelector<HTMLButtonElement>("[data-refresh-topology]")?.addEventListener("click", () => refreshTopology());
  document.querySelector<HTMLButtonElement>("[data-refresh-sysroute]")?.addEventListener("click", () => refreshSysroute());

  document.querySelectorAll<SVGGElement>("[data-topology-node]").forEach((node) => {
    node.addEventListener("click", () => {
      state.topologyFocus = node.dataset.topologyNode || "tun";
      render();
    });
  });

  document.querySelector<HTMLButtonElement>("[data-copy-topology-explain]")?.addEventListener("click", async () => {
    const focus = topologyConcepts[state.topologyFocus] || topologyConcepts.tun;
    const text = `${focus.title}\n\n${focus.body}`;
    await navigator.clipboard?.writeText(text);
    state.output = `${text}\n\n已复制拓扑解说。`;
    if (state.hasKsu) kernelsu.toast?.("拓扑解说已复制");
    render();
  });

  document.querySelector<HTMLFormElement>("[data-sysroute-rule-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    state.sysroute.rulePriority = String(form.get("priority") || "").trim();
    state.sysroute.ruleTable = String(form.get("table") || "").trim();
    if (!/^[0-9]+$/.test(state.sysroute.rulePriority) || !/^[A-Za-z0-9_.-]+$/.test(state.sysroute.ruleTable)) {
      state.output = "ip rule 参数格式不对。priority 必须是数字，table 只能是简单表名或数字。";
      render();
      return;
    }
    await runCli(`sysroute add-rule ${shellQuote(state.sysroute.rulePriority)} ${shellQuote(state.sysroute.ruleTable)}`, { label: "添加 ip rule" });
    await refreshSysroute(true);
    render();
  });

  document.querySelector<HTMLButtonElement>("[data-sysroute-del-rule]")?.addEventListener("click", async () => {
    if (!/^[0-9]+$/.test(state.sysroute.rulePriority)) {
      state.output = "要删除的 priority 必须是数字。";
      render();
      return;
    }
    await runCli(`sysroute del-rule ${shellQuote(state.sysroute.rulePriority)}`, { label: "删除 ip rule" });
    await refreshSysroute(true);
    render();
  });

  document.querySelector<HTMLFormElement>("[data-sysroute-route-form]")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    state.sysroute.routeTable = String(form.get("table") || "").trim();
    state.sysroute.routeDest = String(form.get("dest") || "").trim();
    state.sysroute.routeDev = String(form.get("dev") || "").trim();
    state.sysroute.routeVia = String(form.get("via") || "").trim();
    const token = /^[A-Za-z0-9_./:-]+$/;
    if (!token.test(state.sysroute.routeTable) || !token.test(state.sysroute.routeDest) || !token.test(state.sysroute.routeDev) || (state.sysroute.routeVia && !token.test(state.sysroute.routeVia))) {
      state.output = "route 参数格式不对。请只填写 table、dest、dev、via 这类简单 token。";
      render();
      return;
    }
    await runCli(`sysroute add-route ${shellQuote(state.sysroute.routeTable)} ${shellQuote(state.sysroute.routeDest)} ${shellQuote(state.sysroute.routeDev)} ${shellQuote(state.sysroute.routeVia || "-")}`, { label: "添加 ip route" });
    await refreshSysroute(true);
    render();
  });

  document.querySelector<HTMLButtonElement>("[data-sysroute-del-route]")?.addEventListener("click", async () => {
    if (!state.sysroute.routeTable || !state.sysroute.routeDest) {
      state.output = "删除 route 需要填写 table 和 dest。";
      render();
      return;
    }
    await runCli(`sysroute del-route ${shellQuote(state.sysroute.routeTable)} ${shellQuote(state.sysroute.routeDest)}`, { label: "删除 ip route" });
    await refreshSysroute(true);
    render();
  });

  document.querySelectorAll<HTMLButtonElement>("[data-support-bundle]").forEach((button) => {
    button.addEventListener("click", () => generateDiagnosticContext());
  });

  document.querySelectorAll<HTMLButtonElement>("[data-ask-ai]").forEach((button) => {
    button.addEventListener("click", async () => {
      const key = button.dataset.askAi as AiAssistant | undefined;
      const target = aiAssistants.find((item) => item.key === key);
      if (!target) return;
      await generateDiagnosticContext(`询问 ${target.label}`);
      state.output = `诊断上下文已复制。\n\n正在打开 ${target.label}：\n${target.url}\n\n进入聊天后直接粘贴发送。`;
      render();
      await openExternalUrl(target.url, target.label);
    });
  });

  document.querySelector<HTMLButtonElement>("[data-open-block-issue]")?.addEventListener("click", async () => {
    await openExternalUrl(blockIssueUrl(), "GitHub Issue");
  });

  document.querySelectorAll<HTMLButtonElement>("[data-open-external-url]").forEach((button) => {
    button.addEventListener("click", async () => {
      const url = button.dataset.openExternalUrl;
      if (!url) return;
      await openExternalUrl(url, button.dataset.openExternalLabel || "外部链接");
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-copy-core-entries]").forEach((button) => {
    button.addEventListener("click", () => copyCoreEntries());
  });

  document.querySelectorAll<HTMLButtonElement>("[data-special-action]").forEach((button) => {
    button.addEventListener("click", async () => {
      const action = button.dataset.specialAction;
      const label = button.querySelector("strong")?.textContent?.trim() || button.textContent?.trim() || "模块操作";
      if (action === "open-core") {
        beginInstantAction(label);
        state.coreMenuOpen = true;
        finishInstantAction(label, "已打开内核 WebUI 选择菜单", "已打开内核 WebUI 选择菜单。请选择 Meta Cube X、Yacd 或 zashboard。");
      } else if (action === "copy-core") {
        await copyCoreEntries(label);
      } else if (action === "copy-support") {
        await generateDiagnosticContext(label);
      }
    });
  });

  document.querySelector<HTMLButtonElement>("[data-save-singbox-subs]")?.addEventListener("click", async () => {
    const input = document.querySelector<HTMLTextAreaElement>("[data-singbox-subs]");
    const lines = (input?.value || "")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    if (lines.some((line) => !/^https?:\/\/\S+$/i.test(line))) {
      state.output = "sing-box 订阅列表里有无效 URL，必须一行一个 http(s) 链接。";
      render();
      return;
    }
    const encoded = bytesToBase64(new TextEncoder().encode(`${lines.join("\n")}\n`));
    await runCli(`sub set-file sing-box ${shellQuote(encoded)}`, { quiet: false });
    await refreshSubscriptions(true);
  });

  document.querySelector<HTMLButtonElement>("[data-filter-free-toggle]")?.addEventListener("click", async () => {
    const nextMode = state.subscriptions.freeFilter ? "off" : "on";
    await runCli(`sub filter-free ${nextMode}`, {
      quiet: false,
      label: nextMode === "on" ? "开启免费节点过滤" : "关闭免费节点过滤"
    });
    await refreshSubscriptions(true);
  });

  document.querySelectorAll<HTMLButtonElement>("[data-save-mihomo-provider]").forEach((button) => {
    button.addEventListener("click", async () => {
      const provider = button.dataset.saveMihomoProvider || "";
      const input = document.querySelector<HTMLTextAreaElement>(`[data-mihomo-provider="${provider}"]`);
      const value = input?.value.trim() || "";
      if (!provider || !/^https?:\/\/\S+$/i.test(value)) {
        state.output = "mihomo provider 订阅链接格式不对。";
        render();
        return;
      }
      await runCli(`sub set mihomo ${shellQuote(provider)} ${shellQuote(value)}`, { quiet: false });
      await refreshSubscriptions(true);
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-copy-sub]").forEach((button) => {
    button.addEventListener("click", async () => {
      const target = button.dataset.copySub || "sing-box";
      let value = "";
      if (target === "sing-box") {
        value = state.subscriptions.singBoxUrls.join("\n") || state.subscriptions.singBox;
      } else if (target.startsWith("mihomo:")) {
        const provider = target.slice("mihomo:".length);
        value = state.subscriptions.mihomoProviders.find((item) => item.name === provider)?.url || "";
      }
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

  document.querySelector<HTMLInputElement>("[data-backup-password]")?.addEventListener("input", (event) => {
    state.backupPassword = (event.currentTarget as HTMLInputElement).value;
  });

  document.querySelector<HTMLInputElement>("[data-restore-password]")?.addEventListener("input", (event) => {
    state.restorePassword = (event.currentTarget as HTMLInputElement).value;
  });

  document.querySelector<HTMLTextAreaElement>("[data-restore-payload]")?.addEventListener("input", (event) => {
    state.restorePayload = (event.currentTarget as HTMLTextAreaElement).value;
  });

  document.querySelector<HTMLButtonElement>("[data-export-backup]")?.addEventListener("click", () => exportBackup());

  document.querySelector<HTMLButtonElement>("[data-copy-backup]")?.addEventListener("click", async () => {
    await navigator.clipboard?.writeText(state.backupPayload);
    state.output = state.backupPayload ? "已复制配置备份。" : "当前还没有导出的配置备份。";
    if (state.hasKsu && state.backupPayload) kernelsu.toast?.("备份已复制");
    render();
  });

  document.querySelector<HTMLButtonElement>("[data-restore-backup]")?.addEventListener("click", () => restoreBackup());

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

  document.querySelectorAll<HTMLButtonElement>("[data-allow-block-rule]").forEach((button) => {
    button.addEventListener("click", async () => {
      const rule = button.dataset.allowBlockRule || "";
      if (!rule) return;
      await runCli(`block allow-rule ${shellQuote(rule)}`);
      await refreshBlocklist(true);
    });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-unallow-block-rule]").forEach((button) => {
    button.addEventListener("click", async () => {
      const rule = button.dataset.unallowBlockRule || "";
      if (!rule) return;
      await runCli(`block unallow-rule ${shellQuote(rule)}`);
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
  await maybeAutoOpenCoreUi();
}

void bootstrap();
