/** An explicitly started interval that sleeps while the WebView is hidden. */
export function createVisibilityInterval(callback: () => void, delayMs: number) {
  let enabled = false;
  let timer: number | undefined;
  let generation = 0;

  function clear(): void {
    generation += 1;
    if (timer !== undefined) window.clearInterval(timer);
    timer = undefined;
  }

  function sync(): void {
    clear();
    if (!enabled || document.hidden) return;
    const current = generation;
    timer = window.setInterval(() => {
      // A callback queued just before hide/stop must not start another command.
      if (enabled && !document.hidden && current === generation) callback();
    }, delayMs);
  }

  function stop(): void {
    enabled = false;
    clear();
    document.removeEventListener("visibilitychange", sync);
  }

  function start(): void {
    stop();
    enabled = true;
    document.addEventListener("visibilitychange", sync);
    sync();
  }

  return { start, stop };
}
