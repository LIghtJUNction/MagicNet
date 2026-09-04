export type AppPolicyMode = "blacklist" | "whitelist";
export type AppRouteKind = "proxy" | "direct" | "managed" | "bypass";

export type AppPolicyRouteDefinition = {
  id: Exclude<AppRouteKind, "managed">;
  label: string;
  steps: string[];
  dnsShort: string;
  traffic: string;
  dns: string;
  useCase: string;
};

export const appPolicyRouteDefinitions: AppPolicyRouteDefinition[] = [
  {
    id: "proxy",
    label: "Proxy",
    steps: ["App", "MagicNet", "代理", "Internet"],
    dnsShort: "由 MagicNet 处理",
    traffic: "进入当前 MagicNet 数据面，并由 proxy 出站处理。",
    dns: "由 MagicNet 的 DNS 与目的地路由策略处理。",
    useCase: "需要明确强制代理的应用。",
  },
  {
    id: "direct",
    label: "Direct",
    steps: ["App", "MagicNet", "直连", "Internet"],
    dnsShort: "由 MagicNet 处理",
    traffic: "仍进入当前 MagicNet 数据面，但由 direct 出站直连。",
    dns: "由 MagicNet 的 DNS 与目的地路由策略处理。",
    useCase: "需要直连，同时仍由 MagicNet 管理的应用。",
  },
  {
    id: "bypass",
    label: "Bypass TUN",
    steps: ["App", "系统网络／外部 VPN"],
    dnsShort: "App UID 绕过*",
    traffic: "离开当前 MagicNet 数据面，交给系统网络或外部 VPN。",
    dns: "具体 App UID 会绕过 MagicNet DNS 捕获；Android 共用 netd DNS 仍可能被捕获。",
    useCase: "其他 VPN、银行或兼容性敏感应用。",
  },
];

export function defaultAppRoute(mode: AppPolicyMode): AppRouteKind {
  return mode === "whitelist" ? "bypass" : "managed";
}

export function appPolicyModeSummary(mode: AppPolicyMode): string {
  return mode === "whitelist"
    ? "仅名单接管：未列出应用绕过 MagicNet，使用系统网络。"
    : "全局接管：未列出应用进入 MagicNet，并按一般路由规则处理。";
}

export function appRouteLabel(route: AppRouteKind): string {
  if (route === "proxy") return "Proxy：MagicNet → 代理";
  if (route === "direct") return "Direct：MagicNet → 直连";
  if (route === "bypass") return "Bypass：系统网络／外部 VPN";
  return "MagicNet 一般路由规则";
}

export function appRouteTraffic(route: AppRouteKind): string {
  if (route === "managed") return "进入当前 MagicNet 数据面，并按一般路由规则决定出口。";
  return appPolicyRouteDefinitions.find((item) => item.id === route)?.traffic ?? "路由状态未知。";
}

export function appRouteDns(route: AppRouteKind): string {
  if (route === "managed") return "由 MagicNet 的 DNS 与目的地路由策略处理。";
  return appPolicyRouteDefinitions.find((item) => item.id === route)?.dns ?? "DNS 边界未知。";
}
