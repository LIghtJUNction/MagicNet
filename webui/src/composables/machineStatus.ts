import { runtimeDefaults } from "./parsers.ts";
import type { DnsState, RuntimeState } from "../types.ts";

export type MachineEnvelope<T extends Record<string, unknown>> = {
  schema: 1;
  ok: true;
  command: string;
  data: T;
};

export type NetworkPolicyStatus = {
  configured: { ipv6_mode: string; mtu: number; udp_timeout: string };
  effective: { ipv6_mode: string; stack: string; mtu: number | null; udp_timeout: string };
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function machineObject(text: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(text.trim());
    return isRecord(value) ? value : null;
  } catch {
    // The native bridge may append stderr to the CLI's single-line stdout.
    // Never select one result from multiple, conflicting or truncated objects.
    const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    const candidates = lines.filter((line) => line.startsWith("{"));
    if (candidates.length !== 1 || lines.some((line) =>
      line !== candidates[0] && !/^\[(?:warn|info|debug|error)\]/i.test(line)
    )) return null;
    try {
      const value: unknown = JSON.parse(candidates[0]);
      return isRecord(value) ? value : null;
    } catch {
      return null;
    }
  }
}

export function decodeMachineData<T extends Record<string, unknown>>(
  text: string,
  expectedCommand: string,
): T | null {
  // An execution failure cannot be turned into success by a trailing JSON line.
  if (/^\s*\[error\]/im.test(text)) return null;
  const value = machineObject(text);
  if (!value || value.schema !== 1 || value.ok !== true || value.command !== expectedCommand)
    return null;
  return isRecord(value.data) ? value.data as T : null;
}

export function machineErrorCode(text: string): string {
  const value = machineObject(text);
  if (!value || value.schema !== 1 || value.ok !== false || !isRecord(value.error)) return "";
  const code = value.error.code;
  return typeof code === "string" && /^[a-z][a-z0-9_.-]{0,79}$/.test(code) ? code : "";
}

export function machineFailureText(text: string): string {
  // Do not echo malformed payloads: unlike a validated status they may contain
  // private config, arbitrary stderr, or output from the wrong command.
  return `[error] errno=-1\n${machineErrorCode(text) || "machine.invalid_response"}`;
}

export function parseMachineDns(text: string): DnsState | null {
  const data = decodeMachineData(text, "dns.status");
  if (!data || typeof data.profile !== "string" ||
    !["default", "cloudflare-doh", "cloudflare-dot", "cloudflare-udp"].includes(data.profile) ||
    typeof data.primary !== "string" || !data.primary ||
    (data.secondary !== null && typeof data.secondary !== "string") ||
    typeof data.transport !== "string" || !["default", "doh", "dot", "udp"].includes(data.transport)
  ) return null;
  return {
    profile: data.profile as DnsState["profile"],
    primary: data.primary,
    secondary: data.secondary ?? "",
    transport: data.transport,
  };
}

export function parseMachineNetwork(text: string): NetworkPolicyStatus | null {
  const data = decodeMachineData(text, "network.status");
  if (!data || !isRecord(data.configured) || !isRecord(data.effective)) return null;
  const { configured, effective } = data;
  if (
    typeof configured.ipv6_mode !== "string" ||
    !["ipv4_only", "prefer_ipv4", "prefer_ipv6"].includes(configured.ipv6_mode) ||
    typeof configured.mtu !== "number" || !Number.isInteger(configured.mtu) ||
    configured.mtu < 1280 || configured.mtu > 1500 ||
    typeof configured.udp_timeout !== "string" ||
    !["1m", "3m", "5m", "10m", "15m", "30m"].includes(configured.udp_timeout) ||
    typeof effective.ipv6_mode !== "string" || !effective.ipv6_mode ||
    typeof effective.stack !== "string" || !effective.stack ||
    (effective.mtu !== null && (typeof effective.mtu !== "number" ||
      !Number.isSafeInteger(effective.mtu) || effective.mtu <= 0)) ||
    typeof effective.udp_timeout !== "string" || !effective.udp_timeout
  ) return null;
  return {
    configured: { ipv6_mode: configured.ipv6_mode, mtu: configured.mtu, udp_timeout: configured.udp_timeout },
    effective: { ipv6_mode: effective.ipv6_mode, stack: effective.stack, mtu: effective.mtu, udp_timeout: effective.udp_timeout },
  };
}


