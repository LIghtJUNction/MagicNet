import * as kernelsu from "kernelsu";
import { computed, nextTick, reactive } from "vue";
import { AUTHOR_WHISPER_URL, CLI, CLI_TIMEOUT_MS, MODULE_DIR, REPO } from "@/constants";
import type { AppPolicy, ConfigEditorTarget, HealthItem, PackageInfo } from "@/types";
import { blockDefaults, dnsDefaults, mcpDefaults, parseApps, parseBlock, parseDns, parseHealth, parseMcp, parsePackages, parseRuntime, parseSubs, parseWarp, runtimeDefaults, type SubscriptionState, warpDefaults } from "@/composables/parsers";
import { useExternalLinks } from "@/composables/useExternalLinks";
import { bytesToBase64, compactCommand, compactOutput, copyText, execFailed, intentDataQuote, normalizeExecResult, nextFrame, shellQuote, uniqueNonEmpty, withTimeout } from "@/utils";

type Phase = "idle" | "accepted" | "queued" | "running" | "done" | "error";

const ksuBridge = (globalThis as { ksu?: { exec?: unknown } }).ksu;
const hasKsu = typeof ksuBridge?.exec === "function";
let writeQueue: Promise<unknown> = Promise.resolve();
let backgroundLogTimer = 0;

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
  health: [] as HealthItem[],
  pingtest: "",
  appPolicy: { mode: "blacklist", proxy: [], bypass: [] } as AppPolicy,
  packages: [] as PackageInfo[],
  packageQuery: "",
  packageInput: "",
  blocklist: { ...blockDefaults },
  mcp: { ...mcpDefaults },
  dns: { ...dnsDefaults },
  warp: { ...warpDefaults },
  topology: "",
  sysroute: "",
  subscriptions: {
    singBox: "",
    singBoxUrls: [],
  } as SubscriptionState,
  config: {
    target: "sing-box" as ConfigEditorTarget,
    text: "",
    path: `${MODULE_DIR}/.config/sing-box/config.json`,
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
  stopBackgroundLogFollow();
  state.phase = "accepted";
  state.notice = `已投递后台任务：${label}`;
  state.output = `${label} 已在后台执行。\n日志：${log}\n正在跟踪启动日志...`;
  await nextTick();
  await nextFrame();
  const command = `mkdir -p ${shellQuote(`${MODULE_DIR}/.log`)}; : >${shellQuote(log)}; nohup sh -c ${shellQuote(`${CLI} ${args}`)} >${shellQuote(log)} 2>&1 </dev/null & echo "[info] background task started: ${label}"`;
  const result = await runShell(command, `投递 ${label}`, true);
  if (!execFailed(result)) {
    followBackgroundLogs(log, label, args);
  }
  return result;
}

function stopBackgroundLogFollow(): void {
  if (!backgroundLogTimer) return;
  window.clearTimeout(backgroundLogTimer);
  backgroundLogTimer = 0;
}

function backgroundLogCommand(log: string, args: string): string {
  const parts = [
    `echo "[task log] ${log}"`,
    `[ -f ${shellQuote(log)} ] && tail -n 80 ${shellQuote(log)} || echo "[info] waiting for task log..."`,
  ];
  if (/\bservice\s+(start|restart|ensure)\b/.test(args)) {
    parts.push(
      `echo ""`,
      `echo "[sing-box log] ${MODULE_DIR}/.log/sing-box.log"`,
      `[ -f ${shellQuote(`${MODULE_DIR}/.log/sing-box.log`)} ] && tail -n 80 ${shellQuote(`${MODULE_DIR}/.log/sing-box.log`)} || echo "[info] waiting for sing-box log..."`
    );
  }
  return parts.join("; ");
}

function backgroundFailed(logs: string): boolean {
  return logs.includes("[error]")
    || logs.includes("╳[error]")
    || /\b(not executable|failed with status|No subscription source is available)\b/i.test(logs);
}

