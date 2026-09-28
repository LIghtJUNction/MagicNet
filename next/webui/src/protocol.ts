export interface Settings {
  schema: 1; revision: number; enabled: boolean; mode: 'tun' | 'ebpf';
  user_agent: string; sources: { id: string; url: string; enabled: boolean }[];
  template: Record<string, unknown>;
}
export interface Status {
  phase: 'running' | 'stopped' | 'ownership_changed' | 'unknown';
  configured: boolean; configured_revision: number; effective_revision: number;
  mode: string; source_count: number; pending_changes: boolean; recovery_pending: boolean;
  operation: { id: string; method: string; phase: string } | null;
  observation: string; network_health: string;
}
export interface Capabilities { schema: 1; read: string[]; write: string[]; lifecycle: string; android_acceptance: string; unported: string[] }
export interface Request { schema: 1; id: string; method: string; expected_revision?: number; params: unknown }
export const READ_METHODS = ['capabilities', 'status', 'settings', 'operation', 'diagnostics'] as const;
export const isReadMethod = (method: string) => (READ_METHODS as readonly string[]).includes(method);
export class RpcError extends Error {
  code: string; effectsPossible: boolean; outcomeUnknown: boolean;
  constructor(code: string, effectsPossible = false, outcomeUnknown = false) {
    super(code); this.code = code; this.effectsPossible = effectsPossible; this.outcomeUnknown = outcomeUnknown;
  }
}
export function request(method: string, params: unknown = null, revision?: number): Request {
  if (!/^[a-z][a-z.]{0,63}$/.test(method)) throw new RpcError('invalid_request');
  if (revision !== undefined && (!Number.isSafeInteger(revision) || revision < 0)) throw new RpcError('invalid_revision');
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return { schema: 1, id: Array.from(bytes, b => b.toString(16).padStart(2, '0')).join(''), method, params, ...(revision === undefined ? {} : { expected_revision: revision }) };
}
export function encode(value: Request): string {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  if (bytes.length > 4 * 1024 * 1024) throw new RpcError('too_large');
  let result = '';
  for (let offset = 0; offset < bytes.length; offset += 8192) result += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  return btoa(result);
}
export function object(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value !== null && !Array.isArray(value); }
export function decode(stdout: string, errno: number, input: Request): unknown {
  const invalid = () => new RpcError('invalid_response', !isReadMethod(input.method), !isReadMethod(input.method));
  if (stdout.length > 8 * 1024 * 1024) throw invalid();
  let reply: unknown;
  try { reply = JSON.parse(stdout); } catch { throw invalid(); }
  if (!object(reply) || reply.schema !== 1 || reply.command !== input.method || reply.request_id !== input.id || typeof reply.ok !== 'boolean') throw invalid();
  if (!reply.ok) {
    if (!object(reply.error) || typeof reply.error.code !== 'string' || !/^[a-z_]{1,64}$/.test(reply.error.code)) throw invalid();
    // A correlated server failure is known, even when partial effects need
    // recovery. This differs from losing the response altogether.
    throw new RpcError(reply.error.code, reply.error.effects_possible === true);
  }
  if (errno !== 0 || !Object.hasOwn(reply, 'data')) throw invalid();
  return reply.data;
}
const natural = (value: unknown, maximum = Number.MAX_SAFE_INTEGER): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= maximum;
const token = (value: unknown): value is string => typeof value === 'string' && /^[a-z][a-z_]{0,63}$/.test(value);
const method = (value: unknown): value is string => typeof value === 'string' && /^[a-z][a-z.]{0,63}$/.test(value);
const identity = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
export function settings(value: unknown): Settings {
  if (!object(value) || value.schema !== 1 || !natural(value.revision) || typeof value.enabled !== 'boolean' || typeof value.mode !== 'string' || !['tun','ebpf'].includes(value.mode) || typeof value.user_agent !== 'string' || !value.user_agent.length || value.user_agent.length > 256 || /[\x00-\x1f\x7f]/.test(value.user_agent) || !Array.isArray(value.sources) || value.sources.length > 32 || !object(value.template)) throw new RpcError('invalid_response');
  if (value.sources.some(s => !object(s) || !identity(s.id) || typeof s.url !== 'string' || s.url.length > 4096 || !/^https?:\/\//.test(s.url) || /\s/.test(s.url) || typeof s.enabled !== 'boolean')) throw new RpcError('invalid_response');
  if (new Set(value.sources.map(s => s.id)).size !== value.sources.length || new Set(value.sources.map(s => s.url)).size !== value.sources.length) throw new RpcError('invalid_response');
  return value as unknown as Settings;
}
export function status(value: unknown): Status {
  if (!object(value) || typeof value.phase !== 'string' || !['running','stopped','ownership_changed','unknown'].includes(value.phase) || typeof value.configured !== 'boolean' || !natural(value.configured_revision) || !natural(value.effective_revision) || typeof value.pending_changes !== 'boolean' || typeof value.recovery_pending !== 'boolean' || typeof value.mode !== 'string' || !['tun','ebpf'].includes(value.mode) || !natural(value.source_count,32) || !token(value.network_health) || !token(value.observation)) throw new RpcError('invalid_response');
  if (value.operation !== null && (!object(value.operation) || !identity(value.operation.id) || !method(value.operation.method) || !token(value.operation.phase))) throw new RpcError('invalid_response');
  return value as unknown as Status;
}
export function capabilities(value: unknown): Capabilities {
  if (!object(value) || value.schema !== 1 || !['read','write','unported'].every(k => Array.isArray(value[k]) && value[k].length <= 128 && (value[k] as unknown[]).every(v => k === 'unported' ? token(v) : method(v))) || !token(value.lifecycle) || !token(value.android_acceptance)) throw new RpcError('invalid_response');
  return value as unknown as Capabilities;
}
