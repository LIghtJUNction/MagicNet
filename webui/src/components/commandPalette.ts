/**
 * Quick-jump ranking. Pure so it can be tested without a DOM: entries are
 * matched against both the source (Chinese) label and the active-locale
 * translation, plus optional hints and untranslated keywords.
 */
export type PaletteEntry = {
  id: string;
  label: string;
  group: string;
  hint?: string;
  keywords?: readonly string[];
};

type Translate = (source: string) => string;

const normalize = (value: string): string => value.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();

/** Ordered subsequence match, e.g. "sbx" → "sing-box". */
function subsequence(haystack: string, needle: string): boolean {
  let position = 0;
  for (const character of needle) {
    position = haystack.indexOf(character, position);
    if (position < 0) return false;
    position += character.length;
  }
  return true;
}

function fieldScore(field: string, needle: string): number {
  if (!field) return 0;
  if (field === needle) return 100;
  if (field.startsWith(needle)) return 80;
  if (field.split(/[\s/·・,，-]+/).some((word) => word.startsWith(needle))) return 65;
  if (field.includes(needle)) return 50;
  if (needle.length > 1 && subsequence(field, needle)) return 20;
  return 0;
}

export function scorePaletteEntry(entry: PaletteEntry, query: string, translate: Translate = (source) => source): number {
  const needle = normalize(query);
  if (!needle) return 1;
  const label = Math.max(fieldScore(normalize(entry.label), needle), fieldScore(normalize(translate(entry.label)), needle));
  const hint = entry.hint
    ? Math.max(fieldScore(normalize(entry.hint), needle), fieldScore(normalize(translate(entry.hint)), needle)) * 0.6
    : 0;
  const keywords = Math.max(0, ...(entry.keywords ?? []).map((keyword) => fieldScore(normalize(keyword), needle) * 0.85));
  const group = Math.max(fieldScore(normalize(entry.group), needle), fieldScore(normalize(translate(entry.group)), needle)) * 0.4;
  return Math.max(label, hint, keywords, group);
}

/** Stable ranking: equal scores keep the caller's (navigation) order. */
export function rankPaletteEntries<T extends PaletteEntry>(entries: readonly T[], query: string, translate?: Translate): T[] {
  return entries
    .map((entry, index) => ({ entry, index, score: scorePaletteEntry(entry, query, translate) }))
    .filter((item) => item.score > 0)
    .sort((left, right) => right.score - left.score || left.index - right.index)
    .map((item) => item.entry);
}

/** Global shortcut: Ctrl/⌘+K anywhere, or "/" when not typing in a field. */
export function isPaletteShortcut(event: Pick<KeyboardEvent, "key" | "ctrlKey" | "metaKey" | "altKey" | "target">): boolean {
  if (event.altKey) return false;
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") return true;
  if (event.key !== "/" || event.ctrlKey || event.metaKey) return false;
  const target = event.target as { tagName?: string; isContentEditable?: boolean } | null;
  const tag = target?.tagName?.toLowerCase();
  return !(tag === "input" || tag === "textarea" || tag === "select" || target?.isContentEditable);
}
