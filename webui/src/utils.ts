import { OUTPUT_RENDER_LIMIT } from "./constants.ts";
import type { ExecResult } from "./types.ts";

export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

export function intentDataQuote(value: string): string {
  return `"${value.replace(/(["\\$`])/g, "\\$1")}"`;
}

export function compactOutput(value: string, limit = OUTPUT_RENDER_LIMIT): string {
  if (value.length <= limit) return value;
  const head = value.slice(0, Math.floor(limit * 0.58));
  const tail = value.slice(value.length - Math.floor(limit * 0.32));
  return `${head}\n\n... 输出过长，已折叠中间 ${value.length - head.length - tail.length} 个字符 ...\n\n${tail}`;
}

export function compactCommand(value: string, limit = 420): string {
  if (value.length <= limit) return value;
  return `${value.slice(0, Math.floor(limit * 0.55))} ... [${value.length - limit} chars hidden] ... ${value.slice(-Math.floor(limit * 0.25))}`;
}

export type ExecOutcome = {
  ok: boolean;
  timedOut: boolean;
  errno: number;
  stdout: string;
  stderr: string;
  text: string;
};

export function normalizeExecOutcome(result: ExecResult): ExecOutcome {
  const errno = typeof result.errno === "number" ? result.errno : 0;
  const stdout = result.stdout || result.out || "";
  const stderr = result.stderr || result.err || "";
  const text = [stdout, stderr].filter(Boolean).join("\n").trim();
  return {
    ok: errno === 0,
    timedOut: false,
    errno,
    stdout,
    stderr,
    text: errno === 0 ? text : `[error] errno=${errno}\n${text}`.trim(),
  };
}

export function unavailableExecOutcome(_commandPreview = ""): ExecOutcome {
  const detail = "KernelSU execution unavailable; command was not run";
  return {
    ok: false,
    timedOut: false,
    errno: -1,
    stdout: "",
    stderr: detail,
    text: `[error] unavailable: ${detail}`,
  };
}

export function normalizeExecResult(result: ExecResult): string {
  return normalizeExecOutcome(result).text;
}

export function execFailed(text: string): boolean {
  const trimmed = text.trimStart();
  return /^\[error\]\s+(?:errno=-?\d+|unavailable:)(?:\s|$)/i.test(trimmed)
    || /^\[exec-timeout\](?:\s|$)/i.test(trimmed);
}

export function probeFailed(text: string): boolean {
  return execFailed(text)
    || /\b(failed|fail|curl:|not reachable|Connection refused|Could not connect)\b/i.test(text);
}

export function nextFrame(): Promise<void> {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}

export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard?.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export async function readClipboardText(): Promise<string> {
  return await navigator.clipboard?.readText?.() || "";
}

export class ExecTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ExecTimeoutError";
  }
}

export function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer = 0;
  const timeout = new Promise<never>((_, reject) => {
    timer = window.setTimeout(() => {
      reject(new ExecTimeoutError(`${label} 超过 ${Math.round(ms / 1000)} 秒仍未返回，请到“输出”页查看日志或稍后重试。`));
    }, ms);
  });
  return Promise.race([promise, timeout]).finally(() => window.clearTimeout(timer));
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary);
}

export function uniqueNonEmpty(values: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  values.forEach((value) => {
    const item = value.trim();
    if (!item || seen.has(item)) return;
    seen.add(item);
    result.push(item);
  });
  return result;
}
