import * as kernelsu from "kernelsu";
import { nextTick, reactive } from "vue";
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
  backgroundTaskBlocksLaunch,
  backgroundTaskDefaults,
  createBackgroundOperationId,
  isSubscriptionBackgroundArgs,
  parseBackgroundCompletion,
  reconcileSubscriptionCompletion,
} from "@/composables/backgroundTasks";
import { SerialExecQueue } from "@/composables/execQueue";
import { ForegroundUiGate } from "@/composables/foregroundUiGate";
import {
  beginOperationCapture,
  emptyOperationCapture,
  updateOperationCapture,
} from "@/composables/operationCapture";
import { refreshAllNotice } from "@/composables/refreshAllState";
import {
  blockDefaults,
  dnsDefaults,
  mcpDefaults,
  parseApps,
  parseBlock,
  parseDns,
  parseHealth,
  parseMcp,
  invalidateTransparentRuntime,
  parsePackages,
  parseConfigValidation,
  parseRuntime,
  parseSubs,
  parseWifiPolicy,
  parseWarp,
  runtimeDefaults,
  subscriptionDefaults,
  type ConfigValidationState,
  type SubscriptionState,
  warpDefaults,
  wifiPolicyDefaults,
} from "@/composables/parsers";
import { createMagicNetIssue } from "@/composables/issueReporter";
import type { IssueReportInput } from "@/composables/issueDrafts";
import { useExternalLinks } from "@/composables/useExternalLinks";
import {
  compactCommand,
  compactOutput,
  ExecTimeoutError,
  execFailed,
  normalizeExecOutcome,
  nextFrame,
  removePrivatePayload as removePrivatePayloadWithCli,
  redactedCliPreview,
  shellQuote,
  stagePrivatePayload as stagePrivatePayloadWithCli,
  unavailableExecOutcome,
  type ExecOutcome,
} from "@/utils";

type Phase = "idle" | "accepted" | "queued" | "running" | "done" | "error";
export type ConfigRepository = {
  url: string;
  reference: string;
  path: string;
  sha256?: string;
};

function hasKsuExec(): boolean {
  return (
    typeof (globalThis as { ksu?: { exec?: unknown } }).ksu?.exec === "function"
  );
}

const hasKsu = hasKsuExec();
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
  operationCapture: emptyOperationCapture(),
  backgroundTask: { ...backgroundTaskDefaults },
  issueReporter: {
    open: false,
  },
  runtime: { ...runtimeDefaults },
  health: [] as HealthItem[],
  pingtest: "",
  appPolicy: {
    mode: "blacklist",
    proxy: [],
    direct: [],
    bypass: [],
  } as AppPolicy,
  packages: [] as PackageInfo[],
  packageQuery: "",
  packageInput: "",
  blocklist: { ...blockDefaults },
  mcp: { ...mcpDefaults },
  dns: { ...dnsDefaults },
  warp: { ...warpDefaults },
  wifiPolicy: { ...wifiPolicyDefaults },
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

const execQueue = new SerialExecQueue((depth) => {
  state.queueDepth = depth;
});
const foregroundUiGate = new ForegroundUiGate();

function trackRedactedOperation(commandPreview: string, label = ""): number {
  const output = `$ ${commandPreview}\n执行中；私密输出已隐藏。`;
  const sequence = beginOperationCapture(
    state.operationCapture,
    commandPreview,
    output,
  );
  state.lastCommand = commandPreview;
  state.phase = "accepted";
  state.output = output;
  if (label) state.notice = `已接收：${label}`;
  return sequence;
}

function publishTrackedOperation(
  sequence: number,
  phase: Phase,
  notice: string,
  output: string,
): boolean {
  if (
    !updateOperationCapture(state.operationCapture, sequence, { phase, output })
  )
    return false;
  state.phase = phase;
  state.notice = notice;
  state.output = output;
  return true;
}

