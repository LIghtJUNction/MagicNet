<script setup lang="ts">
import { CheckCircle2, Copy, ListFilter, Plus, RefreshCw, RotateCcw, Search, ShieldCheck, Trash2, X } from "lucide-vue-next";
import { computed, onMounted, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import { buildAppPolicySummary, formatAppPolicyFullReport, formatAppPolicySafeReport, isValidPackageName, recommendedBypass } from "./appPolicyInsights";
import { buildAppPolicyChangePlan, type AppPolicyChangeOperation, type AppPolicyChangePlan } from "./appPolicyChangePlan";

const { state, runCli, refreshApps, refreshPackages, shellQuote } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const removedBypass = ref<string[]>([]);
const pendingAppAction = ref<PendingAppAction | null>(null);
const appReportCopied = ref(false);
const safeReportCopied = ref(false);

type PendingAppAction = {
  key: string;
  command: string;
  message: string;
  plan: AppPolicyChangePlan;
  run: () => Promise<void>;
};

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

const availableRecommendedBypass = computed(() => {
  const active = new Set([...state.appPolicy.proxy, ...state.appPolicy.bypass]);
  const installed = installedNames.value;
  return recommendedBypass.filter((pkg) => {
    if (active.has(pkg)) return false;
    return installed.size === 0 || installed.has(pkg);
  });
});

const policySummary = computed(() => buildAppPolicySummary(
  state.appPolicy.mode,
  state.appPolicy.proxy,
  state.appPolicy.bypass,
  installedNames.value,
  availableRecommendedBypass.value.length
));

function actionPlan(operation: AppPolicyChangeOperation): AppPolicyChangePlan {
  return buildAppPolicyChangePlan({
    mode: state.appPolicy.mode,
    proxy: state.appPolicy.proxy,
    bypass: state.appPolicy.bypass,
    installedPackages: installedNames.value
  }, operation);
}

function commandFailed(text: string): boolean {
  return /\b(error|failed|fail|Usage:|not found)\b/i.test(text);
}

function rememberRemovedBypass(pkg: string): void {
  removedBypass.value = [pkg, ...removedBypass.value.filter((item) => item !== pkg)].slice(0, 24);
}

function forgetRemovedBypass(pkg: string): void {
  removedBypass.value = removedBypass.value.filter((item) => item !== pkg);
}

function validateAppPackage(pkg: string, target: "proxy" | "bypass"): boolean {
  if (!isValidPackageName(pkg)) {
    state.output = "包名格式不对。示例：com.android.chrome";
    return false;
  }
  const list = target === "proxy" ? state.appPolicy.proxy : state.appPolicy.bypass;
  if (list.includes(pkg)) {
    state.output = `${pkg} 已存在，已自动去重。`;
    state.packageInput = "";
    return false;
  }
  return true;
}

function addApp(target: "proxy" | "bypass"): void {
  requestAddPackage(state.packageInput.trim(), target, `add-${target}`);
}

async function addPackage(pkg: string, target: "proxy" | "bypass", key = `add-${target}`): Promise<void> {
  await withAction(key, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousBypass = [...state.appPolicy.bypass];
    const list = target === "proxy" ? state.appPolicy.proxy : state.appPolicy.bypass;
    if (target === "proxy") state.appPolicy.bypass = state.appPolicy.bypass.filter((item) => item !== pkg);
    else state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    list.push(pkg);
    state.packageInput = "";
    if (target === "bypass") forgetRemovedBypass(pkg);
    state.output = `已加入界面，正在保存 ${pkg}...`;
    const text = await runCli(`app add ${shellQuote(pkg)} ${target}`, `添加应用 ${pkg}`, true);
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    await refreshApps(true);
  });
}

function requestAddPackage(pkg: string, target: "proxy" | "bypass", key = `add-${target}`): void {
  if (!validateAppPackage(pkg, target)) return;
  pendingAppAction.value = {
    key,
    command: `app add ${pkg} ${target}`,
    message: target === "proxy"
      ? `确认把 ${pkg} 加入 Proxy 名单？该应用将强制走 MagicNet proxy。`
      : `确认把 ${pkg} 加入 Bypass 名单？该应用将绕过 MagicNet TUN。`,
    plan: actionPlan({ type: "add", target, packages: [pkg] }),
    run: () => addPackage(pkg, target, key)
  };
}

