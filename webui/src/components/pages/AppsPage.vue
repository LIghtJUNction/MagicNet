<script setup lang="ts">
import { t } from "@/i18n";
import { CheckCheck, CheckCircle2, Copy, ListFilter, Plus, RefreshCw, RotateCcw, ShieldCheck, Trash2, X } from "lucide-vue-next";
import { computed, onMounted, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import ConfirmPanel from "@/components/ui/ConfirmPanel.vue";
import Input from "@/components/ui/Input.vue";
import InsightChip from "@/components/ui/InsightChip.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import RemovableTag from "@/components/ui/RemovableTag.vue";
import SearchField from "@/components/ui/SearchField.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText, execFailed, redactedCliPreview } from "@/utils";
import AppPolicyRouteGuide from "./AppPolicyRouteGuide.vue";
import { buildAppPolicySummary, formatAppPolicyFullReport, formatAppPolicySafeReport, isValidPackageName } from "./appPolicyInsights";
import { buildAppPolicyChangePlan, type AppPolicyChangeOperation, type AppPolicyChangePlan } from "./appPolicyChangePlan";

const { state, runCli, refreshApps, refreshPackages, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const removedBypass = ref<string[]>([]);
const pendingAppAction = ref<PendingAppAction | null>(null);
const appReportCopied = ref(false);
const safeReportCopied = ref(false);
const selectedPackages = ref<string[]>([]);
const recommendedBypass = ref<string[]>([]);

type PendingAppAction = {
  key: string;
  command: string;
  message: string;
  plan: AppPolicyChangePlan;
  run: () => Promise<void>;
};
type AppTarget = "proxy" | "direct" | "bypass";

const recycledBypass = computed(() => {
  const active = new Set(state.appPolicy.bypass);
  return removedBypass.value.filter((pkg) => !active.has(pkg));
});

const installedNames = computed(() => new Set(state.packages.map((item) => item.packageName)));

const filteredPackages = computed(() => {
  const query = state.packageQuery.trim().toLowerCase();
  const listed = state.packages.filter((item) => {
    if (!query) return true;
    return item.packageName.toLowerCase().includes(query);
  });
  return listed.slice(0, 120);
});
const visiblePackageNames = computed(() => filteredPackages.value.map((app) => app.packageName));
const allVisibleSelected = computed(() => (
  visiblePackageNames.value.length > 0
  && visiblePackageNames.value.every((pkg) => selectedPackages.value.includes(pkg))
));

const availableRecommendedBypass = computed(() => {
  const active = new Set([...state.appPolicy.proxy, ...state.appPolicy.direct, ...state.appPolicy.bypass]);
  const installed = installedNames.value;
  return recommendedBypass.value.filter((pkg) => {
    if (active.has(pkg)) return false;
    return installed.size === 0 || installed.has(pkg);
  });
});

const policySummary = computed(() => buildAppPolicySummary(
  state.appPolicy.mode,
  state.appPolicy.proxy,
  state.appPolicy.direct,
  state.appPolicy.bypass,
  installedNames.value,
  availableRecommendedBypass.value.length
));

function actionPlan(operation: AppPolicyChangeOperation): AppPolicyChangePlan {
  return buildAppPolicyChangePlan({
    mode: state.appPolicy.mode,
    proxy: state.appPolicy.proxy,
    direct: state.appPolicy.direct,
    bypass: state.appPolicy.bypass,
    installedPackages: installedNames.value
  }, operation);
}

function commandFailed(text: string): boolean {
  return execFailed(text);
}

function rememberRemovedBypass(pkg: string): void {
  removedBypass.value = [pkg, ...removedBypass.value.filter((item) => item !== pkg)].slice(0, 24);
}

function forgetRemovedBypass(pkg: string): void {
  removedBypass.value = removedBypass.value.filter((item) => item !== pkg);
}

function targetList(target: AppTarget): string[] {
  return state.appPolicy[target];
}

function moveLocalPackage(pkg: string, target: AppTarget): void {
  state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
  state.appPolicy.direct = state.appPolicy.direct.filter((item) => item !== pkg);
  state.appPolicy.bypass = state.appPolicy.bypass.filter((item) => item !== pkg);
  targetList(target).push(pkg);
}

function validateAppPackage(pkg: string, target: AppTarget): boolean {
  if (!isValidPackageName(pkg)) {
    state.output = t('包名格式不对。示例：com.android.chrome');
    return false;
  }
  const list = targetList(target);
  if (list.includes(pkg)) {
    state.output = t('{pkg} 已存在，已自动去重。', { pkg: pkg });
    state.packageInput = "";
    return false;
  }
  return true;
}

function addApp(target: AppTarget): void {
  requestAddPackage(state.packageInput.trim(), target, `add-${target}`);
}

function togglePackageSelection(pkg: string): void {
  selectedPackages.value = selectedPackages.value.includes(pkg)
    ? selectedPackages.value.filter((item) => item !== pkg)
    : [...selectedPackages.value, pkg];
}

function selectVisiblePackages(): void {
  if (allVisibleSelected.value) {
    const visible = new Set(visiblePackageNames.value);
    selectedPackages.value = selectedPackages.value.filter((pkg) => !visible.has(pkg));
    return;
  }
  selectedPackages.value = Array.from(new Set([
    ...selectedPackages.value,
    ...visiblePackageNames.value,
  ]));
}

async function applyBatchAdd(packages: string[], target: AppTarget): Promise<void> {
  await withAction(`batch-${target}`, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousDirect = [...state.appPolicy.direct];
    const previousBypass = [...state.appPolicy.bypass];
    packages.forEach((pkg) => moveLocalPackage(pkg, target));
    const quoted = packages.map((pkg) => shellQuote(pkg)).join(" ");
    const text = await runCli(
      `app add-many ${target} ${quoted}`,
      t('批量归类 {count} 个应用到 {target}', { count: packages.length, target: target }),
      true,
    );
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    selectedPackages.value = selectedPackages.value.filter((pkg) => !packages.includes(pkg));
    state.output = t('已批量归类 {count} 个应用到 {target}。', { count: packages.length, target: target });
    if (!(await refreshApps(true))) {
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
      selectedPackages.value = Array.from(new Set([...selectedPackages.value, ...packages]));
    }
  });
}

function requestBatchAdd(target: AppTarget): void {
  const packages = [...selectedPackages.value];
  if (!packages.length) return;
  pendingAppAction.value = {
    key: `batch-${target}`,
    command: `app add-many ${target} (${packages.length} packages)`,
    message: t('确认把已选的 {count} 个应用批量归类到 {target}？只会执行一次策略写入和核心重启。', { count: packages.length, target: target }),
    plan: actionPlan({ type: "add", target, packages }),
    run: () => applyBatchAdd(packages, target),
  };
}

async function addPackage(pkg: string, target: AppTarget, key = `add-${target}`): Promise<void> {
  await withAction(key, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousDirect = [...state.appPolicy.direct];
    const previousBypass = [...state.appPolicy.bypass];
    moveLocalPackage(pkg, target);
    state.packageInput = "";
    if (target === "bypass") forgetRemovedBypass(pkg);
    state.output = t('已加入界面，正在保存 {pkg}...', { pkg: pkg });
    const text = await runCli(
      `app add ${shellQuote(pkg)} ${target}`,
      t('添加应用 {pkg}', { pkg: pkg }),
      true,
      redactedCliPreview(`app add [package] ${target}`),
    );
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    if (!(await refreshApps(true))) {
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
    }
  });
}

