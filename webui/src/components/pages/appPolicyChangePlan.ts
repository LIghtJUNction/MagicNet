import { t } from "@/i18n";
import type { AppPolicyMode } from "./appPolicyInsights.ts";
import {
  appRouteDns,
  appRouteLabel,
  appRouteTraffic,
  defaultAppRoute,
  type AppRouteKind,
} from "./appPolicyRouteModel.ts";

export type AppPolicyChangeInput = {
  mode: AppPolicyMode;
  proxy: string[];
  direct: string[];
  bypass: string[];
  installedPackages: Set<string>;
};

export type AppPolicyChangeOperation =
  | { type: "mode"; mode: AppPolicyMode }
  | { type: "add"; target: "proxy" | "direct" | "bypass"; packages: string[] }
  | { type: "remove"; target: "proxy" | "direct" | "bypass"; packages: string[] }
  | { type: "reapply" };

export type AppPolicyRoutePreview = {
  subject: string;
  before: string;
  after: string;
  traffic: string;
  dns: string;
  activation: string;
};

export type AppPolicyChangePlan = {
  title: string;
  items: Array<{ label: string; value: string; tone: "success" | "warning" | "danger" | "neutral" }>;
  warnings: string[];
  routePreview: AppPolicyRoutePreview;
};

export function buildAppPolicyChangePlan(input: AppPolicyChangeInput, operation: AppPolicyChangeOperation): AppPolicyChangePlan {
  const before = normalizeState(input.mode, input.proxy, input.direct, input.bypass);
  const after = applyOperation(before, operation);
  const listChanged = changedPackages(before, after);
  const routingChanged = effectiveRoutingChanges(before, after, input.installedPackages);
  const conflicts = unique([
    ...after.proxy.filter((pkg) => after.direct.includes(pkg) || after.bypass.includes(pkg)),
    ...after.direct.filter((pkg) => after.bypass.includes(pkg))
  ]);
  const title = operationTitle(operation);
  const items = operation.type === "reapply" ? [
    item(t('名单'), t('保持不变'), "neutral"),
    item(t('包名映射'), t('重新解析'), "warning"),
    item(t('核心'), t('重新启动'), "warning"),
  ] : [
    item(t('模式'), `${before.mode} -> ${after.mode}`, before.mode === after.mode ? "neutral" : "warning"),
    item("Proxy", `${before.proxy.length} -> ${after.proxy.length}`, after.proxy.length >= before.proxy.length ? "success" : "warning"),
    item("Direct", `${before.direct.length} -> ${after.direct.length}`, after.direct.length >= before.direct.length ? "success" : "warning"),
    item("Bypass", `${before.bypass.length} -> ${after.bypass.length}`, after.bypass.length >= before.bypass.length ? "success" : "warning"),
    item(t('名单变化'), t('{count} 个', { count: listChanged.length }), listChanged.length ? "warning" : "neutral"),
    item(t('路由变化'), routingChanged === null ? t('未读取应用') : t('{routingChanged} 个', { routingChanged: routingChanged }), routingChanged === null ? "warning" : routingChanged ? "warning" : "neutral")
  ];
  const warnings = operation.type === "reapply" ? [
    t('仅在应用重装、新增工作资料／Android 用户或 UID 改变后需要手动执行。'),
  ] : [
    ...(routingChanged === null ? [t('未读取已安装应用，只能预览名单变化，无法计算实际路由影响。')] : []),
    ...modeWarnings(before.mode, after),
    ...movedPackageWarnings(before, after),
    ...(conflicts.length ? [t('操作后仍有 {count} 个包同时存在于多个应用策略名单。', { count: conflicts.length })] : [])
  ];
  return { title, items, warnings, routePreview: buildRoutePreview(before, after, operation) };
}

function normalizeState(mode: AppPolicyMode, proxy: string[], direct: string[], bypass: string[]) {
  return { mode, proxy: unique(proxy), direct: unique(direct), bypass: unique(bypass) };
}

function applyOperation(
  state: { mode: AppPolicyMode; proxy: string[]; direct: string[]; bypass: string[] },
  operation: AppPolicyChangeOperation
): { mode: AppPolicyMode; proxy: string[]; direct: string[]; bypass: string[] } {
  if (operation.type === "reapply") return state;
  if (operation.type === "mode") return { ...state, mode: operation.mode };
  const proxy = [...state.proxy];
  const direct = [...state.direct];
  const bypass = [...state.bypass];
  for (const pkg of unique(operation.packages)) {
    if (operation.type === "add") {
      if (operation.target === "proxy") {
        addUnique(proxy, pkg);
        removeValue(direct, pkg);
        removeValue(bypass, pkg);
      } else if (operation.target === "direct") {
        addUnique(direct, pkg);
        removeValue(proxy, pkg);
        removeValue(bypass, pkg);
      } else {
        addUnique(bypass, pkg);
        removeValue(proxy, pkg);
        removeValue(direct, pkg);
      }
    } else if (operation.target === "proxy") {
      removeValue(proxy, pkg);
    } else if (operation.target === "direct") {
      removeValue(direct, pkg);
    } else {
      removeValue(bypass, pkg);
    }
  }
  return { mode: state.mode, proxy, direct, bypass };
}

function changedPackages(
  before: { proxy: string[]; direct: string[]; bypass: string[] },
  after: { proxy: string[]; direct: string[]; bypass: string[] }
): string[] {
  const all = unique([...before.proxy, ...before.direct, ...before.bypass, ...after.proxy, ...after.direct, ...after.bypass]);
  return all.filter((pkg) =>
    before.proxy.includes(pkg) !== after.proxy.includes(pkg)
    || before.direct.includes(pkg) !== after.direct.includes(pkg)
    || before.bypass.includes(pkg) !== after.bypass.includes(pkg));
}

