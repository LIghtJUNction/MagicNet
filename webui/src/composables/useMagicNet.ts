import * as kernelsu from "kernelsu";
import { computed, nextTick, reactive } from "vue";
import {
  AUTHOR_WHISPER_URL,
  CLI,
  CLI_TIMEOUT_MS,
  MODULE_DIR,
  REPO,
} from "@/constants";
import type {
  AppPolicy,
  ConfigEditorTarget,
  HealthItem,
  PackageInfo,
} from "@/types";
import {
  backgroundLaunchCommand,
  backgroundAccepted,
  backgroundLogCommand,
  backgroundLogPath,
  backgroundTaskDefaults,
  createBackgroundOperationId,
  isSubscriptionBackgroundArgs,
  parseBackgroundCompletion,
  reconcileSubscriptionCompletion,
} from "@/composables/backgroundTasks";
import {
  blockDefaults,
  dnsDefaults,
  mcpDefaults,
  parseApps,
  parseBlock,
  parseConfigValidation,
  parseDns,
  parseHealth,
  parseMcp,
  parsePackages,
  parseRuntime,
  parseSubs,
  parseWarp,
  runtimeDefaults,
  subscriptionDefaults,
  type ConfigValidationState,
  type SubscriptionState,
  warpDefaults,
} from "@/composables/parsers";
import { createMagicNetIssue } from "@/composables/issueReporter";
import { useExternalLinks } from "@/composables/useExternalLinks";
import {
  bytesToBase64,
  compactCommand,
  compactOutput,
  ExecTimeoutError,
  execFailed,
  normalizeExecOutcome,
  nextFrame,
  shellQuote,
  unavailableExecOutcome,
  uniqueNonEmpty,
  withTimeout,
  type ExecOutcome,
} from "@/utils";

type Phase = "idle" | "accepted" | "queued" | "running" | "done" | "error";

function hasKsuExec(): boolean {
  return (
    typeof (globalThis as { ksu?: { exec?: unknown } }).ksu?.exec === "function"
  );
}

const hasKsu = hasKsuExec();
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
  output: hasKsu
    ? "正在读取 MagicNet 状态..."
    : "本地预览模式：真机 WebUI 才会执行 root 命令。",
  backgroundTask: { ...backgroundTaskDefaults },
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
    ...subscriptionDefaults,
  } as SubscriptionState,
  config: {
    target: "sing-box" as ConfigEditorTarget,
    text: "",
    path: `${MODULE_DIR}/.config/sing-box/config.json`,
    dirty: false,
    status: "尚未加载",
    validation: {
      status: "idle",
      summary: "尚未执行校验。",
      checkedAt: "",
    } as ConfigValidationState,
  },
  backup: {
    exportPassword: "",
    restorePassword: "",
    payload: "",
    status: "尚未导出",
  },
});

async function queued<T>(task: () => Promise<T>): Promise<T> {
  state.queueDepth += 1;
  const run = writeQueue.then(task, task).finally(() => {
    state.queueDepth = Math.max(0, state.queueDepth - 1);
  });
  writeQueue = run.catch(() => undefined);
  return run;
}

