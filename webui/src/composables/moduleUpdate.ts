import { decodeMachineData, machineErrorCode } from "./machineStatus.ts";

export const MODULE_UPDATE_PHASES = ["idle", "checking", "available", "up_to_date", "downloading", "verifying", "installing", "reboot_required", "failed"] as const;
export type ModuleUpdatePhase = typeof MODULE_UPDATE_PHASES[number];
export type ModuleUpdateSnapshot = {
  installed: { version: string | null; version_code: number | null };
  latest: { version: string | null; version_code: number | null };
  update_available: boolean | null;
  phase: ModuleUpdatePhase;
  manager: "kernelsu" | "magisk" | "apatch" | "unknown";
  supported: boolean;
  busy: boolean;
  reboot_required: boolean;
  recovery_required: boolean;
  error_code: string | null;
  request_id: string | null;
};

type MachineResult = { ok: boolean; stdout: string; timedOut?: boolean };
type MachineRequest = (args: string) => Promise<MachineResult>;
const commands = ["module-update.status", "module-update.check", "module-update.install"];
const mutations = ["module-update.check", "module-update.install"];
const record = (value: unknown): value is Record<string, unknown> => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const version = (value: unknown): value is string => typeof value === "string" && /^v[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$/.test(value);
const requestId = (value: unknown): value is string => typeof value === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(value);
const errorCode = (value: unknown): value is string => typeof value === "string" && /^module-update\.[a-z][a-z0-9_.-]{0,63}$/.test(value);

export function moduleUpdateCapabilities(text: string): boolean {
  const data = decodeMachineData(text, "machine.capabilities");
  const available = data?.commands;
  const writable = data?.mutation_commands;
  return Array.isArray(available) && commands.every(command => available.includes(command)) &&
    Array.isArray(writable) && mutations.every(command => writable.includes(command));
}

export function parseModuleUpdate(text: string, command = "module-update.status"): ModuleUpdateSnapshot | null {
  const data = decodeMachineData(text, command);
  if (!data || !record(data.installed) || !record(data.latest)) return null;
  for (const value of [data.installed, data.latest]) {
    if ((value.version !== null && !version(value.version)) ||
      (value.version_code !== null && (!Number.isSafeInteger(value.version_code) || (value.version_code as number) < 0))) return null;
  }
  if ((data.update_available !== null && typeof data.update_available !== "boolean") ||
    typeof data.phase !== "string" || !MODULE_UPDATE_PHASES.includes(data.phase as ModuleUpdatePhase) ||
    typeof data.manager !== "string" || !["kernelsu", "magisk", "apatch", "unknown"].includes(data.manager) ||
    [data.supported, data.busy, data.reboot_required, data.recovery_required].some(value => typeof value !== "boolean") ||
    (data.error_code !== null && !errorCode(data.error_code)) ||
    (data.request_id !== null && !requestId(data.request_id))) return null;
  if ((data.supported && data.manager === "unknown") ||
    (data.update_available === true && (!data.installed.version || !data.latest.version || data.installed.version === data.latest.version)) ||
    (data.phase === "reboot_required" && data.reboot_required !== true)) return null;
  // Only explicitly allowed values enter presentation state; ignore unknown fields.
  return {
    installed: { version: data.installed.version as string | null, version_code: data.installed.version_code as number | null },
    latest: { version: data.latest.version as string | null, version_code: data.latest.version_code as number | null },
    update_available: data.update_available as boolean | null,
    phase: data.phase as ModuleUpdatePhase,
    manager: data.manager as ModuleUpdateSnapshot["manager"],
    supported: data.supported as boolean,
    busy: data.busy as boolean,
    reboot_required: data.reboot_required as boolean,
    recovery_required: data.recovery_required as boolean,
    error_code: data.error_code as string | null,
    request_id: data.request_id as string | null,
  };
}

export function moduleUpdateCanInstall(snapshot: ModuleUpdateSnapshot | null): boolean {
  return Boolean(snapshot?.supported && snapshot.manager !== "unknown" && snapshot.update_available === true &&
    version(snapshot.installed.version) && version(snapshot.latest.version) && snapshot.installed.version !== snapshot.latest.version &&
    !["checking", "downloading", "verifying", "installing"].includes(snapshot.phase) &&
    !snapshot.busy && !snapshot.reboot_required && !snapshot.recovery_required);
}

export class ModuleUpdateError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.code = code; }
}

/** Explicit capability negotiation: unsupported versions never reach a write. */
export function createModuleUpdateClient(request: MachineRequest) {
  let negotiated = false;
  async function invoke(args: string, command: string, expectedRequestId?: string) {
    let result: MachineResult;
    try { result = await request(args); }
    catch { throw new ModuleUpdateError("module-update.request_failed"); }
    if (!result.ok) {
      const code = machineErrorCode(result.stdout);
      throw new ModuleUpdateError(result.timedOut ? "module-update.request_unconfirmed" : errorCode(code) ? code : "module-update.request_failed");
    }
    const snapshot = parseModuleUpdate(result.stdout, command);
    if (!snapshot || (expectedRequestId && snapshot.request_id !== expectedRequestId)) throw new ModuleUpdateError("module-update.invalid_response");
    return snapshot;
  }
  return {
    async discover() {
      negotiated = false;
      let result: MachineResult;
      try { result = await request("--json capabilities"); }
      catch { throw new ModuleUpdateError("module-update.request_failed"); }
      if (!result.ok && machineErrorCode(result.stdout) !== "machine.unsupported_command") throw new ModuleUpdateError("module-update.request_failed");
      negotiated = result.ok && moduleUpdateCapabilities(result.stdout);
      return negotiated;
    },
    async read() {
      if (!negotiated) throw new ModuleUpdateError("module-update.unsupported_client");
      return invoke("--json module-update status", "module-update.status");
    },
    async check(id: string) {
      if (!negotiated) throw new ModuleUpdateError("module-update.unsupported_client");
      if (!requestId(id)) throw new ModuleUpdateError("module-update.invalid_request");
      return invoke(`--json module-update check ${id}`, "module-update.check", id);
    },
    async install(snapshot: ModuleUpdateSnapshot, id: string) {
      if (!negotiated) throw new ModuleUpdateError("module-update.unsupported_client");
      if (!moduleUpdateCanInstall(snapshot) || !requestId(id)) throw new ModuleUpdateError("module-update.invalid_request");
      return invoke(`--json module-update install ${snapshot.installed.version} ${snapshot.latest.version} ${id}`, "module-update.install", id);
    },
  };
}
