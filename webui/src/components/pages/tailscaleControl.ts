/** Public, credential-free lifecycle observation. Mutations use exit status,
 * then re-read this interface rather than interpreting human CLI output. */
export type TailscaleControlState = {
  enabled: boolean;
  resumable: boolean;
  logout_pending: boolean;
  local_identity: boolean | null;
  revision: string;
  core: "running" | "stopped" | "unknown";
};
export type TailscaleAction = "enable" | "disable" | "logout";

export function parseTailscaleControl(text: string): TailscaleControlState {
  const envelope = JSON.parse(text);
  const data = envelope?.data;
  if (envelope?.schema !== 1 || envelope.ok !== true || envelope.command !== "tailscale.status"
    || !data || typeof data.enabled !== "boolean" || typeof data.resumable !== "boolean"
    || typeof data.logout_pending !== "boolean"
    || (data.local_identity !== null && typeof data.local_identity !== "boolean")
    || typeof data.revision !== "string" || !/^[a-f0-9]{64}$/.test(data.revision)
    || !["running", "stopped", "unknown"].includes(data.core)) {
    throw new Error("tailscale.invalid_status");
  }
  // Return only the allowlisted fields even if a future server adds private data.
  return { enabled: data.enabled, resumable: data.resumable, logout_pending: data.logout_pending,
    local_identity: data.local_identity, revision: data.revision, core: data.core };
}

export function transitionConfirmed(action: TailscaleAction, state: TailscaleControlState): boolean {
  if (action === "enable") return state.enabled && !state.logout_pending;
  if (action === "disable") return !state.enabled;
  return !state.enabled && !state.resumable && !state.logout_pending && state.local_identity === false;
}
