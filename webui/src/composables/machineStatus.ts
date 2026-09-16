import type { DnsState } from "@/types";

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function parseEnvelope(stdout: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(stdout);
    return isRecord(value) && value.schema === 1 ? value : null;
  } catch {
    return null;
  }
}

/** Parse stdout only: stderr is a separate execution channel, not a framing protocol. */
export function decodeMachineData<T extends Record<string, unknown>>(
  stdout: string,
  expectedCommand: string,
): T | null {
  const value = parseEnvelope(stdout);
  return value?.ok === true && value.command === expectedCommand && isRecord(value.data)
    ? value.data as T
    : null;
}

export function machineErrorCode(stdout: string, expectedCommand: string): string {
  const value = parseEnvelope(stdout);
  if (!value || value.ok !== false || !isRecord(value.error)) return "";
  // Dispatcher errors use machine.error because an unsupported request has no command result.
  if (value.command !== expectedCommand && value.command !== "machine.error") return "";
  return typeof value.error.code === "string" ? value.error.code : "";
}

export function decodeDnsStatus(stdout: string): DnsState | null {
  const data = decodeMachineData(stdout, "dns.status");
  if (!data || typeof data.profile !== "string"
    || !["default", "cloudflare-doh", "cloudflare-dot", "cloudflare-udp"].includes(data.profile)
    || typeof data.primary !== "string"
    || (data.secondary !== null && typeof data.secondary !== "string")
    || typeof data.transport !== "string") return null;
  return {
    profile: data.profile as DnsState["profile"],
    primary: data.primary,
    secondary: data.secondary ?? "",
    transport: data.transport,
  };
}

export type NetworkStatus = {
  configured: { ipv6_mode: string; mtu: number; udp_timeout: string };
  effective: { ipv6_mode: string; stack: string; mtu: number | null; udp_timeout: string };
};

export function decodeNetworkStatus(stdout: string): NetworkStatus | null {
  const data = decodeMachineData(stdout, "network.status");
  if (!data || !isRecord(data.configured) || !isRecord(data.effective)) return null;
  const { configured, effective } = data;
  if (typeof configured.ipv6_mode !== "string"
    || !["ipv4_only", "prefer_ipv4", "prefer_ipv6"].includes(configured.ipv6_mode)
    || typeof configured.mtu !== "number" || !Number.isInteger(configured.mtu)
    || configured.mtu < 1280 || configured.mtu > 1500
    || typeof configured.udp_timeout !== "string"
    || !["1m", "3m", "5m", "10m", "15m", "30m"].includes(configured.udp_timeout)
    || typeof effective.ipv6_mode !== "string" || typeof effective.stack !== "string"
    || (effective.mtu !== null && (typeof effective.mtu !== "number" || !Number.isInteger(effective.mtu)))
    || typeof effective.udp_timeout !== "string") return null;
  return data as NetworkStatus;
}