async function runShellOutcome(
  commandBody: string,
  label: string,
  quiet = false,
  previewOverride = "",
): Promise<ExecOutcome> {
  const command = `su -M -c ${shellQuote(commandBody)}`;
  const commandPreview = previewOverride || compactCommand(command);
  if (!quiet || previewOverride) state.lastCommand = commandPreview;
  if (!quiet) {
    state.task = label;
    state.notice = `已接收：${label}`;
    const wasBusy = state.busy;
    state.busy = true;
    state.phase = wasBusy ? "queued" : "accepted";
    state.output = `$ ${commandPreview}\n执行中...`;
  }
  await nextTick();
  await nextFrame();

  state.hasKsu = hasKsuExec();
  if (!state.hasKsu) {
    const outcome = unavailableExecOutcome(commandPreview);
    if (!quiet) {
      state.output = `当前没有 KernelSU 执行通道，命令未执行。\n\n${outcome.text}`;
      state.phase = "error";
      state.notice = `未执行：${label}`;
      state.busy = false;
      state.task = "";
    }
    return outcome;
  }

  try {
    const result = await queued(async () => {
      if (quiet) {
        await nextTick();
        await nextFrame();
        return withTimeout(kernelsu.exec(command), CLI_TIMEOUT_MS, label);
      }
      state.phase = "running";
      state.notice = `正在执行：${label}`;
      await nextTick();
      await nextFrame();
      await nextFrame();
      return withTimeout(kernelsu.exec(command), CLI_TIMEOUT_MS, label);
    });
    const outcome = normalizeExecOutcome(result);
    const text = outcome.text;
    if (!quiet) {
      state.phase = outcome.ok ? "done" : "error";
      state.notice = outcome.ok ? `完成：${label}` : `失败：${label}`;
      state.output = `$ ${commandPreview}\n${text || "完成"}`;
    }
    return outcome;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const timedOut = error instanceof ExecTimeoutError;
    const text = `${timedOut ? "[exec-timeout]" : "[error] errno=-1"} ${message}`;
    if (!quiet) {
      state.phase = "error";
      state.notice = timedOut ? `等待超时：${label}` : `失败：${label}`;
      state.output = `$ ${commandPreview}\n${text}`;
    }
    return { ok: false, timedOut, errno: -1, stdout: "", stderr: message, text };
  } finally {
    if (!quiet) {
      state.busy = false;
      state.task = "";
    }
  }
}

async function runShell(
  commandBody: string,
  label: string,
  quiet = false,
  previewOverride = "",
): Promise<string> {
  return (await runShellOutcome(commandBody, label, quiet, previewOverride)).text;
}

async function runCli(
  args: string,
  label = args,
  quiet = false,
  previewOverride = "",
): Promise<string> {
  return runShell(`${CLI} ${args}`, label, quiet, previewOverride);
}

async function startBackgroundCli(
  args: string,
  label = args,
  previewOverride = "",
  displayArgs = args,
  cleanupCommand = "",
): Promise<string> {
  const subscriptionTask = isSubscriptionBackgroundArgs(displayArgs);
  const subscriptionBaselineKnown = subscriptionTask ? await refreshSubs(true) : false;
  const operationId = createBackgroundOperationId();
  const log = backgroundLogPath(label, operationId);
  stopBackgroundLogFollow();
  const startedAt = Date.now();
  state.backgroundTask = {
    id: operationId,
    label,
    args: displayArgs,
    log,
    startedAt,
    updatedAt: startedAt,
    finishedAt: 0,
    status: "running",
    subscriptionBaselineKnown,
    subscriptionBaselineAttemptEpoch: state.subscriptions.lastAttemptEpoch,
    subscriptionBaselineGenerationId: state.subscriptions.lastGenerationId,
    subscriptionBaselineResult: state.subscriptions.lastResult,
  };
  state.phase = "accepted";
  state.notice = `已投递后台任务：${label}`;
  state.output = `${label} 已在后台执行。\n日志：${log}\n正在跟踪启动日志...`;
  await nextTick();
  await nextFrame();
  const command = backgroundLaunchCommand(args, label, log, operationId, cleanupCommand);
  const outcome = await runShellOutcome(
    command,
    `投递 ${label}`,
    true,
    previewOverride,
  );
  const accepted = outcome.ok && backgroundAccepted(outcome.stdout, operationId);
  if (accepted || outcome.timedOut) {
    if (outcome.timedOut) {
      state.notice = `投递确认超时，继续对账：${label}`;
      state.output = `${label} 的投递确认超时；这不代表设备侧任务失败。正在继续跟踪后台日志。`;
    }
    followBackgroundLogs(log, label, args, operationId);
  } else {
    state.backgroundTask.status = "error";
    state.backgroundTask.updatedAt = Date.now();
    state.backgroundTask.finishedAt = state.backgroundTask.updatedAt;
    state.phase = "error";
    state.notice = `投递失败：${label}`;
    state.output = `${label} 未投递到后台。\n\n${outcome.text || "[error] accepted marker missing"}`;
  }
  if (outcome.timedOut) {
    return `[warning] background launch confirmation timed out; reconciliation continues in ${log}`;
  }
  return accepted ? outcome.text : `[error] errno=-1 background accepted marker missing`;
}

