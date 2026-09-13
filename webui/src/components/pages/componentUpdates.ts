export type UpdateSettings = { enabled: boolean; interval_hours: number; wifi_only: boolean; auto_install: boolean };
export type ComponentUpdate = { id: string; sha256: string; source: 'installed' | 'cache' | 'pending' | 'download'; bytes: number };
export type UpdatePlan = { version: string; current: string; pending: boolean; needed: boolean; package: string; download_bytes: number; saved_bytes: number; components: ComponentUpdate[] };
export type UpdateSnapshot = { settings: UpdateSettings; phase: string; error?: string; last_check: number; next_check: number; failures: number; plan?: UpdatePlan };
const phases = new Set(['idle', 'checking', 'available', 'downloading', 'installing', 'pending-reboot', 'up-to-date', 'waiting-wifi', 'error']);
const integer = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const record = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
export function parseUpdateSnapshot(raw: string): UpdateSnapshot {
  if (raw.length > 1024 * 1024) throw new Error('oversized update status');
  const v: unknown = JSON.parse(raw);
  if (!record(v) || !record(v.settings)) throw new Error('invalid update status');
  const s = v.settings;
  if (typeof s.enabled !== 'boolean' || typeof s.wifi_only !== 'boolean' || typeof s.auto_install !== 'boolean'
      || !integer(s.interval_hours) || s.interval_hours < 1 || s.interval_hours > 168
      || typeof v.phase !== 'string' || !phases.has(v.phase)
      || !integer(v.last_check) || !integer(v.next_check) || !integer(v.failures)
      || (v.error !== undefined && typeof v.error !== 'string')) throw new Error('invalid update fields');
  if (v.plan !== undefined && v.plan !== null) {
    const p = v.plan;
    if (!record(p) || typeof p.version !== 'string' || typeof p.current !== 'string'
      || typeof p.pending !== 'boolean' || typeof p.needed !== 'boolean' || typeof p.package !== 'string'
      || !integer(p.download_bytes) || !integer(p.saved_bytes) || !Array.isArray(p.components) || p.components.length > 128) throw new Error('invalid update plan');
    const seen = new Set<string>();
    for (const row of p.components) {
      if (!record(row) || typeof row.id !== 'string' || !/^[A-Za-z0-9_.-]+$/.test(row.id) || seen.has(row.id)
        || typeof row.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(row.sha256)
        || !['installed', 'cache', 'pending', 'download'].includes(String(row.source)) || !integer(row.bytes)) throw new Error('invalid component plan');
      seen.add(row.id);
    }
  }
  return v as unknown as UpdateSnapshot;
}
export function updateSettingsArgs(s: UpdateSettings): string {
  if (!integer(s.interval_hours) || s.interval_hours < 1 || s.interval_hours > 168
    || [s.enabled, s.wifi_only, s.auto_install].some(v => typeof v !== 'boolean')) throw new Error('invalid update settings');
  return `update configure --enabled=${s.enabled} --interval-hours=${s.interval_hours} --wifi-only=${s.wifi_only} --auto-install=${s.auto_install}`;
}
export function updateBytes(bytes: number): string {
  if (!integer(bytes)) return '—';
  return bytes < 1024 ? `${bytes} B` : bytes < 1024 * 1024 ? `${(bytes / 1024).toFixed(1)} KiB` : `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}
