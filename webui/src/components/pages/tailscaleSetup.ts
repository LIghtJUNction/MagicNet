/** Tailscale onboarding uses the existing private config-editor transaction. */
export const TAILSCALE_KEYS_URL = "https://login.tailscale.com/admin/settings/keys";
export const TAILSCALE_MACHINES_URL = "https://login.tailscale.com/admin/machines";
const CONTROL_URL = "https://controlplane.tailscale.com";
const STATE_DIRECTORY = "/data/adb/modules/MagicNet/.state/sing-box/tailscale";
type JsonObject = Record<string, unknown>;

export type TailscaleDraft = { hostname: string; authKey: string };
export type TailscaleSnapshot = {
  configured: boolean;
  hostname: string;
  tag: string;
  controlUrl: string;
  endpointRevision: string;
};
export type SetupErrorCode = "config" | "multiple" | "hostname" | "auth-key" | "conflict" | "custom-control";
export class TailscaleSetupError extends Error {
  readonly code: SetupErrorCode;
  constructor(code: SetupErrorCode) {
    // Do not put parser errors, configuration text or credentials in errors.
    super(code);
    this.code = code;
  }
}

function object(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function parseConfig(text: string): JsonObject {
  try {
    const config: unknown = JSON.parse(text);
    if (!object(config) || (config.endpoints !== undefined && !Array.isArray(config.endpoints))) {
      throw new TailscaleSetupError("config");
    }
    if ((config.endpoints as unknown[] | undefined)?.some((item) => !object(item))) {
      throw new TailscaleSetupError("config");
    }
    return config;
  } catch {
    throw new TailscaleSetupError("config");
  }
}
function endpointOf(config: JsonObject): JsonObject | undefined {
  const endpoints = (config.endpoints ?? []) as JsonObject[];
  const matches = endpoints.filter((item) => item.type === "tailscale");
  // Runtime routing currently chooses the first tailnet. Never silently edit
  // an arbitrary network when a power user has configured several endpoints.
  if (matches.length > 1) throw new TailscaleSetupError("multiple");
  if (matches[0] && (typeof matches[0].tag !== "string" || !matches[0].tag)) {
    throw new TailscaleSetupError("config");
  }
  return matches[0];
}
function withoutAuth(endpoint: JsonObject): JsonObject {
  const copy = { ...endpoint };
  delete copy.auth_key;
  return copy;
}
function revision(endpoint?: JsonObject): string {
  if (!endpoint) return "";
  const copy = withoutAuth(endpoint);
  return JSON.stringify(Object.fromEntries(Object.keys(copy).sort().map((key) => [key, copy[key]])));
}
function availableTag(config: JsonObject): string {
  const used = new Set(["inbounds", "outbounds", "endpoints"].flatMap((key) =>
    Array.isArray(config[key]) ? config[key].filter(object).map((item) => item.tag) : [],
  ));
  let tag = "magicnet-tailscale";
  for (let suffix = 2; used.has(tag); suffix += 1) tag = `magicnet-tailscale-${suffix}`;
  return tag;
}

export function inspectTailscale(text: string): TailscaleSnapshot {
  const config = parseConfig(text);
  const endpoint = endpointOf(config);
  return {
    configured: Boolean(endpoint),
    hostname: typeof endpoint?.hostname === "string" ? endpoint.hostname : "magicnet-phone",
    tag: endpoint ? String(endpoint.tag) : availableTag(config),
    controlUrl: typeof endpoint?.control_url === "string" && endpoint.control_url ? endpoint.control_url : CONTROL_URL,
    endpointRevision: revision(endpoint),
  };
}

export function buildTailscaleConfig(text: string, draft: TailscaleDraft, baseline: TailscaleSnapshot): string {
  const config = parseConfig(text);
  const endpoint = endpointOf(config);
  if (revision(endpoint) !== baseline.endpointRevision) throw new TailscaleSetupError("conflict");
  const hostname = draft.hostname.trim();
  if (!/^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/.test(hostname)) {
    throw new TailscaleSetupError("hostname");
  }
  const authKey = draft.authKey.trim();
  if ((!endpoint && !authKey) || (authKey && !/^tskey-auth-[a-zA-Z0-9-]{1,240}$/.test(authKey))) {
    throw new TailscaleSetupError("auth-key");
  }
  // This form issues official Tailscale keys; never send them to a preexisting
  // custom control server. Existing custom endpoints can still be inspected.
  const controlUrl = typeof endpoint?.control_url === "string" && endpoint.control_url ? endpoint.control_url : CONTROL_URL;
  if (controlUrl.replace(/\/$/, "") !== CONTROL_URL) throw new TailscaleSetupError("custom-control");
  const next: JsonObject = {
    ...(endpoint ?? { ephemeral: false, accept_routes: false }),
    type: "tailscale",
    tag: endpoint?.tag ?? availableTag(config),
    hostname,
    system_interface: false,
    state_directory: endpoint?.state_directory || STATE_DIRECTORY,
  };
  if (authKey) next.auth_key = authKey;
  const endpoints = (config.endpoints ?? []) as JsonObject[];
  config.endpoints = endpoint ? endpoints.map((item) => item === endpoint ? next : item) : [...endpoints, next];
  return `${JSON.stringify(config, null, 2)}\n`;
}

export type PrivateResult = { ok: boolean; stdout: string };
export type TailscaleClient = {
  run: (args: string) => Promise<PrivateResult>;
  stage: (text: string) => Promise<{ path: string; basename: string } | null>;
  remove: (basename: string) => Promise<boolean>;
  quote: (value: string) => string;
  canSave: () => boolean;
};
export type SaveStage = "read" | "stage" | "conflict" | "validate" | "cleanup" | "restart" | "done";
export type SaveResult = { stage: SaveStage; saved: boolean; snapshot?: TailscaleSnapshot; error?: SetupErrorCode };

export async function saveTailscale(
  client: TailscaleClient,
  draft: TailscaleDraft,
  baseline: TailscaleSnapshot,
): Promise<SaveResult> {
  let payload: { path: string; basename: string } | null = null;
  let stage: SaveStage = "read";
  let saved = false;
  let snapshot: TailscaleSnapshot | undefined;
  let error: SetupErrorCode | undefined;
  try {
    if (!client.canSave()) return { stage: "conflict", saved };
    const current = await client.run("config-editor get sing-box");
    if (!current.ok) return { stage, saved };
    const candidate = buildTailscaleConfig(current.stdout, draft, baseline);
    snapshot = inspectTailscale(candidate);
    stage = "stage";
    payload = await client.stage(candidate);
    if (!payload) return { stage, saved: false };
    stage = "conflict";
    // Read again after potentially chunked transport. Do not apply an old
    // whole-config snapshot after a subscription or another editor changed it.
    const latest = await client.run("config-editor get sing-box");
    if (latest.ok && latest.stdout === current.stdout && client.canSave()) {
      stage = "validate";
      const result = await client.run(`config-editor save-file sing-box ${client.quote(payload.path)}`);
      saved = result.ok && /\[info\]\s+Saved and validated\b/i.test(result.stdout);
    }
  } catch (cause) {
    if (cause instanceof TailscaleSetupError) error = cause.code;
  } finally {
    if (payload) {
      let cleaned = false;
      try { cleaned = await client.remove(payload.basename); } catch { /* Report below without private output. */ }
      if (!cleaned) stage = "cleanup";
    }
  }
  if (!saved || stage === "cleanup") return { stage, saved, error, ...(saved ? { snapshot } : {}) };
  try {
    const result = await client.run("service restart sing-box");
    return { stage: result.ok ? "done" : "restart", saved, snapshot };
  } catch {
    return { stage: "restart", saved, snapshot };
  }
}