function requestAddPackage(pkg: string, target: AppTarget, key = `add-${target}`): void {
  if (!validateAppPackage(pkg, target)) return;
  pendingAppAction.value = {
    key,
    command: `app add ${pkg} ${target}`,
    message: target === "proxy"
      ? t('确认把 {pkg} 加入 Proxy？该应用将强制走 MagicNet proxy。', { pkg: pkg })
      : target === "direct"
        ? t('确认把 {pkg} 加入 Direct？该应用保留在当前 MagicNet 数据面内并强制直连。', { pkg: pkg })
        : t('确认把 {pkg} 加入 Bypass TUN？该应用将完全离开 MagicNet，其他 VPN 或上游网络仍可能提供访问能力。', { pkg: pkg }),
    plan: actionPlan({ type: "add", target, packages: [pkg] }),
    run: () => addPackage(pkg, target, key)
  };
}

async function removeApp(pkg: string, target: AppTarget): Promise<void> {
  await withAction(`remove-${target}-${pkg}`, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousDirect = [...state.appPolicy.direct];
    const previousBypass = [...state.appPolicy.bypass];
    if (target === "proxy") {
      state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    } else if (target === "direct") {
      state.appPolicy.direct = state.appPolicy.direct.filter((item) => item !== pkg);
    } else {
      state.appPolicy.bypass = state.appPolicy.bypass.filter((item) => item !== pkg);
      rememberRemovedBypass(pkg);
    }
    state.output = t('已从界面移除 {pkg}，正在后台保存...', { pkg: pkg });
    const text = await runCli(
      `app remove ${shellQuote(pkg)} ${target}`,
      t('移除应用 {pkg}', { pkg: pkg }),
      true,
      redactedCliPreview(`app remove [package] ${target}`),
    );
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    if (!(await refreshApps(true))) {
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
    }
  });
}

