import type { AppPolicyMode } from "./appPolicyInsights";

export type AppPolicyChangeInput = {
  mode: AppPolicyMode;
  proxy: string[];
  bypass: string[];
  installedPackages: Set<string>;
};

export type AppPolicyChangeOperation =
  | { type: "mode"; mode: AppPolicyMode }
  | { type: "add"; target: "proxy" | "bypass"; packages: string[] }
  | { type: "remove"; target: "proxy" | "bypass"; packages: string[] };

export type AppPolicyChangePlan = {
  title: string;
  items: Array<{ label: string; value: string; tone: "success" | "warning" | "danger" | "neutral" }>;
  warnings: string[];
};

export function buildAppPolicyChangePlan(input: AppPolicyChangeInput, operation: AppPolicyChangeOperation): AppPolicyChangePlan {
  const before = normalizeState(input.mode, input.proxy, input.bypass);
  const after = applyOperation(before, operation);
  const listChanged = changedPackages(before, after);
  const routingChanged = effectiveRoutingChanges(before, after, input.installedPackages);
  const conflicts = after.proxy.filter((pkg) => after.bypass.includes(pkg));
  const title = operationTitle(operation);
  const items = [
    item("模式", `${before.mode} -> ${after.mode}`, before.mode === after.mode ? "neutral" : "warning"),
    item("Proxy", `${before.proxy.length} -> ${after.proxy.length}`, after.proxy.length >= before.proxy.length ? "success" : "warning"),
    item("Bypass", `${before.bypass.length} -> ${after.bypass.length}`, after.bypass.length >= before.bypass.length ? "success" : "warning"),
    item("名单变化", `${listChanged.length} 个`, listChanged.length ? "warning" : "neutral"),
    item("路由变化", routingChanged === null ? "未读取应用" : `${routingChanged} 个`, routingChanged === null ? "warning" : routingChanged ? "warning" : "neutral")
  ];
  const warnings = [
    ...(routingChanged === null ? ["未读取已安装应用，只能预览名单变化，无法计算实际路由影响。"] : []),
    ...modeWarnings(before.mode, after),
    ...movedPackageWarnings(before, after),
    ...(conflicts.length ? [`操作后仍有 ${conflicts.length} 个包同时存在于 Proxy 和 Bypass。`] : [])
  ];
  return { title, items, warnings };
}

function normalizeState(mode: AppPolicyMode, proxy: string[], bypass: string[]): { mode: AppPolicyMode; proxy: string[]; bypass: string[] } {
  return { mode, proxy: unique(proxy), bypass: unique(bypass) };
}

function applyOperation(
  state: { mode: AppPolicyMode; proxy: string[]; bypass: string[] },
  operation: AppPolicyChangeOperation
): { mode: AppPolicyMode; proxy: string[]; bypass: string[] } {
  if (operation.type === "mode") return { ...state, mode: operation.mode };
  const proxy = [...state.proxy];
  const bypass = [...state.bypass];
  for (const pkg of unique(operation.packages)) {
    if (operation.type === "add") {
      if (operation.target === "proxy") {
        addUnique(proxy, pkg);
        removeValue(bypass, pkg);
      } else {
        addUnique(bypass, pkg);
        removeValue(proxy, pkg);
      }
    } else if (operation.target === "proxy") {
      removeValue(proxy, pkg);
    } else {
      removeValue(bypass, pkg);
    }
  }
  return { mode: state.mode, proxy, bypass };
}

function changedPackages(
  before: { proxy: string[]; bypass: string[] },
  after: { proxy: string[]; bypass: string[] }
): string[] {
  const all = unique([...before.proxy, ...before.bypass, ...after.proxy, ...after.bypass]);
  return all.filter((pkg) => before.proxy.includes(pkg) !== after.proxy.includes(pkg) || before.bypass.includes(pkg) !== after.bypass.includes(pkg));
}

function modeWarnings(beforeMode: AppPolicyMode, after: { mode: AppPolicyMode; proxy: string[]; bypass: string[] }): string[] {
  if (beforeMode === after.mode) return [];
  if (after.mode === "whitelist" && !after.proxy.length) return ["白名单模式下 Proxy 为空，未列出应用将绕过 TUN。"];
  if (after.mode === "blacklist" && !after.bypass.length) return ["黑名单模式下 Bypass 为空，除系统排除外应用会默认进入 TUN。"];
  return [];
}

function effectiveRoutingChanges(
  before: { mode: AppPolicyMode; proxy: string[]; bypass: string[] },
  after: { mode: AppPolicyMode; proxy: string[]; bypass: string[] },
  installedPackages: Set<string>
): number | null {
  if (!installedPackages.size) return null;
  return Array.from(installedPackages).filter((pkg) => effectiveRoute(before, pkg) !== effectiveRoute(after, pkg)).length;
}

function effectiveRoute(state: { mode: AppPolicyMode; proxy: string[]; bypass: string[] }, pkg: string): "proxy" | "tun" | "bypass" {
  if (state.proxy.includes(pkg)) return "proxy";
  if (state.bypass.includes(pkg) || state.mode === "whitelist") return "bypass";
  return "tun";
}

function movedPackageWarnings(before: { proxy: string[]; bypass: string[] }, after: { proxy: string[]; bypass: string[] }): string[] {
  const toProxy = after.proxy.filter((pkg) => before.bypass.includes(pkg));
  const toBypass = after.bypass.filter((pkg) => before.proxy.includes(pkg));
  return [
    ...(toProxy.length ? [`${toProxy.length} 个包会从 Bypass 移到 Proxy。`] : []),
    ...(toBypass.length ? [`${toBypass.length} 个包会从 Proxy 移到 Bypass。`] : [])
  ];
}

function operationTitle(operation: AppPolicyChangeOperation): string {
  if (operation.type === "mode") return `切换到 ${operation.mode}`;
  const count = unique(operation.packages).length;
  return operation.type === "add" ? `加入 ${operation.target}：${count} 个包` : `移除 ${operation.target}：${count} 个包`;
}

function addUnique(values: string[], value: string): void {
  if (!values.includes(value)) values.push(value);
}

function removeValue(values: string[], value: string): void {
  const index = values.indexOf(value);
  if (index >= 0) values.splice(index, 1);
}

function unique(values: string[]): string[] {
  return Array.from(new Set(values.filter(Boolean)));
}

function item(label: string, value: string, tone: AppPolicyChangePlan["items"][number]["tone"]): AppPolicyChangePlan["items"][number] {
  return { label, value, tone };
}
