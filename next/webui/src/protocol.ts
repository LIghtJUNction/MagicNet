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
export class RpcError extends Error {
  code: string; effectsPossible: boolean;
  constructor(code: string, effectsPossible = false) { super(code); this.code = code; this.effectsPossible = effectsPossible; }
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
  if (stdout.length > 8 * 1024 * 1024) throw new RpcError('invalid_response');
  let reply: unknown;
  try { reply = JSON.parse(stdout); } catch { throw new RpcError('invalid_response', !['status','settings','capabilities','operation','diagnostics'].includes(input.method)); }
  if (!object(reply) || reply.schema !== 1 || reply.command !== input.method || reply.request_id !== input.id || typeof reply.ok !== 'boolean') throw new RpcError('invalid_response');
  if (!reply.ok) {
    if (!object(reply.error) || typeof reply.error.code !== 'string' || !/^[a-z_]{1,64}$/.test(reply.error.code)) throw new RpcError('invalid_response');
    throw new RpcError(reply.error.code, reply.error.effects_possible === true);
  }
  if (errno !== 0 || !Object.hasOwn(reply, 'data')) throw new RpcError('invalid_response');
  return reply.data;
}
export function settings(value: unknown): Settings {
  if (!object(value) || value.schema !== 1 || !Number.isSafeInteger(value.revision) || Number(value.revision) < 0 || typeof value.enabled !== 'boolean' || !['tun','ebpf'].includes(String(value.mode)) || typeof value.user_agent !== 'string' || !Array.isArray(value.sources) || value.sources.length > 32 || !object(value.template)) throw new RpcError('invalid_response');
  if (value.sources.some(s => !object(s) || typeof s.id !== 'string' || !/^[a-f0-9]{32}$/.test(s.id) || typeof s.url !== 'string' || typeof s.enabled !== 'boolean')) throw new RpcError('invalid_response');
  return value as unknown as Settings;
}
export function status(value: unknown): Status {
  if (!object(value) || !['running','stopped','ownership_changed','unknown'].includes(String(value.phase)) || typeof value.configured !== 'boolean' || !Number.isSafeInteger(value.configured_revision) || !Number.isSafeInteger(value.effective_revision) || typeof value.pending_changes !== 'boolean' || typeof value.recovery_pending !== 'boolean' || typeof value.mode !== 'string' || !Number.isSafeInteger(value.source_count) || typeof value.network_health !== 'string' || typeof value.observation !== 'string') throw new RpcError('invalid_response');
  if (value.operation !== null && (!object(value.operation) || !['id','method','phase'].every(k => typeof (value.operation as Record<string, unknown>)[k] === 'string'))) throw new RpcError('invalid_response');
  return value as unknown as Status;
}
export function capabilities(value: unknown): Capabilities {
  if (!object(value) || value.schema !== 1 || !['read','write','unported'].every(k => Array.isArray(value[k]) && (value[k] as unknown[]).every(v => typeof v === 'string')) || typeof value.lifecycle !== 'string' || typeof value.android_acceptance !== 'string') throw new RpcError('invalid_response');
  return value as unknown as Capabilities;
}