async function restoreBypass(pkg: string): Promise<void> {
  await withAction(`restore-bypass-${pkg}`, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousDirect = [...state.appPolicy.direct];
    const previousBypass = [...state.appPolicy.bypass];
    moveLocalPackage(pkg, "bypass");
    state.output = t('正在把 {pkg} 加回 Bypass...', { pkg: pkg });
    const text = await runCli(
      `app add ${shellQuote(pkg)} bypass`,
      t('恢复 Bypass 应用 {pkg}', { pkg: pkg }),
      true,
      redactedCliPreview("app add [package] bypass"),
    );
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    if (!(await refreshApps(true))) {
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    forgetRemovedBypass(pkg);
  });
}

async function setMode(mode: "blacklist" | "whitelist"): Promise<void> {
  await withAction(`mode-${mode}`, async () => {
    const text = await runCli(`app mode ${mode}`, mode === "blacklist" ? t('切换全局接管') : t('切换仅名单接管'));
    if (commandFailed(text)) return;
    await refreshApps(true);
  });
}

async function reapplyAppPolicy(): Promise<void> {
  await withAction("reapply-app-policy", async () => {
    const text = await runCli("app apply", t('重新解析 App UID 并套用策略'));
    if (commandFailed(text)) return;
    await refreshApps(true);
  });
}

function requestReapplyAppPolicy(): void {
  pendingAppAction.value = {
    key: "reapply-app-policy",
    command: "app apply",
    message: t('确认按当前已安装应用重新解析 UID 并套用现有策略？名单不会改变，但当前核心会重启。'),
    plan: actionPlan({ type: "reapply" }),
    run: reapplyAppPolicy,
  };
}

function requestSetMode(mode: "blacklist" | "whitelist"): void {
  pendingAppAction.value = {
    key: `mode-${mode}`,
    command: `app mode ${mode}`,
    message: mode === "blacklist"
      ? t('确认切换到全局接管？未列出应用会进入当前透明数据面，只有 Bypass 名单走系统网络。')
      : t('确认切换到仅名单接管？只有 Proxy 和 Direct 名单进入当前透明数据面，未列出应用走系统网络。'),
    plan: actionPlan({ type: "mode", mode }),
    run: () => setMode(mode)
  };
}

async function searchPackages(): Promise<void> {
  await withAction("search-packages", () => refreshPackages());
}

