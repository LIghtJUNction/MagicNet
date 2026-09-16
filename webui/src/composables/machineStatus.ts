import type { DnsState } from "../types.ts";

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
