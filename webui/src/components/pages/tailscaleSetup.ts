/** Tailscale onboarding uses the existing private config-editor transaction. */
export const TAILSCALE_KEYS_URL = "https://login.tailscale.com/admin/settings/keys";
export const TAILSCALE_MACHINES_URL = "https://login.tailscale.com/admin/machines";
const CONTROL_URL = "https://controlplane.tailscale.com";
const STATE_DIRECTORY = "/data/adb/modules/MagicNet/.state/sing-box/tailscale";
type JsonObject = Record<string, unknown>;

export type TailscaleDraft = { hostname: string; authKey: string; mode?: "key" | "browser" };
export type TailscaleSnapshot = {
  configured: boolean;
  hostname: string;
  tag: string;
  controlUrl: string;
  endpointRevision: string;
  statusConfigured: boolean;
};
export type SetupErrorCode = "config" | "multiple" | "hostname" | "auth-key" | "conflict" | "custom-control" | "references";
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
    statusConfigured: object(config.experimental) && object(config.experimental.clash_api)
      && Boolean(config.experimental.clash_api.secret || config.experimental.clash_api.tailscale_secret),
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
  if ((!endpoint && !authKey && draft.mode !== "browser") || (authKey && !/^tskey-auth-[a-zA-Z0-9-]{1,240}$/.test(authKey))) {
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
  { // Both login methods need the private status API, not just browser login.
    if (config.experimental !== undefined && !object(config.experimental)) throw new TailscaleSetupError("config");
    const experimental = (config.experimental ?? {}) as JsonObject;
    if (experimental.clash_api !== undefined && !object(experimental.clash_api)) throw new TailscaleSetupError("config");
    const api = (experimental.clash_api ?? {}) as JsonObject;
    if (!api.tailscale_secret) api.tailscale_secret = api.secret || Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2, "0")).join("");
    if (!api.external_controller) api.external_controller = "127.0.0.1:9090";
    experimental.clash_api = api;
    config.experimental = experimental;
  }
  return `${JSON.stringify(config, null, 2)}\n`;
}

// Only remove the exact rules generated by runtime_config.sh. A custom
// reference must be handled in the config editor, never silently discarded.
function removeManagedTailscaleRoutes(config: JsonObject, tag: string): void {
  const exact = (rule: unknown, expected: JsonObject): boolean => object(rule)
    && Object.keys(rule).length === Object.keys(expected).length
    && Object.keys(expected).every(key => JSON.stringify(rule[key]) === JSON.stringify(expected[key]));
  const dns = object(config.dns) ? config.dns : undefined;
  const dnsTags = new Set<string>();
  if (Array.isArray(dns?.servers)) {
    dns.servers = dns.servers.filter((server: unknown) => {
      if (!object(server) || server.type !== "tailscale" || server.endpoint !== tag) return true;
      if (typeof server.tag !== "string" || !exact(server, { type: "tailscale", tag: server.tag, endpoint: tag })) {
        throw new TailscaleSetupError("references");
      }
      dnsTags.add(server.tag);
      return false;
    });
  }
  if (Array.isArray(dns?.rules)) {
    dns.rules = dns.rules.filter((rule: unknown) => ![...dnsTags].some(server =>
      exact(rule, { domain_suffix: ["ts.net"], server })));
  }
  const route = object(config.route) ? config.route : undefined;
  if (Array.isArray(route?.rules)) {
    route.rules = route.rules.filter((rule: unknown) =>
      !exact(rule, { domain_suffix: ["ts.net"], outbound: tag })
      && !exact(rule, { domain_suffix: ["ts.net"], action: "route", outbound: tag })
      && !exact(rule, { ip_cidr: ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], preferred_by: [tag], action: "route", outbound: tag })
      && !exact(rule, { ip_cidr: ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], preferred_by: [tag], outbound: tag })
      && !exact(rule, { ip_cidr: ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], preferred_by: ["tailscale"], outbound: tag }));
  }
  const references = (value: unknown): boolean => {
    if (Array.isArray(value)) return value.some(references);
    if (!object(value)) return false;
    return Object.entries(value).some(([key, item]) => {
      if (["outbound", "detour", "endpoint", "final"].includes(key) && item === tag) return true;
      if (["server", "final"].includes(key) && typeof item === "string" && dnsTags.has(item)) return true;
      if (["outbound", "outbounds"].includes(key) && Array.isArray(item) && item.includes(tag)) return true;
      return references(item);
    });
  };
  if (references(config)) throw new TailscaleSetupError("references");
}

export function removeTailscaleEndpoint(text: string, baseline: TailscaleSnapshot): string {
  const config = parseConfig(text);
  const endpoint = endpointOf(config);
  if (!endpoint || revision(endpoint) !== baseline.endpointRevision) throw new TailscaleSetupError("conflict");
  const endpoints = (config.endpoints ?? []) as JsonObject[];
  config.endpoints = endpoints.filter((item) => item !== endpoint);
  removeManagedTailscaleRoutes(config, String(endpoint.tag));
  return `${JSON.stringify(config, null, 2)}\n`;
}

export function parseTailscaleLogin(text: string): { state: string; authUrl: string; online: boolean } {
  const value: unknown = JSON.parse(text);
  if (!object(value) || typeof value.state !== "string") throw new TailscaleSetupError("config");
  let authUrl = "";
  if (typeof value.auth_url === "string" && value.auth_url) {
    const url = new URL(value.auth_url);
    if (url.protocol !== "https:" || url.hostname !== "login.tailscale.com" || url.port || url.username || url.password || !/^\/a\/[a-zA-Z0-9]+$/.test(url.pathname) || url.search || url.hash) throw new TailscaleSetupError("config");
    authUrl = url.href;
  }
  return { state: value.state, authUrl, online: value.online === true };
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

async function updateTailscale(
  client: TailscaleClient,
  transform: (text: string) => string,
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
    const candidate = transform(current.stdout);
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

export function saveTailscale(client: TailscaleClient, draft: TailscaleDraft, baseline: TailscaleSnapshot): Promise<SaveResult> {
  return updateTailscale(client, (text) => buildTailscaleConfig(text, draft, baseline));
}

export function removeTailscale(client: TailscaleClient, baseline: TailscaleSnapshot): Promise<SaveResult> {
  return updateTailscale(client, (text) => removeTailscaleEndpoint(text, baseline));
}
