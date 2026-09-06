import { readonly, ref } from "vue";
import { messages } from "./messages.ts";

export type Locale = "zh-CN" | "en" | "ru";
export const LOCALE_STORAGE_KEY = "magicnet.webui.locale";
export const languages: readonly { value: Locale; label: string }[] = [
  { value: "zh-CN", label: "简体中文" },
  { value: "en", label: "English" },
  { value: "ru", label: "Русский" },
];

export function resolveLocale(preferred: readonly string[]): Locale {
  for (const language of preferred) {
    const base = language.toLowerCase().split(/[-_]/)[0];
    if (base === "zh") return "zh-CN";
    if (base === "en" || base === "ru") return base;
  }
  return "zh-CN";
}

function initialLocale(): Locale {
  if (typeof window === "undefined") return "zh-CN";
  try {
    const stored = window.localStorage.getItem(LOCALE_STORAGE_KEY);
    if (languages.some(({ value }) => value === stored)) return stored as Locale;
  } catch { /* WebViews may disable storage; language selection still works. */ }
  return resolveLocale(window.navigator.languages?.length
    ? window.navigator.languages
    : [window.navigator.language]);
}

const activeLocale = ref<Locale>(initialLocale());
export const locale = readonly(activeLocale);

export function setLocale(value: string): void {
  if (!languages.some((language) => language.value === value)) return;
  activeLocale.value = value as Locale;
  try { window.localStorage.setItem(LOCALE_STORAGE_KEY, value); } catch { /* optional */ }
  bootstrapLocale();
}

export function bootstrapLocale(): void {
  if (typeof document !== "undefined") document.documentElement.lang = activeLocale.value;
}

/** Translate UI text only. Commands, configuration values and device logs stay verbatim. */
export function t(source: string, params: Record<string, string | number | null | undefined> = {}): string {
  const current = activeLocale.value;
  const translations = Object.hasOwn(messages, source) ? messages[source] : undefined;
  const translated = current === "zh-CN" ? source : translations?.[current === "en" ? 0 : 1] ?? source;
  return translated.replace(/\{(\w+)\}/g, (placeholder, key: string) =>
    Object.hasOwn(params, key) ? String(params[key] ?? "") : placeholder,
  );
}
