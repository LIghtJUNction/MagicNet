import type { RuntimeState } from "@/types";

export type ControlRuntimeInsight = {
  status: "ok" | "warning" | "danger" | "info";
  title: string;
  detail: string;
  actions: string[];
};

type ControlRuntimeInput = {
  hasKsu: boolean;
  phase: string;
  queueDepth: number;
  runtime: RuntimeState;
};

export function controlRuntimeBusy(phase: string, queueDepth: number): boolean {
  return ["accepted", "queued", "running"].includes(phase) || queueDepth > 0;
}

export function buildControlRuntimeInsight(input: ControlRuntimeInput): ControlRuntimeInsight {
  const running = input.runtime.singBoxState === "sing-box";
  const busy = controlRuntimeBusy(input.phase, input.queueDepth);
  if (!input.hasKsu) {
    return {
      status: "warning",
      title: "缺少设备执行通道",
      detail: "当前环境不能直接执行 root/KernelSU 操作，控制按钮只适合在真机 WebUI 使用。",
      actions: ["切到真机 WebUI", "确认 KernelSU 授权"]
    };
  }
  if (busy) {
    return {
      status: "info",
      title: "后台任务进行中",
      detail: `phase=${input.phase} queue=${input.queueDepth}，建议等待任务结束后再切换模式或重启。`,
      actions: ["查看最近输出", "等待队列清空"]
    };
  }
  if (input.phase === "error") {
    return {
      status: "warning",
      title: "上次操作失败",
      detail: "最近命令进入 error 状态，建议先查看最近输出再继续切换模式或重启。",
      actions: ["查看最近输出", "复制控制快照"]
    };
  }
  if (!running) {
    return {
      status: "danger",
      title: "sing-box 未运行",
      detail: "代理核心未处于运行状态，优先启动或执行一键自修复。",
      actions: ["启动 sing-box", "一键自修复"]
    };
  }
  if (input.runtime.fswatch === "stopped") {
    return {
      status: "warning",
      title: "文件监听未运行",
      detail: "sing-box 正在运行，但 fswatch 停止，配置变更可能不会自动应用。",
      actions: ["重启 sing-box", "应用配置"]
    };
  }
  return {
    status: "ok",
    title: "控制面板就绪",
    detail: `sing-box 正在运行，当前透明模式为 ${input.runtime.transparentMode}。`,
    actions: ["打开 zashboard", "按需切换模式"]
  };
}

export function controlInsightTone(status: ControlRuntimeInsight["status"]): string {
  if (status === "ok") return "border-lime-400/20 bg-lime-400/10 text-lime-100";
  if (status === "danger") return "border-red-400/30 bg-red-400/10 text-red-100";
  if (status === "warning") return "border-amber-400/30 bg-amber-400/10 text-amber-100";
  return "border-sky-400/20 bg-sky-400/10 text-sky-100";
}