async function runShellOutcome(
  commandBody: string,
  label: string,
  quiet = false,
  previewOverride = "",
  trackCommand = true,
): Promise<ExecOutcome> {
  const command = `su -M -c ${shellQuote(commandBody)}`;
  const commandPreview = previewOverride || compactCommand(command);
  const foregroundToken = quiet ? 0 : foregroundUiGate.begin();
  const ownsForegroundUi = (): boolean =>
    !quiet && foregroundUiGate.owns(foregroundToken);
  const captureSequence = quiet
    ? 0
    : beginOperationCapture(
        state.operationCapture,
        commandPreview,
        `$ ${commandPreview}\n执行中...`,
      );
  if (trackCommand && (!quiet || previewOverride))
    state.lastCommand = commandPreview;
  if (ownsForegroundUi()) {
    state.task = label;
    state.notice = `已接收：${label}`;
    const wasBusy = state.busy;
    state.busy = true;
    state.phase = wasBusy ? "queued" : "accepted";
    updateOperationCapture(state.operationCapture, captureSequence, {
      phase: state.phase,
    });
    state.output = `$ ${commandPreview}\n执行中...`;
  }
  await nextTick();
  await nextFrame();

  state.hasKsu = hasKsuExec();
  if (!state.hasKsu) {
    const outcome = unavailableExecOutcome(commandPreview);
    const output = `当前没有 KernelSU 执行通道，命令未执行。\n\n${outcome.text}`;
    if (
      ownsForegroundUi() &&
      updateOperationCapture(state.operationCapture, captureSequence, {
        phase: "error",
        output,
      })
    ) {
      state.output = output;
      state.phase = "error";
      state.notice = `未执行：${label}`;
      state.busy = false;
      state.task = "";
    }
    return outcome;
  }

  try {
    const result = await execQueue.enqueue(
      async () => {
        if (quiet) {
          await nextTick();
          await nextFrame();
        }
        if (
          ownsForegroundUi() &&
          updateOperationCapture(state.operationCapture, captureSequence, {
            phase: "running",
          })
        ) {
          state.phase = "running";
          state.notice = `正在执行：${label}`;
          await nextTick();
          await nextFrame();
          await nextFrame();
        }
        return kernelsu.exec(command);
      },
      CLI_TIMEOUT_MS,
      label,
    );
    const outcome = normalizeExecOutcome(result);
    const text = outcome.text;
    const output = `$ ${commandPreview}\n${text || "完成"}`;
    if (
      ownsForegroundUi() &&
      updateOperationCapture(state.operationCapture, captureSequence, {
        phase: outcome.ok ? "done" : "error",
        output,
      })
    ) {
      state.phase = outcome.ok ? "done" : "error";
      state.notice = outcome.ok ? `完成：${label}` : `失败：${label}`;
      state.output = output;
    }
    return outcome;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const timedOut = error instanceof ExecTimeoutError;
    const text = `${timedOut ? "[exec-timeout]" : "[error] errno=-1"} ${message}`;
    const output = `$ ${commandPreview}\n${text}`;
    if (
      ownsForegroundUi() &&
      updateOperationCapture(state.operationCapture, captureSequence, {
        phase: "error",
        output,
      })
    ) {
      state.phase = "error";
      state.notice = timedOut ? `等待超时：${label}` : `失败：${label}`;
      state.output = output;
    }
    return {
      ok: false,
      timedOut,
      errno: -1,
      stdout: "",
      stderr: message,
      text,
    };
  } finally {
    if (ownsForegroundUi()) {
      state.busy = false;
      state.task = "";
    }
  }
}

async function runTrackedQuietShellOutcome(
  commandBody: string,
  label: string,
  redactedPreview: string,
): Promise<ExecOutcome> {
  const foregroundToken = foregroundUiGate.begin();
  const operationSequence = trackRedactedOperation(redactedPreview, label);
  const outcome = await runShellOutcome(
    commandBody,
    label,
    true,
    redactedPreview,
    false,
  );
  if (foregroundUiGate.owns(foregroundToken)) {
    const phase = outcome.ok ? "done" : "error";
    const result = outcome.ok
      ? "[info] completed; private output hidden"
      : outcome.timedOut
        ? "[exec-timeout] private output hidden"
        : `[error] errno=${outcome.errno}; private output hidden`;
    publishTrackedOperation(
      operationSequence,
      phase,
      outcome.ok ? `完成：${label}` : `失败：${label}`,
      `$ ${redactedPreview}\n${result}`,
    );
  }
  return outcome;
}

async function runShell(
  commandBody: string,
  label: string,
  quiet = false,
  previewOverride = "",
): Promise<string> {
  const outcome =
    quiet && previewOverride
      ? await runTrackedQuietShellOutcome(commandBody, label, previewOverride)
      : await runShellOutcome(commandBody, label, quiet, previewOverride);
  return outcome.text;
}

async function runCli(
  args: string,
  label = args,
  quiet = false,
  previewOverride = "",
): Promise<string> {
  return runShell(`${CLI} ${args}`, label, quiet, previewOverride);
}

type ForegroundCommand = {
  promise: Promise<string>;
  token: number;
};

/**
 * Capture the token owned by a command before its first await. Non-quiet
 * commands and redacted quiet commands allocate their own token inside
 * runCli; ordinary quiet reads inherit the caller's token so refresh-all and
 * background reconciliation do not steal foreground ownership merely by
 * reading state.
 */
