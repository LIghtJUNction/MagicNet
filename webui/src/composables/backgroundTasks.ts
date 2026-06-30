import { CLI, MODULE_DIR } from "@/constants";
import { shellQuote } from "@/utils";

export type BackgroundTaskStatus = "idle" | "running" | "done" | "error" | "timeout";

export type BackgroundTaskState = {
  label: string;
  args: string;
  log: string;
  startedAt: number;
  updatedAt: number;
  finishedAt: number;
  status: BackgroundTaskStatus;
};

export const backgroundTaskDefaults: BackgroundTaskState = {
  label: "",
  args: "",
  log: "",
  startedAt: 0,
  updatedAt: 0,
  finishedAt: 0,
  status: "idle",
};

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

export function backgroundLogPath(label: string): string {
  const logName = label
    .replace(/[^\p{L}\p{N}._-]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase() || "task";
  return `${MODULE_DIR}/.log/webui-${logName}.log`;
}

export function backgroundLaunchCommand(args: string, label: string, log: string): string {
  const body = [
    `echo ${shellQuote(`[info] background task started: ${label}`)}`,
    `${CLI} ${args}`,
    `status=$?`,
    `echo "[exit] status=$status"`,
    `exit $status`,
  ].join("; ");
  return `mkdir -p ${shellQuote(`${MODULE_DIR}/.log`)}; : >${shellQuote(log)}; nohup sh -c ${shellQuote(body)} >${shellQuote(log)} 2>&1 </dev/null & echo ${shellQuote(`[info] background task accepted: ${label}`)}`;
}

export function backgroundLogCommand(log: string, args: string): string {
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

export function backgroundFailed(logs: string): boolean {
  return logs.includes("[error]")
    || logs.includes("╳[error]")
    || /\[exit\] status=([1-9]\d*)/.test(logs)
    || /\b(not executable|failed with status|No subscription source is available)\b/i.test(logs);
}

export function backgroundDone(logs: string): boolean {
  return /\[exit\] status=0\b/.test(logs);
}
