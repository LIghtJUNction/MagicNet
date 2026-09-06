import { ref } from "vue";

export function useActionLock() {
  const running = ref(new Set<string>());

  function isRunning(key: string): boolean {
    return running.value.has(key);
  }

  async function withAction<T>(
    key: string,
    task: () => Promise<T>,
  ): Promise<T | undefined> {
    if (isRunning(key)) return undefined;
    running.value.add(key);
    try {
      return await task();
    } finally {
      running.value.delete(key);
    }
  }

  return { isRunning, withAction };
}