function followBackgroundLogs(log: string, label: string, args: string, attempt = 0): void {
  const maxAttempts = 90;
  backgroundLogTimer = window.setTimeout(async () => {
    const [logs, status] = await Promise.all([
      runShell(backgroundLogCommand(log, args), `跟踪 ${label}`, true),
      runCli("service status", "刷新状态", true)
    ]);
    if (!execFailed(status)) {
      state.runtime = parseRuntime(status, state.runtime);
    }
    const done = !execFailed(status) && (
      state.runtime.singBoxState === "sing-box"
      || (/\bservice\s+stop\b/.test(args) && state.runtime.singBoxState === "stopped")
    );
    const failed = !done && backgroundFailed(logs);
    state.phase = done ? "done" : failed ? "error" : "running";
    state.notice = done ? `完成：${label}` : failed ? `失败：${label}` : `正在执行：${label}`;
    state.output = `${done ? "后台任务完成" : failed ? "后台任务失败" : "后台任务运行中"}：${label}\n\n${logs || "等待日志输出..."}`;
    if (!done && !failed && attempt + 1 < maxAttempts) {
      followBackgroundLogs(log, label, args, attempt + 1);
    } else {
      backgroundLogTimer = 0;
      if (!done && !failed) {
        state.phase = "error";
        state.notice = `${label} 仍在后台运行或未完成`;
        state.output += "\n\n[warn] 日志跟踪已超时，请稍后刷新状态或查看完整日志。";
      }
    }
  }, attempt === 0 ? 700 : 1000);
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
      ["读取 DNS", () => refreshDns(true)],
      ["读取 WARP", () => refreshWarp(true)],
      ["读取 MCP 信息", () => refreshMcp(true)],
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

async function refreshMcp(quiet = false): Promise<boolean> {
  const text = await runCli("mcp status", "读取 MCP", quiet);
  if (quiet && markQuietFailure("读取 MCP", text)) return false;
  state.mcp = parseMcp(text, state.mcp);
  return true;
}

async function refreshDns(quiet = false): Promise<boolean> {
  const text = await runCli("dns status", "读取 DNS", quiet);
  if (quiet && markQuietFailure("读取 DNS", text)) return false;
  state.dns = parseDns(text, state.dns);
  return true;
}

async function refreshWarp(quiet = false): Promise<boolean> {
  const text = await runCli("warp status", "读取 WARP", quiet);
  if (quiet && markQuietFailure("读取 WARP", text)) return false;
  state.warp = parseWarp(text, state.warp);
  return true;
}

function fenced(text: string): string {
  const body = text.trim() || "(empty)";
  return `\`\`\`text\n${body.replace(/```/g, "`\u200b``")}\n\`\`\``;
}

function issueSection(title: string, body: string): string {
  return `## ${title}\n\n${fenced(body)}\n`;
}

function propValue(text: string, key: string): string {
  const prefix = `${key}=`;
  return text
    .split("\n")
    .find((line) => line.startsWith(prefix))
    ?.slice(prefix.length)
    .trim() || "";
}

function buildIssueBody(parts: {
  moduleProp: string;
  device: string;
  status: string;
  health: string;
  mcp: string;
  network: string;
  support: string;
}): string {
  const generatedAt = new Date().toISOString();
  return [
    "## Problem",
    "",
    "请在这里描述你遇到的问题、复现步骤和期望结果。",
    "",
    "## Generated Context",
    "",
    `Generated at: ${generatedAt}`,
    "",
    issueSection("Module", parts.moduleProp),
    issueSection("Device", parts.device),
    issueSection("Service Status", parts.status),
    issueSection("Health", parts.health),
    issueSection("MCP", parts.mcp),
    issueSection("Network Probe", parts.network),
    issueSection("Support Bundle", parts.support)
  ].join("\n");
}

function firstLines(text: string, limit: number): string {
  return text
    .trim()
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit)
    .join("\n");
}

function buildShortIssueBody(parts: {
  version: string;
  device: string;
  status: string;
  health: string;
  copied: boolean;
}): string {
  return [
    "## Problem",
    "",
    "请在这里描述问题、复现步骤和期望结果。",
    "",
    "## Diagnostic Context",
    "",
    parts.copied
      ? "完整诊断上下文已复制到剪贴板，请直接粘贴到这里。"
      : "剪贴板不可用，请回到 MagicNet 输出页复制诊断上下文。",
    "",
    "## Summary",
    "",
    `version: ${parts.version}`,
    "",
    "### Device",
    fenced(firstLines(parts.device, 4)),
    "",
    "### Service Status",
    fenced(firstLines(parts.status, 12)),
    "",
    "### Health",
    fenced(firstLines(parts.health, 12))
  ].join("\n");
}

