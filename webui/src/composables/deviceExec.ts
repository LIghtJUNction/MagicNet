import type { ExecResult } from "../types.ts";

type SpawnBridge = {
  spawn(command: string, args: string, options: string, callback: string): void;
};

let callbackCounter = 0;

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
      reject(new Error("当前管理器缺少 KernelSU 异步执行接口，请更新管理器后重试。"));
      return;
    }

    const name = `magicnet_spawn_${Date.now()}_${callbackCounter++}`;
    const callbacks = window as unknown as Record<string, unknown>;
    const stdout: string[] = [];
    const stderr: string[] = [];
    let settled = false;
    function finish(error?: unknown, errno = -1): void {
      if (settled) return;
      settled = true;
      delete callbacks[name];
      if (error !== undefined) reject(error);
      else resolve({ errno, stdout: stdout.join("\n"), stderr: stderr.join("\n") });
    }

    // Register before calling native spawn. The SDK emits synchronous launch
    // errors before callers can attach listeners to its returned ChildProcess.
    callbacks[name] = {
      stdout: { emit: (event: string, line: string) => {
        if (!settled && event === "data") stdout.push(line);
      } },
      stderr: { emit: (event: string, line: string) => {
        if (!settled && event === "data") stderr.push(line);
      } },
      emit: (event: string, value: unknown) => {
        if (event === "exit") finish(undefined, Number(value));
        else if (event === "error") finish(value ?? new Error("KernelSU 启动命令失败。"));
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