/** One service snapshot owns both process and dataplane observations. */
export function parseMachineRuntime(text: string): RuntimeState | null {
  const data = decodeMachineData(text, "service.status");
  if (!data || !isRecord(data.core) || !isRecord(data.core.sing_box) ||
    !isRecord(data.transparent) || !isRecord(data.supervisors) ||
    !isRecord(data.api) || !isRecord(data.readiness)) return null;
  const core = data.core.sing_box;
  const transparent = data.transparent;
  const enumValue = (value: unknown, values: string[]) =>
    typeof value === "string" && values.includes(value);
  const nullableBool = (value: unknown) => value === null || typeof value === "boolean";
  const pidSummary = (value: unknown) => typeof value === "string" &&
    (value === "stopped" || value === "unknown" || value.split(",").every((pid) =>
      /^[0-9]+$/.test(pid) && Number(pid) > 0 && Number(pid) <= 0xffffffff));
  if (!enumValue(core.process_state, ["running", "stopped", "unknown"]) ||
    !pidSummary(core.pid_summary) || !pidSummary(data.supervisors.fswatch) ||
    !nullableBool(core.running) || !nullableBool(data.readiness.overall) ||
    !nullableBool(transparent.dataplane_ready) ||
    (core.rss_kib !== null && (typeof core.rss_kib !== "number" ||
      !Number.isSafeInteger(core.rss_kib) || core.rss_kib < 0)) ||
    !enumValue(transparent.configured_mode, ["tun", "ebpf", "invalid", "unknown"]) ||
    !enumValue(transparent.effective_type, ["tun", "ebpf", "invalid", "unknown"]) ||
    !enumValue(transparent.effective_mode, ["tun", "local", "shared", "hybrid", "unknown"]) ||
    !enumValue(transparent.capability, ["ok", "failed", "not_required", "unknown"]) ||
    !enumValue(transparent.local_cgroup, ["attached", "missing", "configured", "inactive", "unknown"]) ||
    !enumValue(transparent.shared_tc, ["attached", "missing", "configured", "pending", "inactive", "unknown"]) ||
    typeof transparent.shared_interface_count !== "number" ||
    !Number.isSafeInteger(transparent.shared_interface_count) || transparent.shared_interface_count < 0 ||
    typeof transparent.transition !== "string" || !/^[a-z-]{1,128}$/.test(transparent.transition) ||
    typeof transparent.has_recent_error !== "boolean" ||
    typeof data.api.url !== "string" || typeof data.api.webui !== "string") return null;
  const running = core.process_state === "running";
  const expectedRunning = running ? true : core.process_state === "stopped" ? false : null;
  if (core.running !== expectedRunning ||
    (running && !/^[0-9]/.test(core.pid_summary as string)) ||
    (!running && core.pid_summary !== core.process_state) ||
    (!running && data.readiness.overall === true)) return null;
  const transition = transparent.transition;
  const phase = ["idle", "stable"].includes(transition) ? "stable"
    : ["rolling-back", "old-restored", "rollback"].includes(transition) ? "rollback"
      : ["target-written", "preflight", "candidate-prepared", "stopping-old", "old-stopped",
        "candidate-starting", "verified", "pending"].includes(transition) ? "pending" : "unknown";
  return {
    ...runtimeDefaults,
    singBoxState: running ? "sing-box" : core.process_state as "stopped" | "unknown",
    singBox: core.pid_summary as string,
    singBoxRssKib: running ? core.rss_kib as number | null : null,
    serviceReady: data.readiness.overall as boolean | null,
    fswatch: data.supervisors.fswatch as string,
    transparentMode: enumValue(transparent.configured_mode, ["tun", "ebpf"])
      ? transparent.configured_mode as "tun" | "ebpf" : "unknown",
    transparentEffectiveMode: transparent.effective_type === "tun" ? "tun"
      : transparent.effective_type === "ebpf" ? transparent.effective_mode as RuntimeState["transparentEffectiveMode"] : "unknown",
    transparentCapability: transparent.capability === "not_required" ? "not-required"
      : transparent.capability as RuntimeState["transparentCapability"],
    transparentLocalCgroup: transparent.local_cgroup as RuntimeState["transparentLocalCgroup"],
    transparentSharedTc: transparent.shared_tc as RuntimeState["transparentSharedTc"],
    // The machine protocol exposes a count, not interface names. Do not invent
    // names or interpret redaction as zero attached interfaces.
    transparentSharedInterfaces: [],
    transparentSharedInterfaceCount: transparent.shared_interface_count,
    transparentRecentError: transparent.has_recent_error ? "recorded" : "",
    transparentTransition: phase,
    api: data.api.url,
    webui: data.api.webui,
  };
}