function startForegroundCommand(
  args: string,
  label: string,
  quiet = false,
  previewOverride = "",
  inheritedToken?: number,
): ForegroundCommand {
  const before = foregroundUiGate.current();
  const promise = runCli(args, label, quiet, previewOverride);
  const after = foregroundUiGate.current();
  return {
    promise,
    token: after !== before ? after : (inheritedToken ?? before),
  };
}

/**
 * Run a command whose stdout/stderr may itself be sensitive. The real command
 * never reaches reactive output state; callers must provide a redacted preview
 * and turn the returned outcome into a safe user-facing status.
 */
async function runPrivateCli(
  args: string,
  label: string,
  redactedPreview: string,
): Promise<ExecOutcome> {
  return runTrackedQuietShellOutcome(`${CLI} ${args}`, label, redactedPreview);
}

async function runPrivatePayloadCli(
  args: string,
  label: string,
  redactedPreview: string,
): Promise<ExecOutcome> {
  return runShellOutcome(`${CLI} ${args}`, label, true, redactedPreview, false);
}

async function stagePrivatePayload(
  namespace: "tmp" | "subscription",
  basename: string,
  payload: string,
  label: string,
  chunkSize?: number,
) {
  const foregroundToken = foregroundUiGate.begin();
  const operationSequence = trackRedactedOperation(
    redactedCliPreview(`webui payload stage ${namespace} [private-payload]`),
    label,
  );
  const staged = await stagePrivatePayloadWithCli(
    runPrivatePayloadCli,
    MODULE_DIR,
    namespace,
    basename,
    payload,
    label,
    chunkSize,
  );
  if (foregroundUiGate.owns(foregroundToken)) {
    publishTrackedOperation(
      operationSequence,
      staged ? "done" : "error",
      staged ? `完成：${label}` : `失败：${label}`,
      staged
        ? `$ ${state.lastCommand}\n[info] completed; private output hidden`
        : `$ ${state.lastCommand}\n[error] private payload staging failed; private output hidden`,
    );
  }
  return staged;
}

async function removePrivatePayload(
  namespace: "tmp" | "subscription",
  basename: string,
  label: string,
): Promise<boolean> {
  return removePrivatePayloadWithCli(
    runPrivatePayloadCli,
    namespace,
    basename,
    label,
  );
}

async function startBackgroundCli(
  args: string,
  label = args,
  previewOverride = "",
  displayArgs = args,
  cleanupCommand = "",
  lifecycleArgs = displayArgs,
): Promise<string> {
  if (backgroundTaskBlocksLaunch(state.backgroundTask)) {
    const activeLabel = state.backgroundTask.label || "上一个后台任务";
    const text = `[error] unavailable: ${activeLabel} 仍在后台运行或等待对账，请到“输出”页确认完成后再试。`;
    state.notice = `未执行：${label}`;
    state.output = text;
    return text;
  }
  const foregroundToken = foregroundUiGate.begin();
  const ownsForegroundUi = (): boolean =>
    foregroundUiGate.owns(foregroundToken);
  const redactOutput = Boolean(previewOverride);
  const subscriptionTask = isSubscriptionBackgroundArgs(lifecycleArgs);
  const subscriptionBaselineKnown = subscriptionTask
    ? await refreshSubs(true)
    : false;
  if (!ownsForegroundUi()) {
    return `[warning] ${label} superseded by a newer foreground operation`;
  }
  const operationId = createBackgroundOperationId();
  const log = backgroundLogPath(label, operationId);
  stopBackgroundLogFollow();
  const startedAt = Date.now();
  state.backgroundTask = {
    id: operationId,
    label,
    args: displayArgs,
    log: redactOutput ? "" : log,
    startedAt,
    updatedAt: startedAt,
    finishedAt: 0,
    status: "running",
    subscriptionBaselineKnown,
    subscriptionBaselineAttemptEpoch: state.subscriptions.lastAttemptEpoch,
    subscriptionBaselineGenerationId: state.subscriptions.lastGenerationId,
    subscriptionBaselineResult: state.subscriptions.lastResult,
  };
  const operationSequence = trackRedactedOperation(
    previewOverride || redactedCliPreview(displayArgs),
    label,
  );
  await nextTick();
  await nextFrame();
  const command = backgroundLaunchCommand(
    args,
    label,
    log,
    operationId,
    cleanupCommand,
  );
  const outcome = await runShellOutcome(
    command,
    `投递 ${label}`,
    true,
    previewOverride,
  );
  if (state.backgroundTask.id !== operationId) return outcome.text;
  const accepted =
    outcome.ok && backgroundAccepted(outcome.stdout, operationId);
  if (accepted || outcome.timedOut) {
    if (outcome.timedOut && ownsForegroundUi()) {
      const output = redactOutput
        ? `${label} 的投递确认超时；这不代表设备侧任务失败。正在继续跟踪安全状态。`
        : `${label} 的投递确认超时；这不代表设备侧任务失败。正在继续跟踪后台日志。`;
      publishTrackedOperation(
        operationSequence,
        "running",
        `投递确认超时，继续对账：${label}`,
        output,
      );
    }
    followBackgroundLogs(
      log,
      label,
      lifecycleArgs,
      operationId,
      operationSequence,
      foregroundToken,
      0,
      redactOutput,
    );
  } else {
    state.backgroundTask.status = "error";
    state.backgroundTask.updatedAt = Date.now();
    state.backgroundTask.finishedAt = state.backgroundTask.updatedAt;
    const output = redactOutput
      ? `${label} 未投递到后台；私有命令详情已隐藏。请检查设备状态后重试。`
      : `${label} 未投递到后台。\n\n${outcome.text || "[error] accepted marker missing"}`;
    if (ownsForegroundUi()) {
      publishTrackedOperation(
        operationSequence,
        "error",
        `投递失败：${label}`,
        output,
      );
    }
  }
  if (outcome.timedOut) {
    return `[warning] background launch confirmation timed out; reconciliation continues in ${log}`;
  }
  return accepted
    ? outcome.text
    : `[error] errno=-1 background accepted marker missing`;
}

