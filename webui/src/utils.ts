import { OUTPUT_RENDER_LIMIT } from "./constants.ts";
import type { ExecResult } from "./types.ts";

export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

export function intentDataQuote(value: string): string {
  return `"${value.replace(/(["\\$`])/g, "\\$1")}"`;
}

const SENSITIVE_URL_COMPONENT = /(token|secret|signature|expires|x-amz-|x-oss-|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token)/i;
const SENSITIVE_TEXT_URL = /https?:\/\/[^\s<>"'`\u3002\uff0c\uff1b\uff1a\uff01\uff1f\uff08\uff09]+/gi;
const SENSITIVE_AUTHORIZATION_BEARER = /(["']?(?:proxy-)?authorization["']?\s*[:=]\s*)bearer\s+(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}\]\u3002\uff0c\uff1b\uff1a\uff01\uff1f\uff08\uff09]+)/gi;
const SENSITIVE_AUTHORIZATION_VALUE = /(["']?(?:proxy-)?authorization["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\r\n,;}\]\u3002\uff0c\uff1b\uff1a\uff01\uff1f\uff08\uff09]+)/gi;
const SENSITIVE_TEXT_VALUE = /(["']?(?:password|passwd|token|secret|signature|expires|credential|x-amz-[a-z-]+|x-oss-[a-z-]+|api[_-]?key|access[_-]?token|refresh[_-]?token|key)["']?\s*[:=]\s*)["']?[^"',\s;}\]\u3002\uff0c\uff1b\uff1a\uff01\uff1f\uff08\uff09]+["']?/gi;
const SENSITIVE_BEARER = /\bbearer\s+(?:"[^"\r\n]*"|'[^'\r\n]*'|[A-Za-z0-9._~+/-]+=*)/gi;

/**
 * A URL with credentials, a query/fragment, or a recognised signing parameter
 * must not be copied or echoed by generic external-link UI. Query and fragment
 * values are treated as sensitive conservatively: a download URL can carry a
 * short-lived credential under an arbitrary parameter name.
 */
export function isSensitiveExternalUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return Boolean(
      parsed.username
      || parsed.password
      || parsed.search
      || parsed.hash
      || SENSITIVE_URL_COMPONENT.test(value),
    );
  } catch {
    return SENSITIVE_URL_COMPONENT.test(value);
  }
}

/**
 * Preserve ordinary descriptive text while removing URLs and token-shaped
 * values that could grant access if a user pastes them into a shareable draft.
 */
export function redactSensitiveText(value: string): string {
  return value
    .replace(SENSITIVE_TEXT_URL, (rawUrl) => {
      const trailing = rawUrl.match(/[),.;!?]+$/)?.[0] || "";
      const url = trailing ? rawUrl.slice(0, -trailing.length) : rawUrl;
      return isSensitiveExternalUrl(url) ? `[filtered-url]${trailing}` : rawUrl;
    })
    // Match a complete Bearer credential before generic header handling can
    // consume only the scheme and leave its token behind.
    .replace(SENSITIVE_AUTHORIZATION_BEARER, "$1Bearer [filtered]")
    .replace(SENSITIVE_AUTHORIZATION_VALUE, "$1[filtered]")
    .replace(SENSITIVE_TEXT_VALUE, "$1[filtered]")
    .replace(SENSITIVE_BEARER, "bearer [filtered]")
    .replace(/\b(?:gho|ghp|github_pat)_[A-Za-z0-9_]+/g, "[filtered-token]")
    .replace(/\bsk-[A-Za-z0-9_-]+/g, "[filtered-token]");
}

/**
 * Yield chunks of at most `size` UTF-16 code units, never cutting a surrogate
 * pair across a boundary — so a chunk written on its own can always be
 * re-encoded to valid UTF-8. A generator lets callers hand one encoded chunk
 * at a time to the device-side private-payload helper instead of making a
 * second full copy of a potentially multi-MB payload. A size below two cannot
 * represent a surrogate pair, so it is rejected instead of risking an empty
 * chunk and a stalled writer.
 */
export function* chunkSurrogateSafe(text: string, size: number): Generator<string> {
  if (!Number.isSafeInteger(size) || size < 2) {
    throw new RangeError("chunk size must be an integer of at least 2");
  }
  for (let offset = 0; offset < text.length; ) {
    let end = Math.min(offset + size, text.length);
    const boundary = text.charCodeAt(end - 1);
    if (end < text.length && boundary >= 0xd800 && boundary <= 0xdbff) end -= 1;
    yield text.slice(offset, end);
    offset = end;
  }
}

/**
 * Redacted `lastCommand` preview for a CLI invocation whose real arguments
 * carry a secret. Preserve a safe `cli` token so issue diagnostics can classify
 * the operation without retaining the executable path or private arguments.
 */
export function redactedCliPreview(displayArgs: string): string {
  return `su -M -c '… cli ${displayArgs}'`;
}

export function compactOutput(value: string, limit = OUTPUT_RENDER_LIMIT): string {
  if (value.length <= limit) return value;
  const head = value.slice(0, Math.floor(limit * 0.58));
  const tail = value.slice(value.length - Math.floor(limit * 0.32));
  return `${head}\n\n... 输出过长，已折叠中间 ${value.length - head.length - tail.length} 个字符 ...\n\n${tail}`;
}

export function compactCommand(value: string, limit = 420): string {
  if (value.length <= limit) return value;
  const head = value.slice(0, Math.floor(limit * 0.55));
  const tail = value.slice(value.length - Math.floor(limit * 0.25));
  return `${head} ... [${value.length - head.length - tail.length} chars hidden] ... ${tail}`;
}