async function removeApp(pkg: string, target: "proxy" | "bypass"): Promise<void> {
  await withAction(`remove-${target}-${pkg}`, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousBypass = [...state.appPolicy.bypass];
    if (target === "proxy") {
      state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    } else {
      state.appPolicy.bypass = state.appPolicy.bypass.filter((item) => item !== pkg);
      rememberRemovedBypass(pkg);
    }
    state.output = `已从界面移除 ${pkg}，正在后台保存...`;
    const text = await runCli(`app remove ${shellQuote(pkg)} ${target}`, `移除应用 ${pkg}`, true);
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    await refreshApps(true);
  });
}

async function restoreBypass(pkg: string): Promise<void> {
  await withAction(`restore-bypass-${pkg}`, async () => {
    const previousProxy = [...state.appPolicy.proxy];
    const previousBypass = [...state.appPolicy.bypass];
    if (!state.appPolicy.bypass.includes(pkg)) state.appPolicy.bypass.push(pkg);
    state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
    state.output = `正在把 ${pkg} 加回 Bypass...`;
    const text = await runCli(`app add ${shellQuote(pkg)} bypass`, `恢复 Bypass 应用 ${pkg}`, true);
    if (commandFailed(text)) {
      state.output = text;
      state.appPolicy.proxy = previousProxy;
      state.appPolicy.bypass = previousBypass;
      return;
    }
    await refreshApps(true);
    forgetRemovedBypass(pkg);
  });
}

async function setMode(mode: "blacklist" | "whitelist"): Promise<void> {
  await withAction(`mode-${mode}`, async () => {
    await runCli(`app mode ${mode}`, mode === "blacklist" ? "切换黑名单模式" : "切换白名单模式");
    await refreshApps(true);
  });
}

function requestSetMode(mode: "blacklist" | "whitelist"): void {
  pendingAppAction.value = {
    key: `mode-${mode}`,
    command: `app mode ${mode}`,
    message: mode === "blacklist" ? "确认切换到黑名单模式？未列出应用将正常进入 TUN。" : "确认切换到白名单模式？未列出应用将绕过 TUN。",
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
    bypass: state.appPolicy.bypass,
    summary: policySummary.value
  }));
  state.output = appReportCopied.value ? "应用策略完整快照已复制。" : "剪贴板不可用，应用策略快照未复制。";
}

async function copyAppPolicySafeReport(): Promise<void> {
  safeReportCopied.value = await copyText(formatAppPolicySafeReport({
    mode: state.appPolicy.mode,
    proxy: state.appPolicy.proxy,
    bypass: state.appPolicy.bypass,
    summary: policySummary.value
  }));
  state.output = safeReportCopied.value ? "应用策略隐私摘要已复制。" : "剪贴板不可用，应用策略摘要未复制。";
}

async function applyRecommendedBypass(): Promise<void> {
  await withAction("apply-recommended-bypass", async () => {
    const packages = availableRecommendedBypass.value;
    if (!packages.length) {
      state.output = "没有可加入的推荐 Bypass 应用。";
      return;
    }
    packages.forEach((pkg) => {
      if (!state.appPolicy.bypass.includes(pkg)) state.appPolicy.bypass.push(pkg);
      state.appPolicy.proxy = state.appPolicy.proxy.filter((item) => item !== pkg);
      forgetRemovedBypass(pkg);
    });
    const quoted = packages.map((pkg) => shellQuote(pkg)).join(" ");
    const text = await runCli(`app add-many bypass ${quoted}`, `应用推荐 Bypass 名单`);
    if (commandFailed(text)) {
      state.output = text;
      await refreshApps(true);
      return;
    }
    await refreshApps(true);
  });
}

function requestRecommendedBypass(): void {
  const count = availableRecommendedBypass.value.length;
  pendingAppAction.value = {
    key: "apply-recommended-bypass",
    command: `app add-many bypass (${count} packages)`,
    message: `确认把 ${count} 个推荐应用加入 Bypass？这会批量改写应用策略。`,
    plan: actionPlan({ type: "add", target: "bypass", packages: availableRecommendedBypass.value }),
    run: applyRecommendedBypass
  };
}