async function startPrivateBackgroundCli(
  args: string,
  label: string,
  redactedPreview: string,
  displayArgs: string,
  lifecycleArgs = displayArgs,
): Promise<string> {
  return startBackgroundCli(
    args,
    label,
    redactedPreview,
    displayArgs,
    "",
    lifecycleArgs,
  );
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
  operationSequence: number,
  foregroundToken: number,
  attempt = 0,
  redactOutput = false,
): void {
  const maxAttempts = 90;
  backgroundLogTimer = window.setTimeout(
    async () => {
      const subscriptionTask = isSubscriptionBackgroundArgs(args)
        ? refreshSubs(true, undefined, false)
        : Promise.resolve(true);
      const [logs, status] = await Promise.all([
        runShell(
          backgroundLogCommand(log, args, operationId),
          `跟踪 ${label}`,
          true,
        ),
        runCli("service status", "刷新状态", true),
        subscriptionTask,
      ]);
      if (state.backgroundTask.id !== operationId) return;
      const ownsForegroundUi = foregroundUiGate.owns(foregroundToken);
      if (ownsForegroundUi && !execFailed(status)) {
        state.runtime = parseRuntime(status, state.runtime);
      }
      const logCompletion = parseBackgroundCompletion(logs, operationId);
      const subscriptionCompletion = isSubscriptionBackgroundArgs(args)
        ? reconcileSubscriptionCompletion(
            state.backgroundTask,
            state.subscriptions,
          )
        : logCompletion;
      const completion =
        logCompletion === "error" || subscriptionCompletion === "error"
          ? "error"
          : logCompletion === "done" && subscriptionCompletion === "done"
            ? "done"
            : "running";
      const done = completion === "done";
      const failed = completion === "error";
      const now = Date.now();
      const visibleLogs = redactOutput
        ? "私有后台日志已隐藏。"
        : logs || "等待日志输出...";
      const output = `${done ? "后台任务完成" : failed ? "后台任务失败" : "后台任务运行中"}：${label}\n\n${visibleLogs}`;
      // Foreground ownership controls output only. The background operation
      // must still finish and release its launch lock after another UI action.
      if (ownsForegroundUi) {
        publishTrackedOperation(
          operationSequence,
          done ? "done" : failed ? "error" : "running",
          done
            ? `完成：${label}`
            : failed
              ? `失败：${label}`
              : `正在执行：${label}`,
          output,
        );
      }
      state.backgroundTask.status = done
        ? "done"
        : failed
          ? "error"
          : "running";
      state.backgroundTask.updatedAt = now;
      state.backgroundTask.finishedAt = done || failed ? now : 0;
      if (!done && !failed && attempt + 1 < maxAttempts) {
        followBackgroundLogs(
          log,
          label,
          args,
          operationId,
          operationSequence,
          foregroundToken,
          attempt + 1,
          redactOutput,
        );
      } else {
        backgroundLogTimer = 0;
        if (!done && !failed) {
          state.backgroundTask.status = "timeout";
          state.backgroundTask.updatedAt = Date.now();
          state.backgroundTask.finishedAt = 0;
          const timeoutOutput =
            state.output +
            (redactOutput
              ? "\n\n[warn] 安全状态跟踪已超时，但这不代表任务失败。请刷新订阅状态完成对账。"
              : "\n\n[warn] 日志跟踪已超时，但这不代表任务失败。请刷新订阅状态或查看完整日志以完成对账。");
          if (ownsForegroundUi) {
            publishTrackedOperation(
              operationSequence,
              "running",
              `${label} 仍在后台运行或等待对账`,
              timeoutOutput,
            );
          }
        }
      }
    },
    attempt === 0 ? 700 : 1000,
  );
}