async function createIssue(): Promise<void> {
  state.task = "创建 GitHub issue";
  state.notice = "正在收集 issue 诊断信息";
  state.busy = true;
  state.phase = "running";
  try {
    const moduleProp = await runShell(`cat ${shellQuote(`${MODULE_DIR}/module.prop`)}`, "读取模块版本", true);
    const version = propValue(moduleProp, "version") || "unknown";
    const runtimeLabel = state.runtime.singBoxState === "unknown" ? "runtime" : state.runtime.singBoxState;
    const title = `[MagicNet] ${version} ${runtimeLabel} diagnostic report`;
    const [device, status, health, mcp, network, support] = await Promise.all([
      runShell("getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; uname -a", "读取设备信息", true),
      runCli("service status", "读取服务状态", true),
      runCli("health", "运行健康检查", true),
      runCli("mcp status", "读取 MCP 状态", true),
      runShell("ip -br addr; echo; ip route; echo; ss -lntp 2>/dev/null | grep -E '7890|7891|7892|9090|8766|18766' || true; echo; ping -c 1 -W 3 www.baidu.com >/dev/null && echo network_ok || echo network_fail", "读取网络诊断", true),
      runCli("support bundle", "生成支持包", true)
    ]);
    const body = buildIssueBody({ moduleProp, device, status, health, mcp, network, support });
    const copied = await copyText(body);
    const urlBody = buildShortIssueBody({ version, device, status, health, copied });
    const issueUrl = `${REPO}/issues/new?title=${encodeURIComponent(title)}&body=${encodeURIComponent(urlBody)}`;
    state.output = [
      copied ? "完整 issue 正文已复制到剪贴板。" : "剪贴板不可用，issue URL 只包含摘要。",
      `issue URL 只包含 ${urlBody.length} 字符的摘要，完整正文长度 ${body.length} 字符。`,
      "如果 GitHub 页面没有自动带入完整诊断，请长按正文框粘贴。",
      "",
      issueUrl
    ].join("\n");
    state.notice = "正在打开 GitHub issue";
    if (!state.hasKsu) {
      window.open(issueUrl, "_blank", "noopener,noreferrer");
    } else {
      await runShell(
        `am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -p com.android.chrome -d ${intentDataQuote(issueUrl)} >/dev/null 2>&1 || am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d ${intentDataQuote(issueUrl)}`,
        "打开 GitHub issue",
        true
      );
    }
    state.phase = "done";
    state.notice = "GitHub issue 已打开";
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    state.phase = "error";
    state.notice = "创建 issue 失败";
    state.output = `创建 GitHub issue 失败：\n${message}`;
  } finally {
    state.busy = false;
    state.task = "";
  }
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
  state.config.path = `${MODULE_DIR}/.config/sing-box/config.json`;
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

async function syncConfigTemplate(): Promise<void> {
  const target = state.config.target;
  const text = await runCli(`config-editor sync-template ${target}`, `同步 ${target} 上游模板`);
  state.config.status = execFailed(text) ? "同步失败" : "已同步上游模板";
  if (!execFailed(text)) {
    state.config.dirty = false;
    await loadConfig();
  }
}

const {
  autoSingBoxUiOpen,
  openExternal,
  openSingBoxUi,
  setAutoSingBoxUiOpen,
  tryAutoOpenSingBoxUi
} = useExternalLinks(state, runShell, runCli, refreshStatus);

const statusTone = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "success";
  if (state.runtime.singBoxState === "stopped") return "warning";
  return "neutral";
});

export function useMagicNet() {
  return {
    state,
    autoSingBoxUiOpen,
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
    refreshMcp,
    refreshDns,
    refreshWarp,
    createIssue,
    refreshTopology,
    refreshSysroute,
    loadConfig,
    saveConfig,
    syncConfigTemplate,
    openExternal,
    openSingBoxUi,
    setAutoSingBoxUiOpen,
    tryAutoOpenSingBoxUi,
    shellQuote,
    uniqueNonEmpty
  };
}
