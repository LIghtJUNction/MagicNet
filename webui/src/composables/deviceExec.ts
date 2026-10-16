import { t } from "@/i18n";
import type { ExecResult } from "../types.ts";
import { normalizeExitCode } from "../utils.ts";

type SpawnBridge = {
  spawn(command: string, args: string, options: string, callback: string): void;
};

let callbackCounter = 0;

// Bound retained UTF-16 data and array overhead independently, across both
// streams. These are collector limits, not a claim about native/WebView RSS.
const MAX_OUTPUT_UNITS = 8 * 1024 * 1024;
const MAX_OUTPUT_ENTRIES = 64 * 1024;

class ExecOutputLimitError extends Error {
  constructor() {
    super(t("命令输出超过安全上限，已丢弃。命令可能已更改设备，请检查状态后再重试。"));
    this.name = "ExecOutputLimitError";
  }
}

function spawnBridge(): SpawnBridge | undefined {
  const bridge = (globalThis as { ksu?: SpawnBridge }).ksu;
  return typeof bridge?.spawn === "function" ? bridge : undefined;
}

export function hasAsyncExec(): boolean {
  return Boolean(spawnBridge());
}

/** KernelSU exec waits inside the native bridge; only spawn submits asynchronously. */
export function execAsync(command: string): Promise<ExecResult> {
  return new Promise((resolve, reject) => {
    const bridge = spawnBridge();
    if (!bridge) {
      reject(new Error(t("当前管理器缺少 KernelSU 异步执行接口，请更新管理器后重试。")));
      return;
    }

    const name = `magicnet_spawn_${Date.now()}_${callbackCounter++}`;
    const callbacks = window as unknown as Record<string, unknown>;
    const stdout: string[] = [];
    const stderr: string[] = [];
    let settled = false;
    let outputUnits = 0;
    let outputEntries = 0;
    let outputError: ExecOutputLimitError | undefined;
    function clearOutput(): void {
      stdout.length = 0;
      stderr.length = 0;
    }
    function collect(stream: string[], event: string, line: string): void {
      if (settled || outputError || event !== "data") return;
      const nextUnits = outputUnits + line.length + Number(stream.length > 0);
      if (nextUnits > MAX_OUTPUT_UNITS || outputEntries >= MAX_OUTPUT_ENTRIES) {
        outputError = new ExecOutputLimitError();
        clearOutput();
        // Do not settle here: the queue still owns this native operation until
        // exit/error. Discard further output without releasing its serial slot.
        return;
      }
      outputUnits = nextUnits;
      outputEntries += 1;
      stream.push(line);
    }
    function finish(error?: unknown, errno = -1): void {
      if (settled) return;
      settled = true;
      delete callbacks[name];
      const failure = outputError ?? error;
      if (failure !== undefined) {
        clearOutput();
        reject(failure);
      } else {
        const result = { errno, stdout: stdout.join("\n"), stderr: stderr.join("\n") };
        clearOutput();
        resolve(result);
      }
    }

    // Register before calling native spawn. The SDK emits synchronous launch
    // errors before callers can attach listeners to its returned ChildProcess.
    callbacks[name] = {
      stdout: { emit: (event: string, line: string) => collect(stdout, event, line) },
      stderr: { emit: (event: string, line: string) => collect(stderr, event, line) },
      emit: (event: string, value: unknown) => {
        if (event === "exit") finish(undefined, normalizeExitCode(value));
        else if (event === "error") finish(value ?? new Error(t("KernelSU 启动命令失败。")));
      },
    };
    try {
      // Native spawn joins arguments as shell text; keep the existing quoted
      // command intact instead of passing argv as if this were execFile.
      bridge.spawn(command, "[]", "{}", name);
    } catch (error) {
      finish(error);
    }
  });
}