async function copyAppPolicyReport(): Promise<void> {
  appReportCopied.value = await copyText(formatAppPolicyFullReport({
    mode: state.appPolicy.mode,
    proxy: state.appPolicy.proxy,
    direct: state.appPolicy.direct,
    bypass: state.appPolicy.bypass,
    summary: policySummary.value
  }));
  state.output = appReportCopied.value ? t('应用策略完整快照已复制。') : t('剪贴板不可用，应用策略快照未复制。');
}

async function copyAppPolicySafeReport(): Promise<void> {
  safeReportCopied.value = await copyText(formatAppPolicySafeReport({
    mode: state.appPolicy.mode,
    proxy: state.appPolicy.proxy,
    direct: state.appPolicy.direct,
    bypass: state.appPolicy.bypass,
    summary: policySummary.value
  }));
  state.output = safeReportCopied.value ? t('应用策略隐私摘要已复制。') : t('剪贴板不可用，应用策略摘要未复制。');
}

async function applyRecommendedBypass(): Promise<void> {
  await withAction("apply-recommended-bypass", async () => {
    const packages = availableRecommendedBypass.value;
    if (!packages.length) {
      state.output = t('没有可加入的推荐 Bypass 应用。');
      return;
    }
    const previousProxy = [...state.appPolicy.proxy];
    const previousDirect = [...state.appPolicy.direct];
    const previousBypass = [...state.appPolicy.bypass];
    packages.forEach((pkg) => {
      if (!state.appPolicy.bypass.includes(pkg)) state.appPolicy.bypass.push(pkg);
      state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
      state.appPolicy.direct = state.appPolicy.direct.filter((item) => item !== pkg);
      forgetRemovedBypass(pkg);
    });
    const quoted = packages.map((pkg) => shellQuote(pkg)).join(" ");
    const text = await runCli(`app add-many bypass ${quoted}`, t('应用推荐 Bypass 名单'));
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    if (!(await refreshApps(true))) {
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.direct = previousDirect;
      state.appPolicy.bypass = previousBypass;
    }
  });
}

function requestRecommendedBypass(): void {
  const count = availableRecommendedBypass.value.length;
  pendingAppAction.value = {
    key: "apply-recommended-bypass",
    command: `app add-many bypass (${count} packages)`,
    message: t('确认把 {count} 个推荐应用加入 Bypass？这会批量改写应用策略。', { count: count }),
    plan: actionPlan({ type: "add", target: "bypass", packages: availableRecommendedBypass.value }),
    run: applyRecommendedBypass
  };
}

function requestRemoveApp(pkg: string, target: AppTarget): void {
  pendingAppAction.value = {
    key: `remove-${target}-${pkg}`,
    command: `app remove ${pkg} ${target}`,
    message: t('确认从 {target} 名单移除 {pkg}？', { target: target, pkg: pkg }),
    plan: actionPlan({ type: "remove", target, packages: [pkg] }),
    run: () => removeApp(pkg, target)
  };
}

function requestRestoreBypass(pkg: string): void {
  pendingAppAction.value = {
    key: `restore-bypass-${pkg}`,
    command: `app add ${pkg} bypass`,
    message: t('确认把 {pkg} 加回 Bypass 名单？', { pkg: pkg }),
    plan: actionPlan({ type: "add", target: "bypass", packages: [pkg] }),
    run: () => restoreBypass(pkg)
  };
}

function cancelAppAction(): void {
  pendingAppAction.value = null;
}

async function confirmAppAction(): Promise<void> {
  const action = pendingAppAction.value;
  if (!action) return;
  // Consume only this confirmation; a new one may be opened while it runs.
  pendingAppAction.value = null;
  await action.run();
}

onMounted(() => {
  void runCli("app recommendations", t('读取动态推荐 Bypass'), true).then((text) => {
    if (execFailed(text)) return;
    recommendedBypass.value = Array.from(new Set(
      text.split(/\r?\n/).map((item) => item.trim()).filter(isValidPackageName)
    ));
  });
  if (!state.packages.length) void refreshPackages(true);
});
</script>

