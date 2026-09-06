import { t } from "@/i18n";
import type { RuntimeState } from "@/types";
import { statusToneClasses } from "@/lib/statusTone";

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
  backgroundStatus?: string;
  runtime: RuntimeState;
  output?: string;
};

export function controlRuntimeBusy(
  phase: string,
  queueDepth: number,
  backgroundStatus = "idle",
): boolean {
  return (
    ["accepted", "queued", "running"].includes(phase) ||
    queueDepth > 0 ||
    ["running", "timeout"].includes(backgroundStatus)
  );
}

export function buildControlRuntimeInsight(
  input: ControlRuntimeInput,
): ControlRuntimeInsight {
  const running = input.runtime.singBoxState === "sing-box";
  const busy = controlRuntimeBusy(
    input.phase,
    input.queueDepth,
    input.backgroundStatus,
  );
  if (!input.hasKsu) {
    return {
      status: "warning",
      title: t("缺少设备执行通道"),
      detail:
        t("当前环境不能直接执行 root/KernelSU 操作，控制按钮只适合在真机 WebUI 使用。"),
      actions: [t("切到真机 WebUI"), t("确认 KernelSU 授权")],
    };
  }
  if (busy) {
    return {
      status: "info",
      title: t("后台任务进行中"),
      detail: t("phase={phase} queue={queueDepth}，建议等待任务结束后再切换模式或重启。", { phase: input.phase, queueDepth: input.queueDepth }),
      actions: [t("查看最近输出"), t("等待队列清空")],
    };
  }
  if (input.phase === "error") {
    if (
      /No cached sing-box nodes found|run cli sub update sing-box/i.test(
        input.output || "",
      )
    ) {
      return {
        status: "warning",
        title: t("缺少节点缓存"),
        detail:
          t("sing-box 启动前没有找到可用节点缓存。先更新订阅并重建节点，然后再启动 sing-box。"),
        actions: [t("更新订阅并重建节点"), t("再启动 sing-box")],
      };
    }
    return {
      status: "warning",
      title: t("上次操作失败"),
      detail:
        t("最近命令进入 error 状态，建议先查看最近输出再继续切换模式或重启。"),
      actions: [t("查看最近输出"), t("复制控制快照")],
    };
  }
  if (!running) {
    return {
      status: "danger",
      title: t("sing-box 未运行"),
      detail: t("代理核心未处于运行状态，优先启动或执行一键自修复。"),
      actions: [t("启动 sing-box"), t("一键自修复")],
    };
  }
  if (
    input.runtime.transparentMode === "unknown" ||
    input.runtime.transparentEffectiveMode === "unknown"
  ) {
    return {
      status: "warning",
      title: t("透明代理状态不可用"),
      detail:
        t("无法确认 configured/effective 模式；不会按 TUN 或 eBPF 猜测当前数据面。"),
      actions: [t("刷新状态"), t("查看最近输出")],
    };
  }
  if (input.runtime.fswatch === "stopped") {
    return {
      status: "warning",
      title: t("文件监听未运行"),
      detail: t("sing-box 正在运行，但 fswatch 停止，配置变更可能不会自动应用。"),
      actions: [t("重启 sing-box"), t("应用配置")],
    };
  }
  return {
    status: "ok",
    title: t("控制面板就绪"),
    detail: t("sing-box 正在运行，当前透明模式为 {transparentMode}。", { transparentMode: input.runtime.transparentMode }),
    actions: [t("打开 zashboard"), t("按需切换模式")],
  };
}

export function controlInsightTone(
  status: ControlRuntimeInsight["status"],
): string {
  if (status === "ok") return statusToneClasses("ok");
  if (status === "danger") return statusToneClasses("danger");
  if (status === "warning") return statusToneClasses("warning");
  return statusToneClasses("info");
}
