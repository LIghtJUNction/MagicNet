import * as kernelsu from "kernelsu";
import { computed, nextTick, reactive } from "vue";
import { AUTHOR_WHISPER_URL, CLI, CLI_TIMEOUT_MS, MODULE_DIR, REPO } from "@/constants";
import type { AppPolicy, ConfigEditorTarget, HealthItem, PackageInfo } from "@/types";
import { blockDefaults, captureDefaults, certDefaults, mcpDefaults, parseApps, parseBlock, parseCapture, parseCerts, parseHealth, parseMcp, parsePackages, parseRuntime, parseSubs, parseTailscale, runtimeDefaults, tailscaleDefaults, type SubscriptionState } from "@/composables/parsers";
import { useExternalLinks } from "@/composables/useExternalLinks";
import { bytesToBase64, compactCommand, compactOutput, execFailed, normalizeExecResult, nextFrame, shellQuote, uniqueNonEmpty, withTimeout } from "@/utils";

type Phase = "idle" | "accepted" | "queued" | "running" | "done" | "error";

const ksuBridge = (globalThis as { ksu?: { exec?: unknown } }).ksu;
const hasKsu = typeof ksuBridge?.exec === "function";
let writeQueue: Promise<unknown> = Promise.resolve();

const state = reactive({
  hasKsu,
  phase: "idle" as Phase,
  busy: false,
  task: "",
  notice: "面板已加载，所有耗时命令都会异步执行。",
  queueDepth: 0,
  lastCommand: "",
  output: hasKsu ? "正在读取 MagicNet 状态..." : "本地预览模式：真机 WebUI 才会执行 root 命令。",
  runtime: { ...runtimeDefaults },
  selectedCore: "sing-box" as "sing-box" | "mihomo",
  health: [] as HealthItem[],
  pingtest: "",
  appPolicy: { mode: "blacklist", proxy: [], bypass: [] } as AppPolicy,
  packages: [] as PackageInfo[],
  packageQuery: "",
  packageInput: "",
  blocklist: { ...blockDefaults },
  capture: { ...captureDefaults },
  certs: { ...certDefaults },
  mcp: { ...mcpDefaults },
  tailscale: { ...tailscaleDefaults },
  topology: "",
  sysroute: "",
  subscriptions: {
    singBox: "",
    singBoxUrls: [],
    mihomoProviders: []
  } as SubscriptionState,
  config: {
    target: "mihomo" as ConfigEditorTarget,
    text: "",
    path: `${MODULE_DIR}/.config/mihomo/config.yaml`,
    dirty: false,
    status: "尚未加载"
  },
  backup: {
    exportPassword: "",
    restorePassword: "",
    payload: "",
    status: "尚未导出"
  }
});

async function queued<T>(task: () => Promise<T>): Promise<T> {
  state.queueDepth += 1;
  const run = writeQueue.then(task, task).finally(() => {
    state.queueDepth = Math.max(0, state.queueDepth - 1);
  });
  writeQueue = run.catch(() => undefined);
  return run;
}

async function runShell(commandBody: string, label: string, quiet = false): Promise<string> {
  const command = `su -M -c ${shellQuote(commandBody)}`;
  const commandPreview = compactCommand(command);
  const previousTask = state.task;
  const previousNotice = state.notice;
  state.lastCommand = commandPreview;
  state.task = label;
  state.notice = quiet ? `后台执行：${label}` : `已接收：${label}`;
  if (!quiet) {
    const wasBusy = state.busy;
    state.busy = true;
    state.phase = wasBusy ? "queued" : "accepted";
    state.output = `$ ${commandPreview}\n执行中...`;
  }
  await nextTick();
  await nextFrame();

  if (!state.hasKsu) {
    state.output = `当前没有 KernelSU 执行通道。\n\n真机命令：\n${commandPreview}`;
    state.phase = "done";
    state.busy = false;
    state.task = quiet ? previousTask : "";
    if (quiet) state.notice = previousNotice;
    return state.output;
  }

  try {
    const result = await queued(async () => {
      state.phase = "running";
      state.notice = `正在执行：${label}`;
      await nextTick();
      await nextFrame();
      await nextFrame();
      return withTimeout(kernelsu.exec(command), CLI_TIMEOUT_MS, label);
    });
    const text = normalizeExecResult(result);
    if (!quiet) {
      state.phase = execFailed(text) ? "error" : "done";
      state.notice = execFailed(text) ? `失败：${label}` : `完成：${label}`;
      state.output = `$ ${commandPreview}\n${text || "完成"}`;
    } else {
      state.notice = previousNotice;
    }
    return text;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    state.phase = "error";
    state.notice = `失败：${label}`;
    state.output = `$ ${commandPreview}\n${message}`;
    return state.output;
  } finally {
    if (!quiet) {
      state.busy = false;
      state.task = "";
    } else if (state.task === label) {
      state.task = previousTask;
    }
  }
}

