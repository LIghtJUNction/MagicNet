import {
  buildPrivateSubscriptionApplyCommand,
  redactedCliPreview,
  uniqueNonEmpty,
} from "../../utils.ts";

export type SubscriptionPreview = {
  key: string;
  index: number;
  label: string;
  status: "ok" | "duplicate" | "invalid" | "over-limit";
  notes: string[];
};

export type SubscriptionInputSummary = {
  raw: number;
  valid: number;
  duplicate: number;
  overLimit: number;
};

export type SubscriptionSavePlan = {
  status: "idle" | "ok" | "warning" | "error";
  message: string;
  lines: string[];
  raw: number;
  valid: number;
  invalid: number;
  duplicate: number;
  overLimit: number;
  http: number;
};

export type PendingSubscriptionApply = {
  snapshot: string;
  revision: number;
};

export type SubscriptionEditorReconcileInput = {
  draft: string;
  lastLoadedSnapshot: string;
  deviceSnapshot: string;
  dirty: boolean;
  loadedOnce: boolean;
  editRevision: number;
  pendingApply: PendingSubscriptionApply | null;
};

export type SubscriptionEditorReconcileResult = {
  draft: string;
  lastLoadedSnapshot: string;
  dirty: boolean;
  loadedOnce: boolean;
  pendingApply: PendingSubscriptionApply | null;
  syncedDraft: boolean;
};

export function reconcileSubscriptionEditor(
  input: SubscriptionEditorReconcileInput,
): SubscriptionEditorReconcileResult {
  const acceptedPending = Boolean(
    input.pendingApply && input.deviceSnapshot === input.pendingApply.snapshot,
  );
  const maySyncAccepted = Boolean(
    acceptedPending
      && input.pendingApply
      && input.editRevision === input.pendingApply.revision
      && input.draft === input.pendingApply.snapshot,
  );
  const syncOrdinary = !input.loadedOnce || (!input.dirty && !input.pendingApply);
  const syncedDraft = maySyncAccepted || syncOrdinary;
  const draft = syncedDraft ? input.deviceSnapshot : input.draft;
  return {
    draft,
    lastLoadedSnapshot: input.deviceSnapshot,
    dirty: draft !== input.deviceSnapshot,
    loadedOnce: true,
    pendingApply: acceptedPending ? null : input.pendingApply,
    syncedDraft,
  };
}

export type SubscriptionApplyLaunch = {
  args: string;
  displayArgs: string;
  preview: string;
  lifecycleArgs: string;
};

export function buildSubscriptionApplyLaunch(basename: string): SubscriptionApplyLaunch {
  return {
    args: buildPrivateSubscriptionApplyCommand(basename),
    displayArgs: "webui payload apply-subscription [private-payload]",
    preview: redactedCliPreview("webui payload apply-subscription [private-payload]"),
    // Existing lifecycle reconciliation recognises the public subscription
    // operation, while the actual command stays private and no payload path is
    // rendered into task state.
    lifecycleArgs: "sub apply-file sing-box [redacted-payload]",
  };
}

export function summarizeSubscriptionInput(text: string, limit = 5): SubscriptionInputSummary {
  const raw = subscriptionLines(text);
  const validUrls = raw.map(parseSubscriptionLine).filter((item): item is URL => item instanceof URL);
  const uniqueUrls = uniqueNonEmpty(validUrls.map((url) => url.toString()));
  return {
    raw: raw.length,
    valid: validUrls.length,
    duplicate: Math.max(0, validUrls.length - uniqueUrls.length),
    overLimit: Math.max(0, uniqueUrls.length - limit)
  };
}

export function buildSubscriptionPreview(text: string, limit = 5): SubscriptionPreview[] {
  const seen = new Set<string>();
  return subscriptionLines(text).map((line, index) => previewSubscriptionLine(line, index, seen, limit));
}