function requestRemoveApp(pkg: string, target: "proxy" | "bypass"): void {
  pendingAppAction.value = {
    key: `remove-${target}-${pkg}`,
    command: `app remove ${pkg} ${target}`,
    message: `确认从 ${target} 名单移除 ${pkg}？`,
    plan: actionPlan({ type: "remove", target, packages: [pkg] }),
    run: () => removeApp(pkg, target)
  };
}

function requestRestoreBypass(pkg: string): void {
  pendingAppAction.value = {
    key: `restore-bypass-${pkg}`,
    command: `app add ${pkg} bypass`,
    message: `确认把 ${pkg} 加回 Bypass 名单？`,
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
  pendingAppAction.value = null;
  try {
    await action.run();
  } finally {
    if (pendingAppAction.value?.key === action.key) pendingAppAction.value = null;
  }
}

onMounted(() => {
  if (!state.packages.length) void refreshPackages(true);
});
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Per App Policy" title="应用名单" description="Proxy 强制应用走 MagicNet proxy；Bypass 让应用绕过 TUN；模式控制未列出应用是否进入 TUN。">
      <div class="flex flex-wrap gap-2">
        <Button variant="outline" :loading="isRunning('refresh-apps')" @click="withAction('refresh-apps', () => refreshApps())"><RefreshCw :size="17" />读取名单</Button>
        <Button variant="outline" :loading="isRunning('search-packages')" @click="searchPackages"><ListFilter :size="17" />重新读取应用</Button>
        <Button variant="outline" :loading="isRunning('copy-app-policy-report')" @click="withAction('copy-app-policy-report', copyAppPolicyReport)"><Copy :size="17" />{{ appReportCopied ? '已复制快照' : '复制完整快照' }}</Button>
        <Button variant="outline" :loading="isRunning('copy-app-policy-safe-report')" @click="withAction('copy-app-policy-safe-report', copyAppPolicySafeReport)"><Copy :size="17" />{{ safeReportCopied ? '已复制摘要' : '复制隐私摘要' }}</Button>
        <Button :loading="isRunning('apply-recommended-bypass')" :disabled="availableRecommendedBypass.length === 0" @click="requestRecommendedBypass"><ShieldCheck :size="17" />应用推荐名单</Button>
      </div>
    </PageHeader>

    <Card v-if="pendingAppAction" class="grid gap-3 border border-amber-500/40 bg-[color-mix(in_srgb,var(--mn-oat)_55%,white)]">
      <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div class="min-w-0">
          <span class="text-[11px] font-bold uppercase tracking-wide text-[var(--mn-warning)]">Confirm app policy</span>
          <p class="mt-1 text-sm leading-6 text-[var(--mn-warning)]">{{ pendingAppAction.message }}</p>
          <code class="mt-2 block break-all rounded-md bg-[var(--mn-ivory)]/60 px-3 py-2 text-xs text-[var(--mn-ink)]">{{ pendingAppAction.command }}</code>
          <div class="mt-3 grid gap-2 text-xs sm:grid-cols-2 lg:grid-cols-5">
            <span
              v-for="item in pendingAppAction.plan.items"
              :key="item.label"
              class="rounded border px-2 py-1"
              :class="{
                'border-emerald-500/30 text-[var(--mn-success)]': item.tone === 'success',
                'border-amber-500/40 text-[var(--mn-warning)]': item.tone === 'warning',
                'border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] text-[var(--mn-danger)]': item.tone === 'danger',
                'border-zinc-700 text-[var(--mn-ink-soft)]': item.tone === 'neutral',
              }"
            >
              {{ item.label }}: <b class="font-medium">{{ item.value }}</b>
            </span>
          </div>
          <p v-if="pendingAppAction.plan.warnings.length" class="mt-2 text-xs leading-5 text-[var(--mn-warning)]/80">
            {{ pendingAppAction.plan.warnings.join("；") }}
          </p>
        </div>
        <div class="flex shrink-0 gap-2">
          <Button variant="secondary" :loading="isRunning(pendingAppAction.key)" @click="confirmAppAction">确认</Button>
          <Button variant="outline" @click="cancelAppAction">取消</Button>
        </div>
      </div>
    </Card>

    <Card class="grid gap-3">
      <div class="flex flex-wrap items-center gap-3">
        <div class="inline-flex w-fit rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-1">
          <button class="min-h-12 rounded px-3 text-sm text-[var(--mn-ink-muted)] disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('mode-blacklist') || state.appPolicy.mode === 'blacklist'" :class="{ 'bg-[var(--mn-cactus)] text-[var(--mn-ink)]': state.appPolicy.mode === 'blacklist' }" @click="requestSetMode('blacklist')">黑名单</button>
          <button class="min-h-12 rounded px-3 text-sm text-[var(--mn-ink-muted)] disabled:cursor-progress disabled:opacity-60" :disabled="isRunning('mode-whitelist') || state.appPolicy.mode === 'whitelist'" :class="{ 'bg-[var(--mn-cactus)] text-[var(--mn-ink)]': state.appPolicy.mode === 'whitelist' }" @click="requestSetMode('whitelist')">白名单</button>
        </div>
        <span class="text-sm text-[var(--mn-ink-muted)]">Proxy 始终强制走 MagicNet proxy；Bypass 始终绕过 TUN；黑/白名单模式只控制未列出应用。</span>
      </div>
      <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto_auto]">
        <Input v-model="state.packageInput" placeholder="com.android.chrome" spellcheck="false" />
        <Button variant="secondary" :loading="isRunning('add-proxy')" @click="addApp('proxy')"><Plus :size="16" />{{ isRunning('add-proxy') ? '保存中' : 'Proxy' }}</Button>
        <Button variant="secondary" :loading="isRunning('add-bypass')" @click="addApp('bypass')"><Plus :size="16" />{{ isRunning('add-bypass') ? '保存中' : 'Bypass' }}</Button>
      </div>
    </Card>

    <Card class="grid gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 class="text-base font-semibold">策略影响摘要</h3>
          <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">{{ policySummary.summary }}</p>
        </div>
        <span
          class="rounded px-2 py-1 text-xs font-medium"
          :class="policySummary.conflicts.length ? 'bg-[color-mix(in_srgb,var(--mn-coral)_55%,white)] text-[var(--mn-danger)]' : 'bg-[color-mix(in_srgb,var(--mn-cactus)_40%,white)] text-[var(--mn-success)]'"
        >
          {{ policySummary.conflicts.length ? `${policySummary.conflicts.length} 个冲突` : '无冲突' }}
        </span>
      </div>
      <div class="grid gap-2 text-xs sm:grid-cols-2 lg:grid-cols-6">
        <span
          v-for="item in policySummary.items"
          :key="item.label"
          class="rounded border px-2 py-1"
          :class="{
            'border-emerald-500/30 text-[var(--mn-success)]': item.tone === 'success',
            'border-amber-500/30 text-[var(--mn-warning)]': item.tone === 'warning',
            'border-[color-mix(in_srgb,var(--mn-coral)_70%,transparent)] text-[var(--mn-danger)]': item.tone === 'danger',
            'border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] text-[var(--mn-ink-muted)]': item.tone === 'neutral',
          }"
        >
          {{ item.label }}: <b class="font-medium">{{ item.value }}</b>
        </span>
      </div>
      <p v-if="policySummary.conflicts.length" class="break-all text-xs text-[var(--mn-danger)]">
        冲突包名：{{ policySummary.conflicts.join(", ") }}
      </p>
    </Card>

    <div class="grid gap-3 lg:grid-cols-[minmax(0,1.25fr)_minmax(280px,0.75fr)]">
      <Card class="grid gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <div class="relative min-w-0 flex-1">
            <Search class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--mn-ink-faint)]" :size="16" />
            <Input v-model="state.packageQuery" class="pl-9" placeholder="搜索已安装应用包名" spellcheck="false" @keyup.enter="searchPackages" />
          </div>
          <Button variant="secondary" :loading="isRunning('search-packages')" @click="searchPackages">重新读取</Button>
        </div>
        <div class="grid max-h-72 gap-2 overflow-auto">
          <div v-for="app in filteredPackages" :key="app.packageName" class="grid gap-2 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 py-2 sm:grid-cols-[minmax(0,1fr)_auto_auto] sm:items-center">
            <span class="min-w-0 break-all text-sm text-[var(--mn-ink-soft)]">{{ app.packageName }}</span>
            <Button size="sm" variant="outline" :loading="isRunning(`pick-proxy-${app.packageName}`)" @click="requestAddPackage(app.packageName, 'proxy', `pick-proxy-${app.packageName}`)">Proxy</Button>
            <Button size="sm" variant="outline" :loading="isRunning(`pick-bypass-${app.packageName}`)" @click="requestAddPackage(app.packageName, 'bypass', `pick-bypass-${app.packageName}`)">Bypass</Button>
          </div>
          <em v-if="!filteredPackages.length" class="text-sm not-italic text-[var(--mn-ink-muted)]">暂无结果，点“列出应用”或输入关键字过滤。</em>
        </div>
      </Card>

      <Card class="grid gap-3">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h3 class="text-base font-semibold">推荐 Bypass</h3>
            <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">支付、银行、运营商、常用国内服务优先绕过，减少验证码、风控和国内服务误伤。</p>
          </div>
          <CheckCircle2 class="shrink-0 text-[var(--mn-ink-muted)]" :size="18" />
        </div>
        <div class="flex max-h-64 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in availableRecommendedBypass" :key="pkg" class="inline-flex max-w-full items-center rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-2 py-1 text-xs text-[var(--mn-ink-soft)] break-all">{{ pkg }}</span>
          <em v-if="!availableRecommendedBypass.length" class="text-sm not-italic text-[var(--mn-ink-muted)]">推荐项已在名单中，或当前设备未读取到匹配应用。</em>
        </div>
      </Card>
    </div>

    <div class="grid gap-3 md:grid-cols-2">
      <Card>
        <h3 class="mb-2 text-base font-semibold">Proxy</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in state.appPolicy.proxy" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-2 py-1 text-xs break-all">
            {{ pkg }}
            <button class="grid size-6 place-items-center rounded-full bg-[var(--mn-cactus)] text-[var(--mn-ink)] disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-proxy-${pkg}`)" type="button" title="移除" @click="requestRemoveApp(pkg, 'proxy')"><X :size="14" /></button>
          </span>
          <em v-if="!state.appPolicy.proxy.length" class="text-sm not-italic text-[var(--mn-ink-muted)]">暂无应用</em>
        </div>
      </Card>
      <Card>
        <h3 class="mb-2 text-base font-semibold">Bypass</h3>
        <div class="flex max-h-80 flex-wrap gap-2 overflow-auto">
          <span v-for="pkg in state.appPolicy.bypass" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-2 py-1 text-xs break-all">
            {{ pkg }}
            <button class="grid size-6 place-items-center rounded-full bg-[var(--mn-cactus)] text-[var(--mn-ink)] disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`remove-bypass-${pkg}`)" type="button" title="移入回收站" @click="requestRemoveApp(pkg, 'bypass')"><X :size="14" /></button>
          </span>
          <em v-if="!state.appPolicy.bypass.length" class="text-sm not-italic text-[var(--mn-ink-muted)]">暂无应用</em>
        </div>
      </Card>
    </div>

    <Card class="grid gap-3 border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)]/80 bg-[var(--mn-ivory)]/65">
      <div class="flex items-center justify-between gap-3">
        <div>
          <h3 class="text-base font-semibold">Bypass 回收站</h3>
          <p class="mt-1 text-sm text-[var(--mn-ink-muted)]">从 Bypass 点 X 移除的应用会暂存在这里，可以直接加回名单。</p>
        </div>
        <Trash2 class="shrink-0 text-[var(--mn-ink-muted)]" :size="18" />
      </div>
      <div class="flex max-h-56 flex-wrap gap-2 overflow-auto">
        <span v-for="pkg in recycledBypass" :key="pkg" class="inline-flex max-w-full items-center gap-1 rounded-full border border-dashed border-zinc-700 bg-[var(--mn-ivory)] px-2 py-1 text-xs text-[var(--mn-ink-soft)] break-all">
          {{ pkg }}
          <button class="grid size-6 place-items-center rounded-full bg-[color-mix(in_srgb,var(--mn-cactus)_40%,white)] text-[var(--mn-success)] disabled:cursor-progress disabled:opacity-60" :disabled="isRunning(`restore-bypass-${pkg}`)" type="button" title="加回 Bypass" @click="requestRestoreBypass(pkg)">
            <RotateCcw :size="14" />
          </button>
        </span>
        <em v-if="!recycledBypass.length" class="text-sm not-italic text-[var(--mn-ink-muted)]">回收站为空</em>
      </div>
    </Card>
  </div>
</template>
