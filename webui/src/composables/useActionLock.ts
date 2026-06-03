import { ref } from "vue";

export function useActionLock() {
  const running = ref<Record<string, boolean>>({});

  function isRunning(key: string): boolean {
    return Boolean(running.value[key]);
  }

  async function withAction<T>(key: string, task: () => Promise<T>): Promise<T | undefined> {
    if (running.value[key]) return undefined;
    running.value = { ...running.value, [key]: true };
    try {
      return await task();
    } finally {
      const next = { ...running.value };
      delete next[key];
      running.value = next;
    }
  }

  return { isRunning, withAction };
}