export function buildSubscriptionSavePlan(text: string, limit = 5): SubscriptionSavePlan {
  const raw = subscriptionLines(text);
  if (!raw.length) return plan("idle", "请至少填写一个 sing-box 订阅 URL。", [], raw, limit);
  const parsed = raw.map(parseSubscriptionLine);
  const validUrls = parsed.filter((item): item is URL => item instanceof URL);
  const uniqueUrls = uniqueNonEmpty(validUrls.map((url) => url.toString()));
  const lines = uniqueUrls.slice(0, limit);
  const invalid = parsed.length - validUrls.length;
  const duplicate = Math.max(0, validUrls.length - uniqueUrls.length);
  const overLimit = Math.max(0, uniqueUrls.length - limit);
  const http = raw.filter((line) => /^http:\/\/\S+$/i.test(line)).length;
  if (invalid) {
    return {
      ...plan("error", `${invalid} 行不是 HTTPS 订阅 URL，或包含凭据；修正后才能保存。`, lines, raw, limit),
      valid: validUrls.length,
      invalid,
      duplicate,
      overLimit,
      http,
    };
  }
  if (!lines.length) return plan("error", "没有可保存的订阅 URL。", lines, raw, limit);
  if (overLimit || duplicate) {
    const notes = [
      duplicate ? `去重 ${duplicate} 个` : "",
      overLimit ? `只保存前 ${limit} 个唯一 URL` : "",
    ].filter(Boolean).join("，");
    return { ...plan("warning", notes, lines, raw, limit), duplicate, overLimit, http };
  }
  return plan("ok", `将保存 ${lines.length} 个订阅 URL。`, lines, raw, limit);
}

export function formatSubscriptionSummary(text: string, previews: SubscriptionPreview[]): string {
  const summary = summarizeSubscriptionInput(text);
  const savePlan = buildSubscriptionSavePlan(text);
  const omitted = Math.max(0, summary.raw - previews.length);
  return [
    "MagicNet subscription input summary",
    "privacy_note=full subscription URLs are omitted",
    `raw=${summary.raw}`,
    `valid=${summary.valid}`,
    `duplicate=${summary.duplicate}`,
    `over_limit=${summary.overLimit}`,
    `save_status=${savePlan.status}`,
    `save_count=${savePlan.lines.length}`,
    `invalid=${savePlan.invalid}`,
    `http=${savePlan.http}`,
    `save_message=${savePlan.message}`,
    `preview_count=${previews.length}`,
    `omitted_count=${omitted}`,
    "",
    "[sources]",
    ...previews.map((item) => `#${item.index} ${item.label} status=${item.status} notes=${item.notes.join(";")}`)
  ].join("\n").trim();
}

function previewSubscriptionLine(line: string, index: number, seen: Set<string>, limit: number): SubscriptionPreview {
  try {
    const url = parseSubscriptionLine(line);
    if (!url) throw new Error("invalid URL");
    const normalized = url.toString();
    const duplicate = seen.has(normalized);
    const uniqueCount = duplicate ? seen.size : seen.size + 1;
    seen.add(normalized);
    const protocolOk = url.protocol === "https:";
    const notes = [
      url.search || url.hash ? "含参数，界面已隐藏" : "无 query/hash",
      url.pathname.length > 1 ? "含路径，界面已隐藏" : "无路径",
      url.protocol === "http:" ? "设备侧仅支持 HTTPS" : ""
    ].filter(Boolean);
    return {
      key: `${index}-${url.hostname}`,
      index: index + 1,
      label: protocolOk ? `${url.protocol}//${url.hostname}` : "协议不支持",
      status: !protocolOk ? "invalid" : uniqueCount > limit ? "over-limit" : duplicate ? "duplicate" : "ok",
      notes
    };
  } catch {
    return {
      key: `${index}-invalid`,
      index: index + 1,
      label: "无法解析 URL",
      status: "invalid",
      notes: ["必须是一行一个 HTTPS URL，且不能包含凭据"]
    };
  }
}

function parseSubscriptionLine(line: string): URL | null {
  if (!isHttpsUrl(line)) return null;
  try {
    const url = new URL(line);
    return url.protocol === "https:" && !url.username && !url.password ? url : null;
  } catch {
    return null;
  }
}

function plan(status: SubscriptionSavePlan["status"], message: string, lines: string[], raw: string[], limit: number): SubscriptionSavePlan {
  const valid = raw.filter((line) => parseSubscriptionLine(line) !== null);
  const unique = uniqueNonEmpty(valid);
  return {
    status,
    message,
    lines,
    raw: raw.length,
    valid: valid.length,
    invalid: raw.length - valid.length,
    duplicate: Math.max(0, valid.length - unique.length),
    overLimit: Math.max(0, unique.length - limit),
    http: raw.filter((line) => /^http:\/\/\S+$/i.test(line)).length
  };
}

function subscriptionLines(text: string): string[] {
  return text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
}

function isHttpsUrl(line: string): boolean {
  return /^https:\/\/\S+$/i.test(line);
}
