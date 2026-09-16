import { runtimeDefaults, subscriptionDefaults, wifiPolicyDefaults } from "./parsers.ts";
import type { DnsState, RuntimeState, SubscriptionState, WifiPolicyState } from "../types.ts";

import { parseSubscriptionSourceUsage } from "./subscriptionUsage.ts";

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

function safeCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
function token(value: unknown): value is string {
  return typeof value === "string" && /^[a-zA-Z0-9_.-]{1,128}$/.test(value);
}
function strings(value: unknown, maxItems: number, maxBytes: number): value is string[] {
  return Array.isArray(value) && value.length <= maxItems && value.every((item) =>
    typeof item === "string" && new TextEncoder().encode(item).length <= maxBytes && !/[\u0000-\u001f\u007f]/.test(item));
}
function validOwner(owner: unknown, running: unknown): boolean {
  return owner === "active" ? running === true
    : owner === "none" || owner === "stale" ? running === false
      : owner === "unknown" || owner === "pending" ? running === null : false;
}

/** Explicit private inspector; never use this payload in an issue report or log. */
export function parseMachineSubscription(text: string): SubscriptionState | null {
  const data = decodeMachineData(text, "sub.inspect");
  if (!data || !isRecord(data.source) || !isRecord(data.update) || !isRecord(data.last) ||
    !isRecord(data.cache) || !isRecord(data.schedule) || !isRecord(data.configuration) || !isRecord(data.refresh)) return null;
  const { source, update, last, cache, schedule, configuration, refresh } = data;
  if (!["remote_url", "local_file"].includes(source.mode as string) || !safeCount(source.configured_count) ||
    !validOwner(update.owner, update.running) || typeof update.transaction_pending !== "boolean" ||
    !["phase", "result", "generation_id"].every((key) => token(last[key])) || typeof last.has_reason !== "boolean" ||
    !["attempt_epoch", "success_epoch", "configured_count", "source_count", "imported_count", "skipped_count"].every((key) => safeCount(last[key])) ||
    !safeCount(cache.source_entries) || !safeCount(cache.provenance_entries) || !token(cache.identity) ||
    !["off", "12", "24", "48", "72"].includes(schedule.interval_hours as string) ||
    schedule.enabled !== (schedule.interval_hours !== "off") || !validOwner(schedule.owner, schedule.running) ||
    !strings(configuration.sing_box_urls, 5, 65536) || !strings(configuration.filters, 32, 64) ||
    typeof configuration.user_agent !== "string" || new TextEncoder().encode(configuration.user_agent).length > 256 ||
    /[\u0000-\u001f\u007f]/.test(configuration.user_agent) || !Array.isArray(data.source_usage) ||
    !safeCount(refresh.event_count) || !safeCount(refresh.error_count)) return null;
  const ownerValid = schedule.owner === "unknown" ? null : schedule.enabled
    ? schedule.owner === "active" : schedule.owner === "none";
  if (schedule.owner_valid !== ownerValid || (source.mode === "remote_url" && source.configured_count !== configuration.sing_box_urls.length) ||
    (source.mode === "local_file" && source.configured_count !== 1)) return null;
  return {
    ...subscriptionDefaults,
    singBox: configuration.sing_box_urls[0] || "", singBoxUrls: configuration.sing_box_urls.slice(),
    userAgent: configuration.user_agent, filters: configuration.filters.slice(),
    sourceMode: source.mode === "local_file" ? "local" : "url", configuredCount: source.configured_count,
    sourceUsage: source.mode === "local_file" ? [] : parseSubscriptionSourceUsage(JSON.stringify(data.source_usage)),
    updateRunning: update.running === true, updateLockOwner: update.owner as string,
    lastPhase: last.phase as string, lastResult: last.result as string,
    lastAttemptEpoch: last.attempt_epoch as number, lastSuccessEpoch: last.success_epoch as number,
    lastConfiguredCount: last.configured_count as number, lastSourceCount: last.source_count as number,
    lastImportedCount: last.imported_count as number, lastSkippedCount: last.skipped_count as number,
    lastGenerationId: last.generation_id as string,
    // Do not restore the old raw error channel; the page provides a diagnostic link.
    lastReason: "none", cacheCount: cache.source_entries,
    cacheProvenanceCount: cache.provenance_entries, cacheSource: cache.identity as string,
    scheduleIntervalHours: schedule.interval_hours as SubscriptionState["scheduleIntervalHours"],
    scheduleEnabled: schedule.enabled as boolean, scheduleRunning: schedule.running === true,
    scheduleOwner: schedule.owner as string, scheduleOwnerValid: ownerValid === true,
    refreshEventCount: refresh.event_count, refreshErrorCount: refresh.error_count,
  };
}

export function parseMachineWifi(text: string): WifiPolicyState | null {
  const data = decodeMachineData(text, "wifi.inspect");
  if (!data || !isRecord(data.policy) || !isRecord(data.network) || !isRecord(data.configuration)) return null;
  const { policy, network, configuration } = data;
  if (typeof policy.enabled !== "boolean" || !["blacklist", "whitelist"].includes(policy.mode as string) ||
    !safeCount(policy.interval_seconds) || policy.interval_seconds < 3 || policy.interval_seconds > 300 ||
    typeof policy.supervisor !== "string" || !/^(?:stopped|unknown|[1-9][0-9]*(?:,[1-9][0-9]*)*)$/.test(policy.supervisor) ||
    typeof network.connected !== "boolean" || typeof network.matched !== "boolean" ||
    !["rule", "direct"].includes(network.desired_mode as string) ||
    !strings([network.ssid, network.bssid], 2, 1024) || !strings(configuration.ssids, 65536, 65536) ||
    !strings(configuration.bssids, 65536, 17) ||
    !configuration.bssids.every((value) => /^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(value)) ||
    !["rule", "global", "direct", "unavailable"].includes(data.current_mode as string)) return null;
  return {
    ...wifiPolicyDefaults, observed: true, enabled: policy.enabled,
    policyMode: policy.mode as WifiPolicyState["policyMode"], intervalSeconds: policy.interval_seconds,
    supervisor: policy.supervisor, connected: network.connected, matched: network.matched,
    ssid: network.ssid as string, bssid: network.bssid as string,
    desiredMode: network.desired_mode as WifiPolicyState["desiredMode"],
    currentMode: data.current_mode as WifiPolicyState["currentMode"],
    ssids: configuration.ssids.slice(), bssids: configuration.bssids.slice(),
  };
}
