import { withTimeout } from "../utils.ts";

export type QueueDepthListener = (depth: number) => void;

/**
 * Serialize device commands by the lifetime of the underlying KernelSU
 * promise, while still surfacing a timeout to the caller promptly. A plain
 * Promise.race would release the queue when the timeout wins even though the
 * root command is still mutating device state.
 */
export class SerialExecQueue {
  private tail: Promise<void> = Promise.resolve();
  private pending = 0;
  private readonly onDepthChange: QueueDepthListener;

  public constructor(onDepthChange: QueueDepthListener = () => {}) {
    this.onDepthChange = onDepthChange;
  }

  public get depth(): number {
    return this.pending;
  }

  public enqueue<T>(task: () => Promise<T>, timeoutMs: number, label: string): Promise<T> {
    this.pending += 1;
    this.onDepthChange(this.pending);

    let resolveVisible!: (value: T | PromiseLike<T>) => void;
    let rejectVisible!: (reason?: unknown) => void;
    const visible = new Promise<T>((resolve, reject) => {
      resolveVisible = resolve;
      rejectVisible = reject;
    });

    const run = this.tail.then(async () => {
      let operation: Promise<T>;
      try {
        operation = Promise.resolve(task());
      } catch (error) {
        rejectVisible(error);
        return;
      }

      // Surface timeout/error as soon as it is known to the caller, but keep
      // `tail` occupied until the real command has settled.
      void withTimeout(operation, timeoutMs, label).then(resolveVisible, rejectVisible);
      try {
        await operation;
      } catch {
        // The visible promise receives the same rejection above.
      }
    });
    this.tail = run
      .catch(() => undefined)
      .finally(() => {
        this.pending = Math.max(0, this.pending - 1);
        this.onDepthChange(this.pending);
      });
    return visible;
  }
}
