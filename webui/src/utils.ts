import { OUTPUT_RENDER_LIMIT } from "./constants";
import type { ExecResult } from "./types";

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

export function normalizeExecResult(result: ExecResult): string {
  const stdout = result.stdout || result.out || "";
  const stderr = result.stderr || result.err || "";
  const text = [stdout, stderr].filter(Boolean).join("\n").trim();
  if (result.errno && result.errno !== 0) return `[error] errno=${result.errno}\n${text}`.trim();
  return text;
}

export function execFailed(text: string): boolean {
  const trimmed = text.trimStart();
  return !text
    || trimmed.startsWith("[error]")
    || trimmed.startsWith("Usage:")
    || trimmed.includes("KernelSU 执行通道")
    || /^Error:/im.test(trimmed)
    || /^error:/im.test(trimmed)
    || /^✗/m.test(trimmed);
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

export function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer = 0;
  const timeout = new Promise<never>((_, reject) => {
    timer = window.setTimeout(() => {
      reject(new Error(`${label} 超过 ${Math.round(ms / 1000)} 秒仍未返回，请到“输出”页查看日志或稍后重试。`));
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