function canUpdateRefreshUi(
  uiToken: number | undefined,
  allowBusy = false,
): boolean {
  if (uiToken === undefined) return !state.busy;
  return foregroundUiGate.owns(uiToken) && (allowBusy || !state.busy);
}

function markQuietFailure(
  label: string,
  text: string,
  uiToken?: number,
  allowBusy = false,
): boolean {
  if (!execFailed(text)) return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.phase = "error";
    state.notice = `${label}失败`;
    state.output = `${label} 失败：\n${text}`;
  }
  return true;
}

async function refreshStatus(foregroundToken?: number): Promise<boolean> {
  const serviceCommand = startForegroundCommand(
    "service status",
    "刷新服务状态",
    true,
    "",
    foregroundToken,
  );
  const transparentCommand = startForegroundCommand(
    "transparent status",
    "刷新透明代理状态",
    true,
    "",
    foregroundToken,
  );
  const uiToken = serviceCommand.token;
  const allowBusy = foregroundToken !== undefined;
  const [serviceText, transparentText] = await Promise.all([
    serviceCommand.promise,
    transparentCommand.promise,
  ]);
  const serviceFailed = execFailed(serviceText);
  const transparentFailed = execFailed(transparentText);
  const failure = serviceFailed
    ? serviceText
    : transparentFailed
      ? transparentText
      : "";
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    const validText = [
      serviceFailed ? "" : serviceText,
      transparentFailed ? "" : transparentText,
    ]
      .filter(Boolean)
      .join("\n");
    state.runtime = parseRuntime(validText, state.runtime);
    if (transparentFailed) {
      state.runtime = invalidateTransparentRuntime(state.runtime);
    }
  }
  if (failure) {
    markQuietFailure("刷新状态", failure, uiToken, allowBusy);
    return false;
  }
  return true;
}

async function refreshAll(): Promise<void> {
  const foregroundToken = foregroundUiGate.begin();
  const ownsForegroundUi = (): boolean =>
    foregroundUiGate.owns(foregroundToken);
  if (ownsForegroundUi()) {
    state.busy = true;
    state.task = "刷新面板";
    state.notice = "正在刷新面板数据";
  }
  let completed = false;
  try {
    const failed: string[] = [];
    if (!(await refreshStatus(foregroundToken))) failed.push("刷新状态");
    const steps: Array<[string, () => Promise<boolean>]> = [
      ["读取应用规则", () => refreshApps(true, foregroundToken)],
      ["读取黑名单", () => refreshBlock(true, foregroundToken)],
      ["读取订阅", () => refreshSubs(true, foregroundToken)],
      ["读取 DNS", () => refreshDns(true, foregroundToken)],
      ["读取 WARP", () => refreshWarp(true, foregroundToken)],
      ["读取 Wi-Fi 策略", () => refreshWifiPolicy(true, foregroundToken)],
      ["读取 MCP 信息", () => refreshMcp(true, foregroundToken)],
      ["运行诊断", () => refreshHealth(true, foregroundToken)],
    ];
    for (const [label, step] of steps) {
      if (ownsForegroundUi()) {
        state.task = label;
        state.notice = label;
      }
      await nextTick();
      await nextFrame();
      if (!(await step())) failed.push(label);
    }
    if (failed.length && ownsForegroundUi()) {
      state.phase = "error";
      state.notice = "面板刷新不完整";
      state.output = `以下步骤失败：${failed.join("、")}。请查看输出并重试。\n\n${state.output}`;
      return;
    }
    if (ownsForegroundUi()) {
      state.output = "面板数据已刷新。";
      state.phase = "done";
    }
    completed = true;
  } finally {
    if (ownsForegroundUi()) {
      state.busy = false;
      state.task = "";
      state.notice = refreshAllNotice(completed, state.notice);
    }
  }
}

async function refreshHealth(
  quiet = false,
  foregroundToken?: number,
): Promise<boolean> {
  const command = startForegroundCommand(
    "health",
    "运行诊断",
    quiet,
    "",
    foregroundToken,
  );
  const uiToken = command.token;
  const allowBusy = foregroundToken !== undefined;
  const text = await command.promise;
  if (markQuietFailure("运行诊断", text, uiToken, allowBusy)) return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.health = parseHealth(text);
  }
  return true;
}