<template>
  <div class="grid gap-4">
    <PageHeader :overline="t('应用策略')" :title="t('应用名单')">
      <div class="flex flex-wrap gap-2">
        <Button variant="outline" :loading="isRunning('refresh-apps')" @click="withAction('refresh-apps', () => refreshApps())"><RefreshCw :size="17" />{{ t('读取名单') }}</Button>
        <Button variant="outline" :loading="isRunning('search-packages')" @click="searchPackages"><ListFilter :size="17" />{{ t('刷新应用') }}</Button>
        <details class="config-action-menu">
          <summary>{{ t('更多') }}</summary>
          <div>
        <Button variant="outline" :loading="isRunning('copy-app-policy-report')" @click="withAction('copy-app-policy-report', copyAppPolicyReport)"><Copy :size="17" />{{ appReportCopied ? t('已复制快照') : t('复制完整快照') }}</Button>
        <Button variant="outline" :loading="isRunning('copy-app-policy-safe-report')" @click="withAction('copy-app-policy-safe-report', copyAppPolicySafeReport)"><Copy :size="17" />{{ safeReportCopied ? t('已复制摘要') : t('复制隐私摘要') }}</Button>
        <Button :loading="isRunning('apply-recommended-bypass')" :disabled="availableRecommendedBypass.length === 0" @click="requestRecommendedBypass"><ShieldCheck :size="17" />{{ t('应用推荐名单') }}</Button>
          </div>
        </details>
      </div>
    </PageHeader>

    <Teleport to="body">
      <Transition name="sheet">
        <div v-if="pendingAppAction" class="fixed inset-0 z-[70]" role="presentation">
          <button
            class="mn-overlay absolute inset-0 size-full"
            type="button"
            :aria-label="t('取消应用策略操作')"
            @click="cancelAppAction"
          />
          <div
            class="absolute inset-x-3 bottom-[max(1rem,env(safe-area-inset-bottom))] mx-auto max-h-[min(80dvh,680px)] max-w-3xl overflow-auto"
            role="dialog"
            aria-modal="true"
            aria-labelledby="app-policy-confirm-title"
          >
            <ConfirmPanel
              :title="t('确认应用策略')"
              :detail="pendingAppAction.message"
              :command="pendingAppAction.command"
              :loading="isRunning(pendingAppAction.key)"
              :confirm-label="t('应用更改')"
              confirm-variant="default"
              @cancel="cancelAppAction"
              @confirm="confirmAppAction"
            >
              <p id="app-policy-confirm-title" class="sr-only">{{ pendingAppAction.message }}</p>
              <div class="mt-3 flex flex-wrap gap-2">
                <InsightChip
                  v-for="item in pendingAppAction.plan.items"
                  :key="item.label"
                  :label="item.label"
                  :value="item.value"
                  :tone="item.tone"
                />
              </div>
              <p v-if="pendingAppAction.plan.warnings.length" class="mt-2 text-xs leading-5 text-[var(--mn-warning)]/80">
                {{ pendingAppAction.plan.warnings.join("；") }}
              </p>
              <div class="mt-3 grid gap-2 rounded-[var(--mn-radius-md)] border border-[var(--mn-border)] bg-[var(--mn-surface-raised)] p-3 text-xs leading-5">
                <p class="font-semibold text-[var(--mn-ink)]">{{ pendingAppAction.plan.routePreview.subject }}</p>
                <dl class="grid gap-1 text-[var(--mn-ink-muted)] sm:grid-cols-[auto_minmax(0,1fr)] sm:gap-x-3">
                  <dt class="font-semibold text-[var(--mn-ink-soft)]">{{ t('修改前') }}</dt>
                  <dd>{{ pendingAppAction.plan.routePreview.before }}</dd>
                  <dt class="font-semibold text-[var(--mn-ink-soft)]">{{ t('修改后') }}</dt>
                  <dd>{{ pendingAppAction.plan.routePreview.after }}</dd>
                  <dt class="font-semibold text-[var(--mn-ink-soft)]">{{ t('数据') }}</dt>
                  <dd>{{ pendingAppAction.plan.routePreview.traffic }}</dd>
                  <dt class="font-semibold text-[var(--mn-ink-soft)]">DNS</dt>
                  <dd>{{ pendingAppAction.plan.routePreview.dns }}</dd>
                  <dt class="font-semibold text-[var(--mn-ink-soft)]">{{ t('生效') }}</dt>
                  <dd>{{ pendingAppAction.plan.routePreview.activation }}</dd>
                </dl>
              </div>
            </ConfirmPanel>
          </div>
        </div>
      </Transition>
    </Teleport>

    <Card class="grid gap-3">
      <div class="flex flex-wrap items-center gap-3">
        <div class="mn-segmented">
          <button class="min-h-12 whitespace-nowrap rounded px-3 text-sm font-medium text-[var(--mn-ink-muted)] transition-colors disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('mode-blacklist') || state.appPolicy.mode === 'blacklist'" :class="{ 'bg-[var(--mn-cactus)] text-[var(--mn-on-accent)]': state.appPolicy.mode === 'blacklist' }" @click="requestSetMode('blacklist')">{{ t('全局接管') }}</button>
          <button class="min-h-12 whitespace-nowrap rounded px-3 text-sm font-medium text-[var(--mn-ink-muted)] transition-colors disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('mode-whitelist') || state.appPolicy.mode === 'whitelist'" :class="{ 'bg-[var(--mn-cactus)] text-[var(--mn-on-accent)]': state.appPolicy.mode === 'whitelist' }" @click="requestSetMode('whitelist')">{{ t('仅名单接管') }}</button>
        </div>
        <span class="text-sm text-[var(--mn-ink-muted)]">
          {{ state.appPolicy.mode === 'whitelist'
            ? t('仅接管名单中的应用。')
            : t('接管全部应用，绕过名单除外。') }}
        </span>
      </div>
      <p class="text-xs leading-5 text-[var(--mn-ink-faint)]">{{ t('同一 Android UID 的应用会一起生效。') }}</p>
      <AppPolicyRouteGuide
        :mode="state.appPolicy.mode"
        :reapply-loading="isRunning('reapply-app-policy')"
        @reapply="requestReapplyAppPolicy"
      />
      <p v-if="policySummary.conflicts.length" role="alert" class="text-sm text-[var(--mn-danger)]">
        {{ t('{count} 个名单冲突，请检查下方分流概览。', { count: policySummary.conflicts.length }) }}
      </p>
    </Card>

    <div class="grid gap-3 lg:grid-cols-[minmax(0,1.25fr)_minmax(280px,0.75fr)]">
      <Card class="grid gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <SearchField v-model="state.packageQuery" :placeholder="t('搜索已安装应用包名')" @keyup.enter="searchPackages" />
          <Button variant="secondary" :loading="isRunning('search-packages')" @click="searchPackages">{{ t('重新读取') }}</Button>
        </div>
        <div v-if="selectedPackages.length" class="flex min-w-0 flex-wrap items-center gap-2">
          <Button variant="outline" size="sm" :disabled="!visiblePackageNames.length" @click="selectVisiblePackages">
            <CheckCheck :size="15" />{{ allVisibleSelected ? t('取消可见项') : t('选择可见项') }}
          </Button>
          <span class="mr-auto text-xs text-[var(--mn-ink-muted)]">{{ t('已选 {count} 个', { count: selectedPackages.length }) }}</span>
          <Button size="sm" variant="secondary" :disabled="!selectedPackages.length" :loading="isRunning('batch-proxy')" @click="requestBatchAdd('proxy')">{{ t('代理') }}</Button>
          <Button size="sm" variant="secondary" :disabled="!selectedPackages.length" :loading="isRunning('batch-direct')" @click="requestBatchAdd('direct')">{{ t('直连') }}</Button>
          <Button size="sm" variant="secondary" :disabled="!selectedPackages.length" :loading="isRunning('batch-bypass')" @click="requestBatchAdd('bypass')">{{ t('绕过') }}</Button>
          <Button v-if="selectedPackages.length" size="icon" variant="outline" :aria-label="t('清除已选应用')" :title="t('清除已选应用')" @click="selectedPackages = []"><X :size="15" /></Button>
        </div>
        <div class="grid gap-2 sm:max-h-[32rem] sm:overflow-auto">
          <div v-for="app in filteredPackages" :key="app.packageName" class="grid grid-cols-3 gap-2 border-b border-[var(--mn-border)] py-3 sm:grid-cols-[minmax(0,1fr)_auto_auto_auto] sm:items-center">
            <label class="col-span-3 flex min-h-12 min-w-0 cursor-pointer items-center gap-2 sm:col-span-1">
              <input
                type="checkbox"
                class="size-4 shrink-0 accent-[var(--mn-cactus)]"
                :checked="selectedPackages.includes(app.packageName)"
                :aria-label="t('选择 {value}', { value: app.packageName })"
                @change="togglePackageSelection(app.packageName)"
              >
              <span class="min-w-0 break-all text-sm text-[var(--mn-ink-soft)]">{{ app.packageName }}</span>
            </label>
            <Button size="sm" variant="outline" :loading="isRunning(`pick-proxy-${app.packageName}`)" @click="requestAddPackage(app.packageName, 'proxy', `pick-proxy-${app.packageName}`)">{{ t('代理') }}</Button>
            <Button size="sm" variant="outline" :loading="isRunning(`pick-direct-${app.packageName}`)" @click="requestAddPackage(app.packageName, 'direct', `pick-direct-${app.packageName}`)">{{ t('直连') }}</Button>
            <Button size="sm" variant="outline" :loading="isRunning(`pick-bypass-${app.packageName}`)" @click="requestAddPackage(app.packageName, 'bypass', `pick-bypass-${app.packageName}`)">{{ t('绕过') }}</Button>
          </div>
          <em v-if="!filteredPackages.length" class="mn-empty">{{ state.packageQuery.trim() ? t('没有匹配的应用。') : t('暂无应用，点“刷新应用”读取。') }}</em>
        </div>
      </Card>

      <details class="mn-disclosure">
        <summary>{{ t('推荐绕过') }}</summary>
      <Card class="grid gap-3">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h3 class="text-base font-medium">{{ t('推荐绕过') }}</h3>
            <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">{{ t('这些应用建议使用系统网络。') }}</p>
          </div>
          <CheckCircle2 class="shrink-0 text-[var(--mn-ink-muted)]" :size="18" />
        </div>
        <div class="flex max-h-64 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in availableRecommendedBypass" :key="pkg" class="mn-tag text-[var(--mn-ink-soft)]">{{ pkg }}</span>
          <em v-if="!availableRecommendedBypass.length" class="mn-empty">{{ t('推荐项已在名单中，或当前设备未读取到匹配应用。') }}</em>
        </div>
      </Card>
      </details>
    </div>

    <details class="mn-disclosure">
      <summary>{{ t('按包名添加') }}</summary>
      <div class="mn-disclosure__body">
        <Input v-model="state.packageInput" :aria-label="t('应用包名')" placeholder="com.android.chrome" spellcheck="false" autocapitalize="none" autocomplete="off" />
        <p class="text-xs leading-5 text-[var(--mn-ink-muted)]">{{ t('直连仍经过 MagicNet，绕过使用系统网络。') }}</p>
        <div class="grid grid-cols-3 gap-2">
          <Button variant="secondary" :loading="isRunning('add-proxy')" @click="addApp('proxy')"><Plus :size="16" />{{ t('代理') }}</Button>
          <Button variant="secondary" :loading="isRunning('add-direct')" @click="addApp('direct')">{{ t('直连') }}</Button>
          <Button variant="secondary" :loading="isRunning('add-bypass')" @click="addApp('bypass')">{{ t('绕过') }}</Button>
        </div>
      </div>
    </details>

    <details class="mn-disclosure" :open="policySummary.conflicts.length > 0">
      <summary>{{ t('分流概览') }}<span v-if="policySummary.conflicts.length">{{ t('需要检查') }}</span></summary>
      <Card class="grid gap-3">
        <p class="text-sm leading-6 text-[var(--mn-ink-muted)]">{{ policySummary.summary }}</p>
        <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-6">
          <InsightChip v-for="item in policySummary.items" :key="item.label" :label="item.label" :value="item.value" :tone="item.tone" />
        </div>
        <p v-if="policySummary.conflicts.length" class="break-all text-xs text-[var(--mn-danger)]">
          {{ t('冲突包名：') }}{{ policySummary.conflicts.join(", ") }}
        </p>
      </Card>
    </details>

    <div class="grid gap-3 md:grid-cols-3">
      <Card>
        <h3 class="mb-2 text-base font-medium">{{ t('代理名单') }}</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <RemovableTag
            v-for="pkg in state.appPolicy.proxy"
            :key="pkg"
            :disabled="isRunning(`remove-proxy-${pkg}`)"
            :title="t('移除')"
            @remove="requestRemoveApp(pkg, 'proxy')"
          >{{ pkg }}</RemovableTag>
          <em v-if="!state.appPolicy.proxy.length" class="mn-empty">{{ t('暂无应用') }}</em>
        </div>
      </Card>
      <Card>
        <h3 class="mb-2 text-base font-medium">{{ t('MagicNet 内直连') }}</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <RemovableTag
            v-for="pkg in state.appPolicy.direct"
            :key="pkg"
            :disabled="isRunning(`remove-direct-${pkg}`)"
            :title="t('移除')"
            @remove="requestRemoveApp(pkg, 'direct')"
          >{{ pkg }}</RemovableTag>
          <em v-if="!state.appPolicy.direct.length" class="mn-empty">{{ t('暂无应用') }}</em>
        </div>
      </Card>
      <Card>
        <h3 class="mb-2 text-base font-medium">{{ t('绕过名单') }}</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <RemovableTag
            v-for="pkg in state.appPolicy.bypass"
            :key="pkg"
            :disabled="isRunning(`remove-bypass-${pkg}`)"
            :title="t('移入回收站')"
            @remove="requestRemoveApp(pkg, 'bypass')"
          >{{ pkg }}</RemovableTag>
          <em v-if="!state.appPolicy.bypass.length" class="mn-empty">{{ t('暂无应用') }}</em>
        </div>
      </Card>
    </div>

    <Card class="grid gap-3 border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)]/80 bg-[var(--mn-ivory)]/65">
      <div class="flex items-center justify-between gap-3">
        <div>
          <h3 class="text-base font-semibold">{{ t('Bypass 回收站') }}</h3>
          <p class="mt-1 text-sm text-[var(--mn-ink-muted)]">{{ t('从 Bypass 点 X 移除的应用会暂存在这里，可以直接加回名单。') }}</p>
        </div>
        <Trash2 class="shrink-0 text-[var(--mn-ink-muted)]" :size="18" />
      </div>
      <div class="flex max-h-56 flex-wrap gap-2 overflow-auto">
        <RemovableTag
          v-for="pkg in recycledBypass"
          :key="pkg"
          variant="dashed"
          remove-variant="restore"
          :disabled="isRunning(`restore-bypass-${pkg}`)"
          :title="t('加回 Bypass')"
          @remove="requestRestoreBypass(pkg)"
        >
          {{ pkg }}
          <template #icon><RotateCcw :size="14" /></template>
        </RemovableTag>
        <em v-if="!recycledBypass.length" class="mn-empty">{{ t('回收站为空') }}</em>
      </div>
    </Card>
  </div>
</template>
