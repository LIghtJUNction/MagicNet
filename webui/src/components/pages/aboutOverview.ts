export const DATAPLANE_LABEL = "tun | ebpf";

export type AboutFact = {
  code: string;
  title: string;
  detail: string;
};

export type AboutStep = {
  id: string;
  title: string;
  detail: string;
};

export type AboutCheck = {
  command: string;
  expect: string;
};

export type AboutPathNode = {
  index: string;
  label: string;
  code: string;
};

export function pathFlowNodes(): AboutPathNode[] {
  return [
    { index: "01", label: "Android root", code: "ROOT" },
    { index: "02", label: DATAPLANE_LABEL, code: "DATA" },
    { index: "03", label: "sing-box", code: "CORE" },
    { index: "04", label: "策略 / 出口", code: "OUT" },
  ];
}

export function dataPlaneFacts(): AboutFact[] {
  return [
    {
      code: "ROOT",
      title: "Android root 工作台",
      detail:
        "MagicNet 通过模块 CLI 管理 sing-box，不调用应用侧 VpnService.establish()，也不会占用系统 VPN slot。",
    },
    {
      code: "DATA",
      title: "显式 tun | ebpf 数据面",
      detail:
        "默认 TUN 使用 magicnet0；eBPF 使用 local cgroup，并在确认真实下游接口后启用 shared TC。两种模式都进入同一 sing-box 策略与出口。",
    },
    {
      code: "PROOF",
      title: "以真实运行状态为准",
      detail:
        "真机是否成功，看 cli health 与 cli transparent status；只有 TUN 要求 magicnet0，eBPF 以 cgroup/TC attachment 为准。",
    },
  ];
}

export function firstRunSteps(): AboutStep[] {
  return [
    {
      id: "dns",
      title: "关闭私人 DNS",
      detail: "在系统设置中关闭私人 DNS / Private DNS，不要保留为自动。",
    },
    {
      id: "sub",
      title: "保存订阅或导入本地文件",
      detail: "在订阅页保存合法 URL，或导入 Clash YAML、分享链接、JSON 或文本订阅。",
    },
    {
      id: "health",
      title: "确认健康与透明数据面",
      detail: "健康检查没有核心/数据面阻塞项，transparent status 的 configured 与 effective 状态一致或明确标注 pending。",
    },
  ];
}

export function successChecks(): AboutCheck[] {
  return [
    {
      command: "cli health",
      expect: "没有核心或 Dataplane 阻塞项",
    },
    {
      command: "cli transparent status",
      expect: "configured/effective 模式与 attachment 状态明确",
    },
    {
      command: "tun | ebpf",
      expect: "TUN 存在 magicnet0；eBPF 报告 cgroup/TC 状态且不要求 magicnet0",
    },
  ];
}

export function formatAboutOverview(
  facts = dataPlaneFacts(),
  steps = firstRunSteps(),
  checks = successChecks(),
): string {
  return [
    "MagicNet path overview",
    `dataplane_label=${DATAPLANE_LABEL}`,
    "dataplane=sing-box tun|ebpf",
    "",
    "facts",
    ...facts.map((item) => `${item.code}\t${item.title}\t${item.detail}`),
    "",
    "first-run",
    ...steps.map((item, index) => `${index + 1}. ${item.title}: ${item.detail}`),
    "",
    "success",
    ...checks.map((item) => `${item.command}\t${item.expect}`),
  ].join("\n");
}
