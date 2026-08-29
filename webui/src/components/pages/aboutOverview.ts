export const DATAPLANE_IFACE = "magicnet0";

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

export function dataPlaneFacts(): AboutFact[] {
  return [
    {
      code: "ROOT",
      title: "Android root 工作台",
      detail:
        "MagicNet 通过模块 CLI 管理 sing-box，不调用应用侧 VpnService.establish()，也不会占用系统 VPN slot。",
    },
    {
      code: "TUN",
      title: "sing-box magicnet0 TUN",
      detail:
        "当前主线只有 TUN 数据面。流量路径是 Android root → magicnet0 → sing-box → 策略/出口。",
    },
    {
      code: "PROOF",
      title: "以真实接口为准",
      detail:
        "真机是否成功，看 cli health、cli transparent status 和 magicnet0 是否存在。",
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
      title: "确认健康与 TUN",
      detail: "健康检查没有核心/TUN 阻塞项，transparent status 显示 TUN，系统存在 magicnet0。",
    },
  ];
}

export function successChecks(): AboutCheck[] {
  return [
    {
      command: "cli health",
      expect: "没有核心或 TUN 阻塞项",
    },
    {
      command: "cli transparent status",
      expect: "透明路径为 TUN",
    },
    {
      command: "magicnet0",
      expect: "系统存在 magicnet0 接口",
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
    `iface=${DATAPLANE_IFACE}`,
    "dataplane=sing-box TUN",
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