async function refreshPing(): Promise<void> {
  const command = startForegroundCommand("pingtest", "连通性测试");
  const text = await command.promise;
  if (foregroundUiGate.owns(command.token)) state.pingtest = text;
}

async function refreshApps(
  quiet = false,
  foregroundToken?: number,
): Promise<boolean> {
  const command = startForegroundCommand(
    "app list",
    "读取应用规则",
    quiet,
    "",
    foregroundToken,
  );
  const uiToken = command.token;
  const allowBusy = foregroundToken !== undefined;
  const text = await command.promise;
  if (markQuietFailure("读取应用规则", text, uiToken, allowBusy)) return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.appPolicy = parseApps(text);
  }
  return true;
}

async function refreshPackages(
  quiet = false,
  foregroundToken?: number,
): Promise<boolean> {
  const query = state.packageQuery.trim();
  const command = startForegroundCommand(
    `app packages ${shellQuote(query)}`,
    query ? `搜索应用 ${query}` : "读取已安装应用",
    quiet,
    "",
    foregroundToken,
  );
  const uiToken = command.token;
  const allowBusy = foregroundToken !== undefined;
  const text = await command.promise;
  if (markQuietFailure("读取已安装应用", text, uiToken, allowBusy))
    return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.packages = parsePackages(text);
  }
  return true;
}

async function refreshBlock(
  quiet = false,
  foregroundToken?: number,
): Promise<boolean> {
  const command = startForegroundCommand(
    "block list",
    "读取黑名单",
    quiet,
    "",
    foregroundToken,
  );
  const uiToken = command.token;
  const allowBusy = foregroundToken !== undefined;
  const text = await command.promise;
  if (markQuietFailure("读取黑名单", text, uiToken, allowBusy)) return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.blocklist = parseBlock(text, state.blocklist);
  }
  return true;
}

async function refreshSubs(
  quiet = false,
  foregroundToken?: number,
  reportFailure = true,
): Promise<boolean> {
  const listCommand = startForegroundCommand(
    "sub list",
    "读取订阅列表",
    quiet,
    "",
    foregroundToken,
  );
  const statusCommand = startForegroundCommand(
    "sub status",
    "读取订阅状态",
    quiet,
    "",
    foregroundToken,
  );
  const uiToken = statusCommand.token;
  const allowBusy = foregroundToken !== undefined;
  const [listText, statusText] = await Promise.all([
    listCommand.promise,
    statusCommand.promise,
  ]);
  const failed = [
    execFailed(listText) ? "订阅列表" : "",
    execFailed(statusText) ? "订阅状态" : "",
  ].filter(Boolean);
  if (failed.length) {
    if (reportFailure && canUpdateRefreshUi(uiToken, allowBusy)) {
      state.phase = "error";
      state.notice = "订阅刷新不完整";
      state.output = `读取${failed.join("和")}失败，旧数据已保留。\n\n${[listText, statusText].filter(execFailed).join("\n")}`;
    }
    return false;
  }
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.subscriptions = parseSubs(listText, statusText, state.subscriptions);
  }
  return true;
}

async function refreshMcp(
  quiet = false,
  foregroundToken?: number,
): Promise<boolean> {
  const command = startForegroundCommand(
    "mcp status",
    "读取 MCP",
    quiet,
    "",
    foregroundToken,
  );
  const uiToken = command.token;
  const allowBusy = foregroundToken !== undefined;
  const text = await command.promise;
  if (markQuietFailure("读取 MCP", text, uiToken, allowBusy)) return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.mcp = parseMcp(text, state.mcp);
  }
  return true;
}

async function refreshDns(
  quiet = false,
  foregroundTokenOrPreview?: number | string,
): Promise<boolean> {
  const foregroundToken =
    typeof foregroundTokenOrPreview === "number"
      ? foregroundTokenOrPreview
      : undefined;
  const previewOverride =
    typeof foregroundTokenOrPreview === "string"
      ? foregroundTokenOrPreview
      : "";
  const command = startForegroundCommand(
    "dns status",
    "读取 DNS",
    quiet,
    previewOverride,
    foregroundToken,
  );
  const uiToken = command.token;
  const allowBusy = foregroundTokenOrPreview !== undefined;
  const text = await command.promise;
  if (markQuietFailure("读取 DNS", text, uiToken, allowBusy)) return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.dns = parseDns(text, state.dns);
  }
  return true;
}

async function refreshWarp(
  quiet = false,
  foregroundToken?: number,
): Promise<boolean> {
  const command = startForegroundCommand(
    "warp status",
    "读取 WARP",
    quiet,
    "",
    foregroundToken,
  );
  const uiToken = command.token;
  const allowBusy = foregroundToken !== undefined;
  const text = await command.promise;
  if (markQuietFailure("读取 WARP", text, uiToken, allowBusy)) return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.warp = parseWarp(text, state.warp);
  }
  return true;
}