function modeWarnings(beforeMode: AppPolicyMode, after: { mode: AppPolicyMode; proxy: string[]; direct: string[]; bypass: string[] }): string[] {
  if (beforeMode === after.mode) return [];
  if (after.mode === "whitelist" && !after.proxy.length && !after.direct.length) {
    return [t('仅名单接管下 Proxy 和 Direct 均为空，所有应用都将绕过 TUN。')];
  }
  if (after.mode === "blacklist" && !after.bypass.length) return [t('全局接管下 Bypass 为空，除系统排除外应用会默认进入 TUN。')];
  return [];
}

function effectiveRoutingChanges(
  before: { mode: AppPolicyMode; proxy: string[]; direct: string[]; bypass: string[] },
  after: { mode: AppPolicyMode; proxy: string[]; direct: string[]; bypass: string[] },
  installedPackages: Set<string>
): number | null {
  if (!installedPackages.size) return null;
  return Array.from(installedPackages).filter((pkg) => effectiveRoute(before, pkg) !== effectiveRoute(after, pkg)).length;
}

function effectiveRoute(state: { mode: AppPolicyMode; proxy: string[]; direct: string[]; bypass: string[] }, pkg: string): AppRouteKind {
  if (state.proxy.includes(pkg)) return "proxy";
  if (state.direct.includes(pkg)) return "direct";
  if (state.bypass.includes(pkg)) return "bypass";
  return defaultAppRoute(state.mode);
}

function movedPackageWarnings(before: { proxy: string[]; direct: string[]; bypass: string[] }, after: { proxy: string[]; direct: string[]; bypass: string[] }): string[] {
  const toProxy = after.proxy.filter((pkg) => before.direct.includes(pkg) || before.bypass.includes(pkg));
  const toDirect = after.direct.filter((pkg) => before.proxy.includes(pkg) || before.bypass.includes(pkg));
  const toBypass = after.bypass.filter((pkg) => before.proxy.includes(pkg) || before.direct.includes(pkg));
  return [
    ...(toProxy.length ? [t('{count} 个包会从其他名单移到 Proxy。', { count: toProxy.length })] : []),
    ...(toDirect.length ? [t('{count} 个包会移到 Direct。', { count: toDirect.length })] : []),
    ...(toBypass.length ? [t('{count} 个包会从其他名单移到 Bypass TUN。', { count: toBypass.length })] : [])
  ];
}

function operationTitle(operation: AppPolicyChangeOperation): string {
  if (operation.type === "reapply") return t('重新解析 App UID');
  if (operation.type === "mode") return t('切换到 {value}', { value: operation.mode });
  const count = unique(operation.packages).length;
  return operation.type === "add" ? t('加入 {value}：{count} 个包', { value: operation.target, count: count }) : t('移除 {value}：{count} 个包', { value: operation.target, count: count });
}

function buildRoutePreview(
  before: { mode: AppPolicyMode; proxy: string[]; direct: string[]; bypass: string[] },
  after: { mode: AppPolicyMode; proxy: string[]; direct: string[]; bypass: string[] },
  operation: AppPolicyChangeOperation,
): AppPolicyRoutePreview {
  const activation = t('确认后自动解析 UID、套用配置并重启当前核心；现有连接可能短暂中断。');
  if (operation.type === "reapply") {
    return {
      subject: t('当前应用策略'),
      before: t('已保存的名单与 UID 映射'),
      after: t('相同名单，重新绑定当前 UID'),
      traffic: t('策略选择保持不变，只刷新包名对应的 Android UID。'),
      dns: t('Bypass 的数据面与 DNS 绕过边界会按当前 UID 重建。'),
      activation,
    };
  }

  if (operation.type === "mode") {
    const beforeRoute = defaultAppRoute(before.mode);
    const afterRoute = defaultAppRoute(after.mode);
    return routePreview(t('未列出的应用'), [beforeRoute], [afterRoute], activation);
  }

  const packages = unique(operation.packages);
  const beforeRoutes = packages.map((pkg) => effectiveRoute(before, pkg));
  const afterRoutes = packages.map((pkg) => effectiveRoute(after, pkg));
  return routePreview(packages.length === 1 ? packages[0] : t('{count} 个应用', { count: packages.length }), beforeRoutes, afterRoutes, activation);
}

function routePreview(
  subject: string,
  beforeRoutes: AppRouteKind[],
  afterRoutes: AppRouteKind[],
  activation: string,
): AppPolicyRoutePreview {
  const normalizedAfter = uniqueRoutes(afterRoutes);
  return {
    subject,
    before: routeSetLabel(beforeRoutes),
    after: routeSetLabel(afterRoutes),
    traffic: normalizedAfter.length === 1
      ? appRouteTraffic(normalizedAfter[0])
      : t('所选应用会按各自修改后的策略进入不同流量路径。'),
    dns: normalizedAfter.length === 1
      ? appRouteDns(normalizedAfter[0])
      : t('DNS 边界取决于每个应用修改后的有效路径。'),
    activation,
  };
}

function routeSetLabel(routes: AppRouteKind[]): string {
  const normalized = uniqueRoutes(routes);
  if (!normalized.length) return t('没有可计算的应用');
  if (normalized.length === 1) return appRouteLabel(normalized[0]);
  return normalized.map(appRouteLabel).join("；");
}

function uniqueRoutes(routes: AppRouteKind[]): AppRouteKind[] {
  return Array.from(new Set(routes));
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
