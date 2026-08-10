import { CLI, MODULE_DIR } from "../constants.ts";
import { shellQuote } from "../utils.ts";

export type BackgroundTaskStatus = "idle" | "running" | "done" | "error" | "timeout";

export type BackgroundTaskState = {
  id: string;
  label: string;
  args: string;
  log: string;
  startedAt: number;
  updatedAt: number;
  finishedAt: number;
  status: BackgroundTaskStatus;
  subscriptionBaselineKnown: boolean;
  subscriptionBaselineAttemptEpoch: number;
  subscriptionBaselineGenerationId: string;
  subscriptionBaselineResult: string;
};

export const backgroundTaskDefaults: BackgroundTaskState = {
  id: "",
  label: "",
  args: "",
  log: "",
  startedAt: 0,
  updatedAt: 0,
  finishedAt: 0,
  status: "idle",
  subscriptionBaselineKnown: false,
  subscriptionBaselineAttemptEpoch: 0,
  subscriptionBaselineGenerationId: "none",
  subscriptionBaselineResult: "never",
};

let operationCounter = 0;

export function createBackgroundOperationId(now = Date.now()): string {
  operationCounter = (operationCounter + 1) % 0x100000;
  const random = new Uint32Array(2);
  globalThis.crypto?.getRandomValues?.(random);
  if (random[0] === 0 && random[1] === 0) {
    random[0] = Math.floor(Math.random() * 0xffffffff);
    random[1] = Math.floor(Math.random() * 0xffffffff);
  }
  return `${now.toString(36)}-${operationCounter.toString(36)}-${random[0].toString(36)}${random[1].toString(36)}`;
}

