import { decodeMachineData } from "@/composables/machineStatus.ts";

const playPackages = new Set(["com.android.vending", "com.google.android.gms", "com.google.android.gsf"]);
export type RecoveryAction = "repair" | "reapply" | "rollback";
export type PlayPolicy = {
  candidate: string;
  provider: "android" | "oplus";
  packages: string[];
  configured: string;
  phase: string;
  writable: boolean;
  observed: string;
};

function object(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
function identity(value: unknown): value is Record<string, unknown> & { candidate: string; provider: "android" | "oplus"; packages: string[] } {
  return object(value) && typeof value.candidate === "string" && /^[a-f0-9]{64}$/.test(value.candidate)
    && ["android", "oplus"].includes(String(value.provider)) && Array.isArray(value.packages)
    && value.packages.length <= 128
    && value.packages.every((p, i, list) => typeof p === "string" && p.length <= 255
      && /^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$/.test(p) && (i === 0 || list[i - 1] < p));
}
export function parsePlayPolicies(text: string): { rows: PlayPolicy[]; observed: boolean } | null {
  const data = decodeMachineData(text, "network-access.inspect");
  if (!data || !Array.isArray(data.entries) || data.entries.length > 32768
    || !Array.isArray(data.providers) || !object(data.recovery)
    || data.recovery.status !== "observed" || !Array.isArray(data.recovery.records)
    || data.recovery.records.length > 128) return null;
  const rows = new Map<string, PlayPolicy>();
  for (const item of data.entries) {
    // Other providers may report system identities without an app package name.
    if (!object(item) || !Array.isArray(item.packages)) return null;
    if (!item.packages.some(p => typeof p === "string" && playPackages.has(p))) continue;
    if (!identity(item) || !object(item) || typeof item.configured !== "string"
      || typeof item.manual_repair_supported !== "boolean") return null;
    rows.set(item.candidate, {
      candidate: item.candidate, provider: item.provider, packages: item.packages.slice(),
      configured: item.configured, phase: "new", writable: item.manual_repair_supported, observed: "not_probed",
    });
  }
  for (const item of data.recovery.records) {
    if (!identity(item) || item.packages.length === 0 || !object(item) || !["prepared", "applied", "rollback_prepared", "rolled_back"].includes(String(item.recorded_phase))) return null;
    if (!item.packages.some(p => playPackages.has(p))) continue;
    const existing = rows.get(item.candidate);
    rows.set(item.candidate, existing ? { ...existing, phase: String(item.recorded_phase) } : {
      candidate: item.candidate, provider: item.provider, packages: item.packages.slice(),
      configured: "not_probed", phase: String(item.recorded_phase), writable: false, observed: "not_probed",
    });
  }
  return {
    rows: [...rows.values()],
    observed: data.package_inventory === "observed" && data.providers.some(p => object(p) && p.provider === "oplus" && p.status === "observed"),
  };
}
export function recoveryCommand(action: RecoveryAction | "check", candidate: string): string {
  if (!["repair", "reapply", "rollback", "check"].includes(action) || !/^[a-f0-9]{64}$/.test(candidate)) throw new Error("invalid recovery action");
  return `--json network-access ${action} ${candidate}${action === "check" ? "" : " --confirm"}`;
}
export function checkedPolicy(text: string, candidate: string): string {
  const data = decodeMachineData(text, "network-access.check");
  if (!data || data.candidate !== candidate || !["original_policy", "recovered_policy", "policy_conflict"].includes(String(data.observed_policy))) return "unknown";
  return String(data.observed_policy);
}
export function availableRecoveryActions(row: PlayPolicy): RecoveryAction[] {
  if (row.phase === "new") return row.writable ? ["repair"] : [];
  if (row.observed === "unknown" || row.observed === "not_probed" || row.observed === "policy_conflict") return [];
  if (row.phase === "applied") return row.observed === "original_policy" ? ["reapply", "rollback"] : ["rollback"];
  if (row.phase === "prepared" || row.phase === "rollback_prepared") return ["rollback"];
  return row.writable && row.observed === "original_policy" ? ["repair"] : [];
}
