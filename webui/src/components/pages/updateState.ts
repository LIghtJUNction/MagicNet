export type UpdateSettings = { enabled: boolean; interval_hours: number; wifi_only: boolean };
export type ComponentUpdate = { id: string; sha256: string; size: number; source: "installed" | "cache" | "download" };
export type UpdatePlan = { version: string; core_source: string; core_bytes: number; download_bytes: number; reuse_bytes: number; components: ComponentUpdate[] };
export type UpdateStatus = {
  schema: number; settings: UpdateSettings; current_version: string; pending_version: string;
  phase: string; last_attempt: number; last_check: number; next_check: number; last_success: number;
  failures: number; transferred_bytes: number; running: boolean; error: string; plan: UpdatePlan | null;
};
const phases = new Set(["idle", "checking", "available", "current", "preparing", "installing", "ready", "pending_reboot", "waiting_wifi", "interrupted", "error"]);
const sources = new Set(["installed", "cache", "download"]);
const record = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const count = (value: unknown): value is number => Number.isSafeInteger(value) && Number(value) >= 0;
const version = (value: unknown): value is string => typeof value === "string" && (value === "" || /^v\d+\.\d+\.\d+$/.test(value));

export function parseUpdateStatus(raw: string): UpdateStatus | null {
  let value: unknown;
  try { value = JSON.parse(raw); } catch { return null; }
  if (!record(value) || value.schema !== 1 || !record(value.settings)) return null;
  const settings = value.settings;
  if (typeof settings.enabled !== "boolean" || typeof settings.wifi_only !== "boolean"
    || !count(settings.interval_hours) || settings.interval_hours < 1 || settings.interval_hours > 168) return null;
  if (!version(value.current_version) || !version(value.pending_version) || typeof value.phase !== "string"
    || !phases.has(value.phase) || typeof value.running !== "boolean" || typeof value.error !== "string") return null;
  for (const key of ["last_attempt", "last_check", "next_check", "last_success", "failures", "transferred_bytes"]) {
    if (!count(value[key])) return null;
  }
  for (const key of ["last_attempt", "last_check", "next_check", "last_success"]) {
    if (Number(value[key]) > 8_640_000_000_000) return null;
  }
  if (value.plan !== null) {
    const plan = value.plan;
    if (!record(plan) || !version(plan.version) || plan.version === "" || typeof plan.core_source !== "string"
      || !sources.has(plan.core_source) || !count(plan.core_bytes) || !count(plan.download_bytes) || !count(plan.reuse_bytes)
      || !Array.isArray(plan.components) || plan.components.length > 128) return null;
    const ids = new Set<string>();
    for (const component of plan.components) {
      if (!record(component) || typeof component.id !== "string" || !/^[A-Za-z0-9_.-]+$/.test(component.id)
        || ids.has(component.id) || typeof component.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(component.sha256)
        || !count(component.size) || typeof component.source !== "string" || !sources.has(component.source)) return null;
      ids.add(component.id);
    }
  }
  return value as unknown as UpdateStatus;
}

export function configureUpdateCommand(settings: UpdateSettings): string {
  if (typeof settings.enabled !== "boolean" || typeof settings.wifi_only !== "boolean"
    || !Number.isInteger(settings.interval_hours) || settings.interval_hours < 1 || settings.interval_hours > 168) {
    throw new Error("Invalid update settings");
  }
  return `update configure ${Number(settings.enabled)} ${settings.interval_hours} ${Number(settings.wifi_only)}`;
}
export function updateBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}