export function formatBackgroundTime(value: number): string {
  if (!value) return "-";
  return new Date(value).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

export function formatBackgroundDuration(task: BackgroundTaskState): string {
  if (!task.startedAt) return "-";
  const end = task.finishedAt || task.updatedAt || Date.now();
  const seconds = Math.max(0, Math.round((end - task.startedAt) / 1000));
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return minutes ? `${minutes}m ${rest}s` : `${rest}s`;
}

export function backgroundLogPath(label: string, operationId: string): string {
  const logName = label
    .replace(/[^\p{L}\p{N}._-]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase() || "task";
  const safeId = operationId.replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 96);
  return `${MODULE_DIR}/.log/webui-${logName}-${safeId || "invalid-operation"}.log`;
}

export function backgroundLaunchCommand(
  args: string,
  label: string,
  log: string,
  operationId: string,
  cleanupCommand = "",
): string {
  const cleanup = cleanupCommand
    ? `cleanup() { if ! { ${cleanupCommand}; }; then echo "[warning] background cleanup failed"; fi; }`
    : "cleanup() { :; }";
  const body = [
    cleanup,
    `trap 'cleanup' EXIT`,
    `trap 'exit 129' HUP`,
    `trap 'exit 130' INT`,
    `trap 'exit 143' TERM`,
    `echo ${shellQuote(`[launch] id=${operationId} label=${label}`)}`,
    `${CLI} ${args}`,
    `status=$?`,
    `trap - EXIT HUP INT TERM`,
    `cleanup`,
    `echo "[exit] id=${operationId} status=$status"`,
    `exit $status`,
  ].join("; ");
  const logDir = shellQuote(`${MODULE_DIR}/.log`);
  const logFile = shellQuote(log);
  const accepted = shellQuote(`[accepted] id=${operationId}`);
  const setupFailure = shellQuote(`[error] background launch setup failed: ${label}`);
  const missingLauncher = shellQuote(`[error] background launcher unavailable: nohup`);
  // Check all foreground preparation before emitting the accepted marker. The
  // previous `; ... & echo accepted` chain reported success even when the log
  // directory could not be created, leaving the UI to reconcile a task that
  // had never been launched. Keep the log fd open across the background fork
  // so a permission/unlink race cannot make the child's redirection fail.
  return [
    `if ! mkdir -p ${logDir} || ! : >${logFile} || ! exec 9>>${logFile}; then echo ${setupFailure} >&2; exit 1; fi`,
    `if ! command -v nohup >/dev/null 2>&1 || ! command -v sh >/dev/null 2>&1; then exec 9>&-; echo ${missingLauncher} >&2; exit 127; fi`,
    `nohup sh -c ${shellQuote(body)} >&9 2>&1 </dev/null & _magicnet_background_pid=$!; exec 9>&-; case "$_magicnet_background_pid" in ''|*[!0-9]*) echo ${setupFailure} >&2; exit 1;; esac; echo ${accepted}`,
  ].join("; ");
}

export function backgroundLogCommand(log: string, args: string, operationId = ""): string {
  const logFile = shellQuote(log);
  const markerRead = operationId
    ? `{ grep -F ${shellQuote(`[launch] id=${operationId}`)} ${logFile} || true; grep -F ${shellQuote(`[exit] id=${operationId} status=`)} ${logFile} || true; tail -n 80 ${logFile}; }`
    : `tail -n 80 ${logFile}`;
  const parts = [
    `echo ${shellQuote(`[task log] id=${operationId || "unknown"} ${log}`)}`,
    `[ -f ${logFile} ] && ${markerRead} || echo "[info] waiting for task log..."`,
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

export function backgroundFailed(logs: string, operationId: string): boolean {
  return parseBackgroundCompletion(logs, operationId) === "error";
}

export function backgroundDone(logs: string, operationId: string): boolean {
  return parseBackgroundCompletion(logs, operationId) === "done";
}

export type BackgroundCompletion = "running" | "done" | "error";

export function backgroundAccepted(output: string, operationId: string): boolean {
  return output.split(/\r?\n/).some((line) => line.trim() === `[accepted] id=${operationId}`);
}

export function parseBackgroundCompletion(logs: string, operationId: string): BackgroundCompletion {
  const launched = logs.split(/\r?\n/).some((line) =>
    line.startsWith(`[launch] id=${operationId} `)
  );
  if (!launched) return "running";
  const matches = Array.from(logs.matchAll(/^\[exit\] id=([^\s]+) status=(-?\d+)\s*$/gm))
    .filter((match) => match[1] === operationId);
  const last = matches.at(-1);
  if (!last) return "running";
  return Number(last[2]) === 0 ? "done" : "error";
}

export function reconcileSubscriptionCompletion(
  task: Pick<BackgroundTaskState, "subscriptionBaselineKnown" | "subscriptionBaselineAttemptEpoch" | "subscriptionBaselineGenerationId" | "subscriptionBaselineResult">,
  current: { lastAttemptEpoch: number; lastGenerationId: string; lastResult: string },
): BackgroundCompletion {
  if (!task.subscriptionBaselineKnown) return "running";
  const attemptAdvanced = current.lastAttemptEpoch > task.subscriptionBaselineAttemptEpoch;
  const generationChanged = current.lastGenerationId !== "none"
    && current.lastGenerationId !== task.subscriptionBaselineGenerationId;
  if (!attemptAdvanced && !generationChanged) return "running";
  if (current.lastResult === "success") return "done";
  if (["failed", "interrupted"].includes(current.lastResult)) return "error";
  return "running";
}

export function isSubscriptionBackgroundArgs(args: string): boolean {
  return /(?:^|\s)sub\s+(?:apply-file|update|update-all)\b/.test(args);
}

export function isActiveSubscriptionBackgroundTask(
  task: Pick<BackgroundTaskState, "status" | "args">,
): boolean {
  return task.status === "running" && isSubscriptionBackgroundArgs(task.args);
}

export function subscriptionLifecycleRunning(
  task: Pick<BackgroundTaskState, "status" | "args">,
  deviceUpdateRunning: boolean,
): boolean {
  return isActiveSubscriptionBackgroundTask(task) || deviceUpdateRunning;
}