async function refreshWifiPolicy(
  quiet = false,
  foregroundToken?: number,
): Promise<boolean> {
  const command = startForegroundCommand(
    "wifi status",
    "读取 Wi-Fi 策略",
    quiet,
    "",
    foregroundToken,
  );
  const uiToken = command.token;
  const allowBusy = foregroundToken !== undefined;
  const text = await command.promise;
  if (markQuietFailure("读取 Wi-Fi 策略", text, uiToken, allowBusy))
    return false;
  if (canUpdateRefreshUi(uiToken, allowBusy)) {
    state.wifiPolicy = parseWifiPolicy(text);
  }
  return true;
}

async function createIssue(): Promise<void> {
  state.issueReporter.open = true;
}

function closeIssueReporter(): void {
  state.issueReporter.open = false;
}

async function submitIssue(report: IssueReportInput): Promise<void> {
  closeIssueReporter();
  await createMagicNetIssue({ state, runShell, runCli }, report);
}

async function refreshTopology(): Promise<void> {
  const topologyCommand = startForegroundCommand(
    "topology",
    "刷新网络拓扑",
    true,
    redactedCliPreview("topology [private-output]"),
  );
  const text = await topologyCommand.promise;
  if (!foregroundUiGate.owns(topologyCommand.token)) return;
  if (!execFailed(text)) {
    state.topology = text;
    return;
  }
  const fallbackCommand = startForegroundCommand(
    "sysroute snapshot",
    "刷新路由快照",
  );
  const fallbackText = await fallbackCommand.promise;
  if (foregroundUiGate.owns(fallbackCommand.token))
    state.sysroute = fallbackText;
}

async function refreshSysroute(): Promise<void> {
  const command = startForegroundCommand("sysroute snapshot", "刷新路由表");
  const text = await command.promise;
  if (foregroundUiGate.owns(command.token)) state.sysroute = text;
}

function configDraftMatches(
  snapshot: { target: ConfigEditorTarget; text: string },
): boolean {
  return state.config.target === snapshot.target && state.config.text === snapshot.text;
}

