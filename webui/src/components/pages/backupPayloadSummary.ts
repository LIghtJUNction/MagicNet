import { fnv32Hex } from "@/lib/fnv32";

export type BackupPayloadSummary = {
  chars: number;
  compactChars: number;
  lines: number;
  hasWhitespace: boolean;
  fingerprint: string;
  invalidChars: boolean;
  tooLarge: boolean;
  looksValid: boolean;
};

export function summarizeBackupPayload(payload: string): BackupPayloadSummary {
  const compact = payload.replace(/\s+/g, "");
  const invalidChars = Boolean(compact) && !/^[A-Za-z0-9+/=_-]+$/.test(compact);
  const tooLarge = compact.length > 5 * 1024 * 1024;
  return {
    chars: payload.length,
    compactChars: compact.length,
    lines: payload ? payload.split(/\r?\n/).length : 0,
    hasWhitespace: /\s/.test(payload),
    fingerprint: compact ? fnv32Hex(compact) : "-",
    invalidChars,
    tooLarge,
    looksValid: compact.length >= 32 && !invalidChars && !tooLarge
  };
}
