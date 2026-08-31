import type { TransparentMode } from "@/types";

export type ControlDangerAction = {
  key: string;
  args: string;
  label: string;
  message: string;
  background: boolean;
};

export function singBoxToggleAction(running: boolean): ControlDangerAction {
  return {
    key: "toggle-sing-box",
    args: running ? "service stop" : "service start",
    label: running ? "停止 sing-box" : "启动 sing-box",
    message: running
      ? "确认停止 sing-box？停止后流量可能无法继续通过 MagicNet。"
      : "确认启动 sing-box？该操作不会主动停止一个已运行的内核。",
    background: true,
  };
}

export function restartSingBoxAction(): ControlDangerAction {
  return {
    key: "restart-sing-box",
    args: "service restart sing-box",
    label: "重启 sing-box",
    message: "确认重启 sing-box？当前连接可能会短暂中断。",
    background: true,
  };
}

export function applyConfigAction(): ControlDangerAction {
  return {
    key: "apply-config",
    args: "config apply",
    label: "应用全部配置",
    message:
      "确认应用配置？运行中的 sing-box 会重启以读取最新配置，当前连接可能会短暂中断。",
    background: false,
  };
}

export function repairAction(): ControlDangerAction {
  return {
    key: "repair",
    args: "repair",
    label: "一键自修复",
    message: "确认执行一键自修复？它可能会改写配置并调整运行状态。",
    background: false,
  };
}

export function stopAllServicesAction(): ControlDangerAction {
  return {
    key: "stop-all",
    args: "service stop",
    label: "停止全部服务",
    message: "确认停止全部服务？流量可能无法继续通过 MagicNet。",
    background: true,
  };
}

export function setTransparentModeAction(
  mode: TransparentMode,
  currentMode: TransparentMode,
): ControlDangerAction {
  const targetLabel = mode === "ebpf" ? "eBPF" : "TUN";
  const currentLabel = currentMode === "ebpf" ? "eBPF" : "TUN";
  return {
    key: `transparent-set-${mode}`,
    args: `transparent set ${mode}`,
    label: `切换为 ${targetLabel}`,
    message: `确认从 ${currentLabel} 切换为 ${targetLabel}？MagicNet 会停止当前数据面，验证并启动目标模式；失败时将尝试恢复 ${currentLabel}。`,
    background: false,
  };
}

export function applyTransparentModeAction(): ControlDangerAction {
  return {
    key: "transparent-apply",
    args: "transparent apply",
    label: "应用编排模式",
    message: "确认重新应用编排模式并重启 sing-box？当前连接可能会短暂中断。",
    background: false,
  };
}
