import { t } from "@/i18n";
import { ExecTimeoutError } from "../utils.ts";

export type QueueDepthListener = (depth: number) => void;

type QueuedTask = {
  deadline: number;
  run: () => void;
  expire: () => void;
};

/**
 * Bound queue wait and execution separately. Give a dispatched command its full
 * execution budget. It retains the slot until its underlying promise settles;
 * expired waiting commands are removed so they can never mutate the device later.
 */
export class SerialExecQueue {
  private active = false;
  private readonly waiting = new Set<QueuedTask>();
  private readonly onDepthChange: QueueDepthListener;

  public constructor(onDepthChange: QueueDepthListener = () => {}) {
    this.onDepthChange = onDepthChange;
  }

  public get depth(): number {
    return this.waiting.size + Number(this.active);
  }

  public enqueue<T>(task: () => Promise<T>, timeoutMs: number, label: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const job: QueuedTask = {
        deadline: Date.now() + timeoutMs,
        run: () => {
          window.clearTimeout(timer);
          timer = window.setTimeout(job.expire, timeoutMs);
          // Resolve synchronous throws and asynchronous failures through the same
          // path, releasing the slot only when the actual operation settles.
          void Promise.resolve().then(task).then(resolve, reject).finally(() => {
            window.clearTimeout(timer);
            this.active = false;
            this.onDepthChange(this.depth);
            this.startNext();
          });
        },
        expire: () => {
          window.clearTimeout(timer);
          const queued = this.waiting.delete(job);
          if (queued) this.onDepthChange(this.depth);
          const message = queued
            ? t("{p0} 等待前一个操作超过 {p1} 秒，命令未执行。请稍后重试。", { p0: t(label), p1: Math.round(timeoutMs / 1000) })
            : t("{p0} 超过 {p1} 秒仍未返回，请到“输出”页查看日志或稍后重试。", { p0: t(label), p1: Math.round(timeoutMs / 1000) });
          reject(new ExecTimeoutError(message, !queued));
        },
      };
      let timer = window.setTimeout(job.expire, timeoutMs);
      this.waiting.add(job);
      this.onDepthChange(this.depth);
      this.startNext();
    });
  }

  private startNext(): void {
    if (this.active) return;
    for (const job of this.waiting) {
      // Timers can be delayed while the event loop is busy. Check the deadline
      // before starting a queued command even if its timer has not fired yet.
      if (Date.now() >= job.deadline) {
        job.expire();
        continue;
      }
      this.waiting.delete(job);
      this.active = true;
      job.run();
      return;
    }
  }
}
