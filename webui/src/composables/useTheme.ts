import { t } from "@/i18n";
import { computed, onMounted, onUnmounted, ref, watch } from "vue";

export type ThemePreference = "light" | "dark" | "system";
export type ResolvedTheme = "light" | "dark";

const STORAGE_KEY = "magicnet.webui.theme";

const preference = ref<ThemePreference>("system");
const systemDark = ref(false);
let media: MediaQueryList | null = null;
let bound = false;

function readStored(): ThemePreference {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw === "light" || raw === "dark" || raw === "system") return raw;
  } catch {
    /* ignore */
  }
  return "system";
}

function writeStored(value: ThemePreference): void {
  try {
    localStorage.setItem(STORAGE_KEY, value);
  } catch {
    /* ignore */
  }
}

function applyResolved(theme: ResolvedTheme): void {
  const root = document.documentElement;
  root.dataset.theme = theme;
  root.style.colorScheme = theme;
  const meta = document.querySelector('meta[name="color-scheme"]');
  if (meta) meta.setAttribute("content", theme === "dark" ? "dark light" : "light dark");
}

export function useTheme() {
  const resolved = computed<ResolvedTheme>(() => {
    if (preference.value === "system") return systemDark.value ? "dark" : "light";
    return preference.value;
  });

  const label = computed(() => {
    if (preference.value === "light") return t("亮色");
    if (preference.value === "dark") return t("暗色");
    return t("跟随系统");
  });

  function setPreference(next: ThemePreference): void {
    preference.value = next;
    writeStored(next);
    applyResolved(resolved.value);
  }

  /** Cycle light → dark → system → light */
  function cycleTheme(): void {
    const order: ThemePreference[] = ["light", "dark", "system"];
    const idx = order.indexOf(preference.value);
    setPreference(order[(idx + 1) % order.length]);
  }

  function syncSystem(e?: MediaQueryListEvent): void {
    systemDark.value = e ? e.matches : Boolean(media?.matches);
    if (preference.value === "system") applyResolved(resolved.value);
  }

  onMounted(() => {
    preference.value = readStored();
    if (typeof window !== "undefined" && window.matchMedia) {
      media = window.matchMedia("(prefers-color-scheme: dark)");
      systemDark.value = media.matches;
      if (!bound) {
        media.addEventListener("change", syncSystem);
        bound = true;
      }
    }
    applyResolved(resolved.value);
  });

  onUnmounted(() => {
    if (media && bound) {
      media.removeEventListener("change", syncSystem);
      bound = false;
    }
  });

  watch(resolved, (theme) => applyResolved(theme));

  return {
    preference,
    resolved,
    label,
    setPreference,
    cycleTheme,
  };
}

/** Apply theme before Vue mounts to avoid flash (call from main.ts). */
export function bootstrapTheme(): void {
  let pref: ThemePreference = "system";
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw === "light" || raw === "dark" || raw === "system") pref = raw;
  } catch {
    /* ignore */
  }
  const dark =
    pref === "dark" ||
    (pref === "system" &&
      typeof window !== "undefined" &&
      window.matchMedia?.("(prefers-color-scheme: dark)").matches);
  applyResolved(dark ? "dark" : "light");
}
