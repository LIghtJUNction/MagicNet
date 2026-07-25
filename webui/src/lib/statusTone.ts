/**
 * Single source of truth for status/surface tone classes.
 * Components and plan helpers MUST use these (or CSS .mn-tone-* aliases),
 * not ad-hoc Tailwind pale-ink colors that break on the ivory canvas.
 */
export type StatusToneKind =
  | "ok"
  | "success"
  | "warn"
  | "warning"
  | "danger"
  | "error"
  | "info"
  | "neutral"
  | "idle"
  | "missing"
  | "switch"
  | "keep";

const TONE_CLASS: Record<string, string> = {
  ok: "mn-tone-ok",
  success: "mn-tone-ok",
  switch: "mn-tone-ok",
  warn: "mn-tone-warn",
  warning: "mn-tone-warn",
  danger: "mn-tone-danger",
  error: "mn-tone-danger",
  missing: "mn-tone-danger",
  info: "mn-tone-info",
  keep: "mn-tone-info",
  neutral: "mn-tone-neutral",
  idle: "mn-tone-neutral",
};

/** Full panel surface: border + bg + text for insight/status cards. */
export function statusToneClasses(kind: StatusToneKind | string): string {
  return TONE_CLASS[kind] || TONE_CLASS.neutral;
}

/** Chip / badge border+text without heavy fill (list chips). */
export function statusChipClasses(kind: StatusToneKind | string): string {
  const map: Record<string, string> = {
    ok: "mn-chip-ok",
    success: "mn-chip-ok",
    warn: "mn-chip-warn",
    warning: "mn-chip-warn",
    danger: "mn-chip-danger",
    error: "mn-chip-danger",
    missing: "mn-chip-danger",
    info: "mn-chip-info",
    neutral: "mn-chip-neutral",
    idle: "mn-chip-neutral",
  };
  return map[kind] || map.neutral;
}