function stopBackgroundLogFollow(): void {
  if (!backgroundLogTimer) return;
  window.clearTimeout(backgroundLogTimer);
  backgroundLogTimer = 0;
}

function followBackgroundLogs(
  log: string,
  label: string,
  args: string,
  operationId: string,
  attempt = 0,
): void {
  const maxAttempts = 90;
  backgroundLogTimer = window.setTimeout(
    async () => {
      const subscriptionTask = isSubscriptionBackgroundArgs(args)
        ? refreshSubs(true)
        : Promise.resolve(true);
      const [logs, status] = await Promise.all([
        runShell(backgroundLogCommand(log, args, operationId), `跟踪 ${label}`, true),
        runCli("service status", "刷新状态", true),
        subscriptionTask,
      ]);
      if (state.backgroundTask.id !== operationId) return;
      if (!execFailed(status)) {
        state.runtime = parseRuntime(status, state.runtime);
      }
      const logCompletion = parseBackgroundCompletion(logs, operationId);
      const subscriptionCompletion = isSubscriptionBackgroundArgs(args)
        ? reconcileSubscriptionCompletion(state.backgroundTask, state.subscriptions)
        : logCompletion;
      const completion = logCompletion === "error" || subscriptionCompletion === "error"
        ? "error"
        : logCompletion === "done" && subscriptionCompletion === "done"
          ? "done"
          : "running";
      const done = completion === "done";
      const failed = completion === "error";
      const now = Date.now();
      state.backgroundTask.status = done
        ? "done"
        : failed
          ? "error"
          : "running";
      state.backgroundTask.updatedAt = now;
      state.backgroundTask.finishedAt = done || failed ? now : 0;
      state.phase = done ? "done" : failed ? "error" : "running";
      state.notice = done
        ? `完成：${label}`
        : failed
          ? `失败：${label}`
          : `正在执行：${label}`;
      state.output = `${done ? "后台任务完成" : failed ? "后台任务失败" : "后台任务运行中"}：${label}\n\n${logs || "等待日志输出..."}`;
      if (!done && !failed && attempt + 1 < maxAttempts) {
        followBackgroundLogs(log, label, args, operationId, attempt + 1);
      } else {
        backgroundLogTimer = 0;
        if (!done && !failed) {
          state.backgroundTask.status = "timeout";
          state.backgroundTask.updatedAt = Date.now();
          state.backgroundTask.finishedAt = 0;
          state.phase = "running";
          state.notice = `${label} 仍在后台运行或等待对账`;
          state.output +=
            "\n\n[warn] 日志跟踪已超时，但这不代表任务失败。请刷新订阅状态或查看完整日志以完成对账。";
        }
      }
    },
    attempt === 0 ? 700 : 1000,
  );
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
    if (!(await refreshStatus())) failed.push("刷新状态");
    const steps: Array<[string, () => Promise<boolean>]> = [
      ["读取应用规则", () => refreshApps(true)],
      ["读取黑名单", () => refreshBlock(true)],
      ["读取订阅", () => refreshSubs(true)],
      ["读取 DNS", () => refreshDns(true)],
      ["读取 WARP", () => refreshWarp(true)],
      ["读取 MCP 信息", () => refreshMcp(true)],
      ["运行诊断", () => refreshHealth(true)],
    ];
    for (const [label, step] of steps) {
      state.task = label;
      state.notice = label;
      await nextTick();
      await nextFrame();
      if (!(await step())) failed.push(label);
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
  const text = await runCli(
    `app packages ${shellQuote(query)}`,
    query ? `搜索应用 ${query}` : "读取已安装应用",
    quiet,
  );
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
  const [listText, statusText] = await Promise.all([
    runCli("sub list", "读取订阅列表", quiet),
    runCli("sub status", "读取订阅状态", quiet),
  ]);
  const failed = [
    execFailed(listText) ? "订阅列表" : "",
    execFailed(statusText) ? "订阅状态" : "",
  ].filter(Boolean);
  if (failed.length) {
    state.phase = "error";
    state.notice = "订阅刷新不完整";
    state.output = `读取${failed.join("和")}失败，旧数据已保留。\n\n${[listText, statusText].filter(execFailed).join("\n")}`;
    return false;
  }
  state.subscriptions = parseSubs(listText, statusText, state.subscriptions);
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

async function createIssue(): Promise<void> {
  await createMagicNetIssue({ state, runShell, runCli });
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
  const text = await runCli(
    `config-editor get ${target}`,
    `加载 ${target} 配置`,
    true,
  );
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
  state.config.validation = {
    status: "idle",
    summary: "配置已加载，尚未执行本次校验。",
    checkedAt: "",
  };
  state.config.path = `${MODULE_DIR}/.config/sing-box/config.json`;
  state.notice = `${target} 配置已加载`;
  state.phase = "done";
  state.output = `${target} 配置已加载到编辑器，未在输出页展开显示。`;
}

async function saveConfig(): Promise<void> {
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const tmp = `${MODULE_DIR}/.tmp/config-editor-${state.config.target}-${stamp}.tmp`;
  const chunkSize = 1600;
  let text = await runShell(
    `mkdir -p ${shellQuote(`${MODULE_DIR}/.tmp`)}; : > ${shellQuote(tmp)}`,
    "准备配置临时文件",
    true,
  );
  if (execFailed(text)) {
    state.config.status = "写入失败，未保存";
    return;
  }
  for (let offset = 0; offset < state.config.text.length; offset += chunkSize) {
    const chunk = state.config.text.slice(offset, offset + chunkSize);
    text = await runShell(
      `printf %s ${shellQuote(chunk)} >> ${shellQuote(tmp)}`,
      "写入配置临时文件",
      true,
    );
    if (execFailed(text)) {
      state.config.status = "写入失败，未保存";
      await runShell(`rm -f ${shellQuote(tmp)}`, "清理配置临时文件", true);
      return;
    }
  }
  try {
    text = await runCli(
      `config-editor save-file ${state.config.target} ${shellQuote(tmp)}`,
      `校验并保存 ${state.config.target}`,
    );
    const validation = parseConfigValidation(text);
    state.config.validation = {
      ...validation,
      checkedAt: new Date().toLocaleTimeString(),
    };
    state.config.status = execFailed(text)
      ? "校验失败，未保存"
      : "校验通过，已保存";
    if (!execFailed(text)) state.config.dirty = false;
  } finally {
    await runShell(`rm -f ${shellQuote(tmp)}`, "清理配置临时文件", true);
  }
}

async function syncConfigTemplate(): Promise<void> {
  const target = state.config.target;
  const text = await runCli(
    `config-editor sync-template ${target}`,
    `同步 ${target} 上游模板`,
  );
  state.config.status = execFailed(text) ? "同步失败" : "已同步上游模板";
  state.config.validation = {
    status: execFailed(text) ? "error" : "ok",
    summary: execFailed(text)
      ? "上游模板同步失败。"
      : "上游模板已同步并通过校验。",
    checkedAt: new Date().toLocaleTimeString(),
  };
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
  tryAutoOpenSingBoxUi,
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
    uniqueNonEmpty,
  };
}
