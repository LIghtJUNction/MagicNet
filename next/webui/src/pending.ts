import { object, RpcError, type Request } from './protocol.ts';

// Persist correlation only. URLs, imported documents and native settings must
// never end up in browser storage just because a request lost its response.
export interface Pending { id: string; method: string }
export type Outcome = { ok: true; data: unknown } | { ok: false; error: { code: string; effects_possible?: boolean } };
const KEY = 'magicnet.pending.v1';
const idValid = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
const methodValid = (value: unknown): value is string => typeof value === 'string' && /^[a-z][a-z.]{0,63}$/.test(value);
export function track(input: Request): Pending { return { id: input.id, method: input.method }; }
export function restore(storage: Pick<Storage, 'getItem'>): Pending[] {
  try {
    const raw = storage.getItem(KEY);
    if (!raw || raw.length > 2048) return [];
    const values: unknown = JSON.parse(raw);
    if (!Array.isArray(values) || values.length > 8 || values.some(v => !object(v) || !idValid(v.id) || !methodValid(v.method))) return [];
    const entries = values.map(v => ({ id: v.id as string, method: v.method as string }));
    return new Set(entries.map(v => v.id)).size === entries.length ? entries : [];
  } catch { return []; }
}
export function persist(storage: Pick<Storage, 'setItem' | 'removeItem'>, entries: Pending[]) {
  try {
    if (entries.length) storage.setItem(KEY, JSON.stringify(entries.map(({id, method}) => ({id, method}))));
    else storage.removeItem(KEY);
  } catch { /* Storage may be disabled by the WebView; in-memory tracking remains. */ }
}
export function settled(expected: Pending, value: unknown): Outcome | null {
  if (value === null) return null; // Missing/expired receipt is not a negative acknowledgement.
  if (!object(value) || value.id !== expected.id || value.method !== expected.method || typeof value.phase !== 'string') throw new RpcError('invalid_response', true, true);
  if (['running', 'unknown'].includes(value.phase)) return null;
  if (value.phase === 'interrupted' && value.outcome === null) return null;
  const outcome = value.outcome;
  if (!object(outcome)) throw new RpcError('invalid_response', true, true);
  if (value.phase === 'completed' && outcome.ok === true && Object.hasOwn(outcome, 'data')) return {ok:true, data:outcome.data};
  if (['failed','interrupted'].includes(value.phase) && outcome.ok === false && object(outcome.error) && typeof outcome.error.code === 'string' && /^[a-z_]{1,64}$/.test(outcome.error.code)) {
    return {ok:false, error:{code:outcome.error.code, effects_possible:outcome.error.effects_possible === true}};
  }
  throw new RpcError('invalid_response', true, true);
}