export type ExecOutcome = {
  ok: boolean;
  timedOut: boolean;
  errno: number;
  stdout: string;
  stderr: string;
  text: string;
};

export type PrivatePayloadNamespace = "tmp" | "subscription";
export type PrivatePayloadAction = "create" | "append" | "remove";

export type PrivatePayloadHandle = {
  namespace: PrivatePayloadNamespace;
  basename: string;
  path: string;
};

export type PrivatePayloadRunner = (
  args: string,
  label: string,
  redactedPreview: string,
) => Promise<Pick<ExecOutcome, "ok" | "stdout">>;

const PRIVATE_PAYLOAD_BASENAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const BASE64_CHUNK = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export function isSafePrivatePayloadBasename(value: string): boolean {
  return PRIVATE_PAYLOAD_BASENAME.test(value);
}

/** Build the only frontend-to-device private-payload command shape. */
export function buildPrivatePayloadCommand(
  action: PrivatePayloadAction,
  namespace: PrivatePayloadNamespace,
  basename: string,
  base64Chunk?: string,
): string {
  if (!isSafePrivatePayloadBasename(basename)) {
    throw new RangeError("private payload basename is invalid");
  }
  if (action !== "append" && base64Chunk !== undefined) {
    throw new RangeError(action + " does not accept a payload chunk");
  }
  if (action === "append" && (!base64Chunk || !BASE64_CHUNK.test(base64Chunk))) {
    throw new RangeError("private payload chunk must be base64");
  }
  const chunk = base64Chunk === undefined ? "" : " " + shellQuote(base64Chunk);
  return "webui payload " + action + " " + namespace + " " + shellQuote(basename) + chunk;
}

export function buildPrivateSubscriptionApplyCommand(basename: string): string {
  if (!isSafePrivatePayloadBasename(basename)) {
    throw new RangeError("private payload basename is invalid");
  }
  return "webui payload apply-subscription " + shellQuote(basename);
}

export function buildPrivateSubscriptionSourceApplyCommand(basename: string): string {
  if (!isSafePrivatePayloadBasename(basename)) {
    throw new RangeError("private payload basename is invalid");
  }
  return "webui payload apply-subscription-source " + shellQuote(basename);
}

/**
 * Accept only the backend's one-line controlled absolute path. It remains in
 * local memory and is used solely as an argument to the existing file-path
 * command; it is never a display value.
 */
export function parsePrivatePayloadPath(
  stdout: string,
  moduleDir: string,
  namespace: PrivatePayloadNamespace,
  basename: string,
): string | null {
  const lines = stdout.split(/\r?\n/);
  if (lines[lines.length - 1] === "") lines.pop();
  if (lines.length !== 1) return null;
  const path = lines[0];
  const root = moduleDir.endsWith("/") ? moduleDir.slice(0, -1) : moduleDir;
  const directory = namespace === "tmp" ? "webui-payload" : "webui-subscription";
  const expected = `${root}/.tmp/${directory}/${basename}`;
  if (!path || /[\s\0]/.test(path) || path !== expected) return null;
  return path;
}

function privatePayloadPreview(action: string, namespace: PrivatePayloadNamespace): string {
  return redactedCliPreview("webui payload " + action + " " + namespace + " [private-payload]");
}

/**
 * Stream UTF-8 data through the device-side no-follow payload owner. Any
 * failed create/append path is removed through that same owner before callers
 * can invoke import/apply commands.
 */
export async function stagePrivatePayload(
  runPrivate: PrivatePayloadRunner,
  moduleDir: string,
  namespace: PrivatePayloadNamespace,
  basename: string,
  payload: string,
  label: string,
  chunkSize = 32 * 1024,
): Promise<PrivatePayloadHandle | null> {
  let created: Pick<ExecOutcome, "ok" | "stdout">;
  try {
    created = await runPrivate(
      buildPrivatePayloadCommand("create", namespace, basename),
      "准备" + label,
      privatePayloadPreview("create", namespace),
    );
  } catch {
    return null;
  }
  if (!created.ok) return null;

  const path = parsePrivatePayloadPath(created.stdout, moduleDir, namespace, basename);
  if (!path) {
    await removePrivatePayload(runPrivate, namespace, basename, label);
    return null;
  }

  try {
    const encoder = new TextEncoder();
    for (const textChunk of chunkSurrogateSafe(payload, chunkSize)) {
      const base64Chunk = bytesToBase64(encoder.encode(textChunk));
      const appended = await runPrivate(
        buildPrivatePayloadCommand("append", namespace, basename, base64Chunk),
        "写入" + label,
        privatePayloadPreview("append", namespace),
      );
      if (!appended.ok) {
        await removePrivatePayload(runPrivate, namespace, basename, label);
        return null;
      }
    }
  } catch {
    await removePrivatePayload(runPrivate, namespace, basename, label);
    return null;
  }

  return { namespace, basename, path };
}

export async function removePrivatePayload(
  runPrivate: PrivatePayloadRunner,
  namespace: PrivatePayloadNamespace,
  basename: string,
  label: string,
): Promise<boolean> {
  try {
    const outcome = await runPrivate(
      buildPrivatePayloadCommand("remove", namespace, basename),
      "清理" + label,
      privatePayloadPreview("remove", namespace),
    );
    return outcome.ok;
  } catch {
    return false;
  }
}

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