async function loadConfig(): Promise<void> {
  const snapshot = { target: state.config.target, text: state.config.text };
  const { target } = snapshot;
  const command = startForegroundCommand(
    `config-editor get ${target}`,
    `加载 ${target} 配置`,
    true,
    redactedCliPreview(`config-editor get ${target} [private-output]`),
  );
  if (foregroundUiGate.owns(command.token)) {
    state.config.status = "加载中";
    state.notice = `正在加载 ${target} 配置`;
  }
  const text = await command.promise;
  if (!foregroundUiGate.owns(command.token)) return;
  if (!configDraftMatches(snapshot)) {
    state.config.status = "已保留加载期间的修改";
    return;
  }
  if (execFailed(text)) {
    state.config.status = "加载失败";
    state.notice = `${target} 配置加载失败`;
    state.output = "加载失败：配置读取命令未成功，私密输出未显示。";
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
  const snapshot = { target: state.config.target, text: state.config.text };
  const { target } = snapshot;
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const basename = `config-editor-${target}-${stamp}.tmp`;
  const stagePromise = stagePrivatePayload(
    "tmp",
    basename,
    snapshot.text,
    "配置私有载荷",
  );
  const stageToken = foregroundUiGate.current();
  const staged = await stagePromise;
  if (!staged) {
    if (!foregroundUiGate.owns(stageToken)) return;
    state.config.status = "安全临时数据写入失败，未保存";
    state.config.validation = {
      status: "error",
      summary: "安全临时数据写入失败，未运行配置校验。",
      checkedAt: new Date().toLocaleTimeString(),
    };
    state.phase = "error";
    state.notice = `${state.config.target} 配置未保存`;
    state.output = state.config.status;
    return;
  }
  if (!foregroundUiGate.owns(stageToken)) {
    await removePrivatePayload("tmp", staged.basename, "配置私有载荷");
    return;
  }

  let uiToken = stageToken;
  try {
    const commandPromise = runPrivateCli(
      `config-editor save-file ${target} ${shellQuote(staged.path)}`,
      `校验并保存 ${target}`,
      redactedCliPreview(
        `config-editor save-file ${target} [private-payload]`,
      ),
    );
    uiToken = foregroundUiGate.current();
    const outcome = await commandPromise;
    if (!foregroundUiGate.owns(uiToken)) return;
    if (state.config.target !== target) return;
    const saved =
      outcome.ok && /\[info\]\s+Saved and validated/i.test(outcome.stdout);
    const currentDraft = configDraftMatches(snapshot);
    state.config.validation = {
      status: currentDraft ? (saved ? "ok" : "error") : "idle",
      summary: !currentDraft
        ? "当前修改尚未校验。"
        : saved ? "配置已通过校验并保存。" : "配置校验失败，未保存。",
      checkedAt: new Date().toLocaleTimeString(),
    };
    state.config.status = saved ? "校验通过，已保存" : "校验失败，未保存";
    if (!currentDraft) state.config.status += "；当前修改未保存";
    state.phase = saved ? "done" : "error";
    state.notice = saved
      ? `${state.config.target} 配置已保存`
      : `${state.config.target} 配置未保存`;
    state.output = state.config.status;
    if (saved && currentDraft) state.config.dirty = false;
  } finally {
    const cleaned = await removePrivatePayload(
      "tmp",
      staged.basename,
      "配置私有载荷",
    );
    if (!foregroundUiGate.owns(uiToken)) return;
    if (!cleaned) {
      state.config.status = `${state.config.status}；私有临时数据清理未确认`;
      state.config.validation = {
        status: "error",
        summary: "私有临时数据清理未确认，请检查设备状态。",
        checkedAt: new Date().toLocaleTimeString(),
      };
      state.phase = "error";
      state.output = state.config.status;
    }
  }
}

async function syncConfigTemplate(): Promise<void> {
  const snapshot = { target: state.config.target, text: state.config.text };
  const { target } = snapshot;
  const command = startForegroundCommand(
    `config-editor sync-template ${target}`,
    `同步 ${target} 配置仓库模板`,
  );
  const text = await command.promise;
  if (!foregroundUiGate.owns(command.token)) return;
  if (state.config.target !== target) return;
  const failed = execFailed(text);
  const validation = parseConfigValidation(text);
  state.config.status = failed ? "同步失败" : "已同步配置仓库模板";
  state.config.validation = {
    status: failed ? "error" : "ok",
    summary: failed ? validation.summary : "配置仓库模板已同步并通过校验。",
    checkedAt: new Date().toLocaleTimeString(),
  };
  if (!failed) {
    if (!configDraftMatches(snapshot)) {
      state.config.status = "已同步模板；当前修改已保留";
      state.config.validation = {
        status: "idle", summary: "当前修改尚未校验。", checkedAt: "",
      };
      return;
    }
    await loadConfig();
  }
}

async function loadConfigRepository(): Promise<ConfigRepository | null> {
  const outcome = await runPrivateCli(
    "config-editor repo get-json",
    "读取配置仓库",
    "config-editor repo get-json [private-output]",
  );
  if (!outcome.ok) return null;
  try {
    const parsed = JSON.parse(outcome.stdout) as Partial<ConfigRepository>;
    if (
      typeof parsed.url !== "string" ||
      typeof parsed.reference !== "string" ||
      typeof parsed.path !== "string"
    ) {
      return null;
    }
    return {
      url: parsed.url,
      reference: parsed.reference,
      path: parsed.path,
      ...(typeof parsed.sha256 === "string" ? { sha256: parsed.sha256 } : {}),
    };
  } catch {
    return null;
  }
}

async function saveConfigRepository(repository: {
  url: string;
  ref: string;
  path: string;
  sha256?: string;
}): Promise<boolean> {
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const basename = `config-repository-${stamp}.json`;
  const staged = await stagePrivatePayload(
    "tmp",
    basename,
    `${JSON.stringify(repository)}\n`,
    "配置仓库私有载荷",
  );
  if (!staged) return false;
  try {
    const outcome = await runPrivateCli(
      `config-editor repo set-file ${shellQuote(staged.path)}`,
      "保存配置仓库",
      "config-editor repo set-file [private-payload]",
    );
    if (!outcome.ok) return false;
    state.notice = "配置仓库已保存";
    return true;
  } finally {
    await removePrivatePayload("tmp", staged.basename, "配置仓库私有载荷");
  }
}

const { openExternal, openSingBoxUi } = useExternalLinks(
  state,
  runShell,
  runCli,
);

export function useMagicNet() {
  return {
    state,
    compactOutput,
    REPO,
    AUTHOR_WHISPER_URL,
    runShell,
    runCli,
    runPrivateCli,
    stagePrivatePayload,
    removePrivatePayload,
    startBackgroundCli,
    startPrivateBackgroundCli,
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
    refreshWifiPolicy,
    createIssue,
    closeIssueReporter,
    submitIssue,
    refreshTopology,
    refreshSysroute,
    loadConfig,
    saveConfig,
    syncConfigTemplate,
    loadConfigRepository,
    saveConfigRepository,
    openExternal,
    openSingBoxUi,
    shellQuote,
  };
}