async function runCli(args: string, label = args, quiet = false): Promise<string> {
  return runShell(`${CLI} ${args}`, label, quiet);
}

async function startBackgroundCli(args: string, label = args): Promise<string> {
  const logName = label
    .replace(/[^\p{L}\p{N}._-]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase() || "task";
  const log = `${MODULE_DIR}/.log/webui-${logName}.log`;
  state.phase = "accepted";
  state.notice = `已投递后台任务：${label}`;
  state.output = `${label} 已在后台执行。\n日志：${log}\n完成后点刷新查看状态。`;
  await nextTick();
  await nextFrame();
  const command = `mkdir -p ${shellQuote(`${MODULE_DIR}/.log`)}; nohup sh -c ${shellQuote(`${CLI} ${args}`)} >${shellQuote(log)} 2>&1 & echo "[info] background task started: ${label}"`;
  return runShell(command, `投递 ${label}`, true);
}

function markQuietFailure(label: string, text: string): boolean {
  if (!execFailed(text)) return false;
  state.phase = "error";
  state.output = `${label} 失败：\n${text}`;
  return true;
}

async function refreshStatus(): Promise<boolean> {
  const text = await runCli("service status", "刷新状态", true);
  if (markQuietFailure("刷新状态", text)) return false;
  state.runtime = parseRuntime(text, state.runtime);
  state.selectedCore = state.runtime.selectedCore;
  return true;
}

async function refreshAll(): Promise<void> {
  state.task = "刷新面板";
  state.notice = "正在刷新面板数据";
  try {
    const failed: string[] = [];
    if (!await refreshStatus()) failed.push("刷新状态");
    const steps: Array<[string, () => Promise<boolean>]> = [
      ["读取应用规则", () => refreshApps(true)],
      ["读取黑名单", () => refreshBlock(true)],
      ["读取订阅", () => refreshSubs(true)],
      ["读取 MCP 信息", () => refreshMcp(true)],
      ["读取 Tailscale", () => refreshTailscale(true)],
      ["运行诊断", () => refreshHealth(true)]
    ];
    for (const [label, step] of steps) {
      state.task = label;
      state.notice = label;
      await nextTick();
      await nextFrame();
      if (!await step()) failed.push(label);
    }
    if (failed.length) {
      state.phase = "error";
      state.notice = "面板刷新不完整";
      state.output = `以下步骤失败：${failed.join("、")}。请查看输出并重试。\n\n${state.output}`;
      return;
    }
    state.output = "面板数据已刷新。";
    state.phase = "done";
  } finally {
    state.task = "";
    state.notice = "面板数据已刷新。";
  }
}

async function refreshHealth(quiet = false): Promise<boolean> {
  const text = await runCli("health", "运行诊断", quiet);
  if (quiet && markQuietFailure("运行诊断", text)) return false;
  state.health = parseHealth(text);
  return true;
}

async function refreshPing(): Promise<void> {
  state.pingtest = await runCli("pingtest", "连通性测试");
}

async function refreshApps(quiet = false): Promise<boolean> {
  const text = await runCli("app list", "读取应用规则", quiet);
  if (quiet && markQuietFailure("读取应用规则", text)) return false;
  state.appPolicy = parseApps(text);
  return true;
}

async function refreshPackages(quiet = false): Promise<boolean> {
  const query = state.packageQuery.trim();
  const text = await runCli(`app packages ${shellQuote(query)}`, query ? `搜索应用 ${query}` : "读取已安装应用", quiet);
  if (markQuietFailure("读取已安装应用", text)) return false;
  state.packages = parsePackages(text);
  return true;
}

async function refreshBlock(quiet = false): Promise<boolean> {
  const text = await runCli("block list", "读取黑名单", quiet);
  if (quiet && markQuietFailure("读取黑名单", text)) return false;
  state.blocklist = parseBlock(text, state.blocklist);
  return true;
}

async function refreshSubs(quiet = false): Promise<boolean> {
  const text = await runCli("sub list", "读取订阅", quiet);
  if (quiet && markQuietFailure("读取订阅", text)) return false;
  state.subscriptions = parseSubs(text, state.subscriptions);
  return true;
}

async function refreshCapture(quiet = false): Promise<void> {
  const text = await runCli("capture list", "读取抓包规则", quiet);
  state.capture = parseCapture(text, state.capture);
}

async function refreshCerts(quiet = false): Promise<boolean> {
  const text = await runCli("cert list", "读取证书", quiet);
  if (quiet && markQuietFailure("读取证书", text)) return false;
  state.certs = parseCerts(text, state.certs);
  return true;
}

async function refreshMcp(quiet = false): Promise<boolean> {
  const text = await runCli("mcp status", "读取 MCP", quiet);
  if (quiet && markQuietFailure("读取 MCP", text)) return false;
  state.mcp = parseMcp(text, state.mcp);
  return true;
}

async function refreshTailscale(quiet = false): Promise<boolean> {
  const text = await runCli("tailscale status", "读取 Tailscale", quiet);
  if (quiet && markQuietFailure("读取 Tailscale", text)) return false;
  state.tailscale = parseTailscale(text, state.tailscale);
  return true;
}

async function refreshTopology(): Promise<void> {
  const text = await runCli("topology", "刷新网络拓扑", true);
  state.topology = execFailed(text)
    ? await runCli("sysroute snapshot", "刷新路由快照")
    : text;
}

async function refreshSysroute(): Promise<void> {
  state.sysroute = await runCli("sysroute snapshot", "刷新路由表");
}

async function loadConfig(): Promise<void> {
  const target = state.config.target;
  state.config.status = "加载中";
  state.notice = `正在加载 ${target} 配置`;
  const text = await runCli(`config-editor get ${target}`, `加载 ${target} 配置`, true);
  if (execFailed(text)) {
    state.config.status = "加载失败";
    state.notice = `${target} 配置加载失败`;
    state.output = text || "加载失败：没有返回内容。";
    state.phase = "error";
    return;
  }
  state.config.text = text;
  state.config.dirty = false;
  state.config.status = `已加载 ${text.length} 字符`;
  state.config.path = target === "mihomo" ? `${MODULE_DIR}/.config/mihomo/config.yaml` : `${MODULE_DIR}/.config/sing-box/config.json`;
  state.notice = `${target} 配置已加载`;
  state.phase = "done";
  state.output = `${target} 配置已加载到编辑器，未在输出页展开显示。`;
}

async function saveConfig(): Promise<void> {
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const tmp = `${MODULE_DIR}/.tmp/config-editor-${state.config.target}-${stamp}.tmp`;
  const chunkSize = 1600;
  let text = await runShell(`mkdir -p ${shellQuote(`${MODULE_DIR}/.tmp`)}; : > ${shellQuote(tmp)}`, "准备配置临时文件", true);
  if (execFailed(text)) {
    state.config.status = "写入失败，未保存";
    return;
  }
  for (let offset = 0; offset < state.config.text.length; offset += chunkSize) {
    const chunk = state.config.text.slice(offset, offset + chunkSize);
    text = await runShell(`printf %s ${shellQuote(chunk)} >> ${shellQuote(tmp)}`, "写入配置临时文件", true);
    if (execFailed(text)) {
      state.config.status = "写入失败，未保存";
      await runShell(`rm -f ${shellQuote(tmp)}`, "清理配置临时文件", true);
      return;
    }
  }
  text = await runCli(`config-editor save-file ${state.config.target} ${shellQuote(tmp)}`, `校验并保存 ${state.config.target}`);
  state.config.status = execFailed(text) ? "校验失败，未保存" : "校验通过，已保存";
  if (!execFailed(text)) state.config.dirty = false;
}

const {
  autoCoreOpen,
  openExternal,
  openCoreUi,
  setAutoCoreOpen,
  tryAutoOpenCoreUi
} = useExternalLinks(state, runShell, runCli, refreshStatus);

const statusTone = computed(() => {
  if (state.runtime.core === "sing-box" || state.runtime.core === "mihomo") return "success";
  if (state.runtime.core === "stopped") return "warning";
  return "neutral";
});

export function useMagicNet() {
  return {
    state,
    autoCoreOpen,
    statusTone,
    compactOutput,
    REPO,
    AUTHOR_WHISPER_URL,
    runShell,
    runCli,
    startBackgroundCli,
    refreshAll,
    refreshStatus,
    refreshHealth,
    refreshPing,
    refreshApps,
    refreshPackages,
    refreshBlock,
    refreshSubs,
    refreshCapture,
    refreshCerts,
    refreshMcp,
    refreshTailscale,
    refreshTopology,
    refreshSysroute,
    loadConfig,
    saveConfig,
    openExternal,
    openCoreUi,
    setAutoCoreOpen,
    tryAutoOpenCoreUi,
    shellQuote,
    uniqueNonEmpty
  };
}
