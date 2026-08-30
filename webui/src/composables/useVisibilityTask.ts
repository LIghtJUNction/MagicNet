import {
  onActivated,
  onBeforeUnmount,
  onDeactivated,
  onMounted,
  ref,
} from "vue";

type VisibilityTaskOptions = {
  rootMargin?: string;
};

export function useVisibilityTask(
  task: () => void | Promise<void>,
  options: VisibilityTaskOptions = {},
) {
  const target = ref<HTMLElement | null>(null);
  const started = ref(false);
  let observer: IntersectionObserver | null = null;

  function disconnect(): void {
    observer?.disconnect();
    observer = null;
  }

  function activate(): void {
    if (started.value) return;
    started.value = true;
    disconnect();
    void task();
  }

  function observe(): void {
    if (started.value || observer || !target.value) return;
    if (!("IntersectionObserver" in globalThis)) {
      activate();
      return;
    }
    observer = new globalThis.IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) activate();
      },
      { rootMargin: options.rootMargin ?? "320px 0px" },
    );
    observer.observe(target.value);
  }

  onMounted(observe);
  onActivated(observe);
  onDeactivated(disconnect);
  onBeforeUnmount(disconnect);

  return { target, started, activate };
}
