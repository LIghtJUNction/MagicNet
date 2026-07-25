<script setup lang="ts">
import {
  Activity,
  Ban,
  Bug,
  DownloadCloud,
  MonitorCog,
  Gauge,
  Github,
  ListFilter,
  MessageCircle,
  Medal,
  MoreHorizontal,
  ScrollText,
  Settings,
  Stethoscope,
  Terminal,
  X,
} from "lucide-vue-next";
import { computed, defineAsyncComponent, nextTick, onMounted, onUnmounted, ref, type Component } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import { useMagicNet } from "@/composables/useMagicNet";

type TabKey = "control" | "config" | "apps" | "block" | "subs" | "rank" | "tools" | "health" | "webui" | "output";

const pageLoaders: Record<TabKey, () => Promise<{ default: Component }>> = {
  control: () => import("@/components/pages/ControlPage.vue"),
  config: () => import("@/components/pages/ConfigPage.vue"),
  apps: () => import("@/components/pages/AppsPage.vue"),
  block: () => import("@/components/pages/BlocklistPage.vue"),
  subs: () => import("@/components/pages/SubscriptionsPage.vue"),
  rank: () => import("@/components/pages/RankingPage.vue"),
  tools: () => import("@/components/pages/ToolsPage.vue"),
  webui: () => import("@/components/pages/WebuiPage.vue"),
  health: () => import("@/components/pages/DiagnosticsPage.vue"),
  output: () => import("@/components/pages/OutputPage.vue"),
};

/** Lazy page components — inactive tabs stay off the first-load critical path */
const asyncPages = Object.fromEntries(
  (Object.keys(pageLoaders) as TabKey[]).map((key) => [
    key,
    defineAsyncComponent({
      loader: pageLoaders[key],
      delay: 80,
      timeout: 20000,
    }),
  ]),
) as Record<TabKey, Component>;

const {
  state,
  statusTone,
  refreshAll,
  refreshStatus,
  refreshApps,
  refreshBlock,
  refreshSubs,
  refreshHealth,
  refreshMcp,
  refreshDns,
  refreshWarp,
  createIssue,
  openExternal,
  REPO,
  AUTHOR_WHISPER_URL,
} = useMagicNet();
const activeTab = ref<TabKey>("control");
const showAdvancedNav = ref(false);
const advancedDialog = ref<HTMLElement | null>(null);
const advancedNavTrigger = ref<HTMLElement | null>(null);
const easterEggVisitors = [
  {
    title: "准备好你的太阳镜 😎",
    body: "SOL 到此一游 · 光太亮，别直视内核。",
  },
  {
    title: "Grok 4.5 到此一游 ✨",
    body: "xAI 路过 MagicNet · 路由已嗅探，彩蛋已落盘。",
  },
  {
    title: "Kimi K3 到此一游 🌙",
    body: "月之暗面打卡成功 · 上下文很长，短签也行。",
  },
] as const;

const easterEggVisible = ref(false);
/** Index of the visitor currently shown (advances after each unlock). */
const easterEggShownIndex = ref(0);
/** Next visitor to show on the following unlock. */
let easterEggNextIndex = 0;
const easterEggPayload = computed(
  () => easterEggVisitors[easterEggShownIndex.value] ?? easterEggVisitors[0],
);
let brandClickCount = 0;
let brandClickWindowStartedAt = 0;
let easterEggTimer: number | undefined;
let bodyOverflowBeforeDialog = "";

const tabs = [
  { key: "control", label: "控制", icon: Gauge, group: "primary" },
  { key: "config", label: "配置", icon: Settings, group: "primary" },
  { key: "apps", label: "应用", icon: ListFilter, group: "primary" },
  { key: "block", label: "黑名单", icon: Ban, group: "primary" },
  { key: "health", label: "诊断", icon: Stethoscope, group: "primary" },
  { key: "subs", label: "订阅", icon: DownloadCloud, group: "advanced" },
  { key: "rank", label: "排行", icon: Medal, group: "advanced" },
  { key: "tools", label: "工具", icon: Stethoscope, group: "advanced" },
  { key: "webui", label: "面板", icon: MonitorCog, group: "advanced" },
  { key: "output", label: "输出", icon: Terminal, group: "advanced" },
] as const;

const primaryTabs = computed(() => tabs.filter((item) => item.group === "primary"));
const advancedTabs = computed(() => tabs.filter((item) => item.group === "advanced"));
const activeAdvancedTab = computed(() => advancedTabs.value.find((item) => item.key === activeTab.value));

const activeComponent = computed(() => asyncPages[activeTab.value]);

const statusMessage = computed(() => (state.task ? `正在执行：${state.task}` : state.notice || "等待操作"));

const statusDotClass = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "mn-status-dot-ok";
  if (state.runtime.singBoxState === "stopped") return "mn-status-dot-stop";
  return "mn-status-dot-unknown";
});

function setTab(tab: TabKey): void {
  activeTab.value = tab;
  if (showAdvancedNav.value) closeAdvancedNav();
  warmActiveTab(tab);
  void nextTick(() => {
    const target = Array.from(
      document.querySelectorAll<HTMLElement>(`[data-tab="${tab}"]`),
    ).find((item) => item.offsetParent !== null);
    target?.scrollIntoView({ block: "nearest", inline: "center" });
  });
}

async function openAdvancedNav(event: MouseEvent): Promise<void> {
  if (event.currentTarget instanceof HTMLElement) {
    advancedNavTrigger.value = event.currentTarget;
  }
  bodyOverflowBeforeDialog = document.body.style.overflow;
  document.body.style.overflow = "hidden";
  showAdvancedNav.value = true;
  await nextTick();
  const initial = advancedDialog.value?.querySelector<HTMLElement>("[data-dialog-initial-focus]");
  (initial || advancedDialog.value)?.focus();
}

function closeAdvancedNav(restoreFocus = true): void {
  if (!showAdvancedNav.value) return;
  showAdvancedNav.value = false;
  document.body.style.overflow = bodyOverflowBeforeDialog;
  const trigger = advancedNavTrigger.value;
  if (restoreFocus && trigger instanceof HTMLElement && typeof trigger.focus === "function") {
    void nextTick(() => {
      if (trigger instanceof HTMLElement && trigger.isConnected && typeof trigger.focus === "function") {
        trigger.focus();
      }
    });
  }
}

function trapAdvancedNavFocus(event: KeyboardEvent): void {
  if (!showAdvancedNav.value || event.key !== "Tab" || !advancedDialog.value) return;
  const focusable = Array.from(
    advancedDialog.value.querySelectorAll<HTMLElement>(
      'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    ),
  ).filter((element) => element.getClientRects().length > 0);
  if (!focusable.length) {
    event.preventDefault();
    advancedDialog.value.focus();
    return;
  }
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  const active = document.activeElement;
  if (event.shiftKey && (active === first || !advancedDialog.value.contains(active))) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (active === last || !advancedDialog.value.contains(active))) {
    event.preventDefault();
    first.focus();
  }
}

function closeEasterEgg(): void {
  easterEggVisible.value = false;
  if (easterEggTimer !== undefined) window.clearTimeout(easterEggTimer);
  easterEggTimer = undefined;
}

function handleBrandMarkClick(): void {
  const now = Date.now();
  if (now - brandClickWindowStartedAt > 2400) brandClickCount = 0;
  if (brandClickCount === 0) brandClickWindowStartedAt = now;
  brandClickCount += 1;
  if (brandClickCount < 5) return;

  brandClickCount = 0;
  // Rotate: SOL → Grok 4.5 → Kimi K3 → …
  easterEggShownIndex.value = easterEggNextIndex % easterEggVisitors.length;
  easterEggNextIndex = (easterEggShownIndex.value + 1) % easterEggVisitors.length;
  easterEggVisible.value = true;
  if (easterEggTimer !== undefined) window.clearTimeout(easterEggTimer);
  easterEggTimer = window.setTimeout(closeEasterEgg, 5200);
}

function handleEscape(event: KeyboardEvent): void {
  if (event.key === "Tab") {
    trapAdvancedNavFocus(event);
    return;
  }
  if (event.key !== "Escape") return;
  if (showAdvancedNav.value) {
    event.preventDefault();
    closeAdvancedNav();
    return;
  }
  closeEasterEgg();
}

function warmActiveTab(tab: TabKey): void {
  if (tab === "apps") void refreshApps(true);
  if (tab === "block") void refreshBlock(true);
  if (tab === "subs") void refreshSubs(true);
  if (tab === "health") {
    void refreshMcp(true);
    void refreshHealth(true);
  }
  if (tab === "tools") {
    void refreshDns(true);
    void refreshWarp(true);
    void refreshMcp(true);
  }
}

onMounted(() => {
  void refreshStatus();
  document.addEventListener("keydown", handleEscape);
  void pageLoaders.control();
});

onUnmounted(() => {
  document.removeEventListener("keydown", handleEscape);
  if (easterEggTimer !== undefined) window.clearTimeout(easterEggTimer);
  if (showAdvancedNav.value) document.body.style.overflow = bodyOverflowBeforeDialog;
});
</script>

<template>
  <div class="mn-shell relative mx-auto min-h-dvh w-full max-w-[1500px] px-3 pb-[calc(7rem+env(safe-area-inset-bottom))] pt-3 sm:px-5 md:px-7 md:pb-12 md:pt-6">
    <header class="mb-5 flex flex-nowrap items-center justify-between gap-1 md:mb-7">
      <div class="mn-chrome flex min-w-0 items-center gap-1 rounded-md p-0.5 pr-1.5">
        <button
          class="brand-mark mn-brand-mark grid size-11 shrink-0 place-items-center overflow-hidden rounded-[5px] transition-[transform,opacity] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))] active:scale-[0.94]"
          type="button"
          aria-label="MagicNet 品牌标记"
          title="MagicNet"
          @click="handleBrandMarkClick"
        >
          <img
            src="/magicnet-network-card.svg"
            alt=""
            width="44"
            height="44"
            class="size-11 object-cover"
            decoding="async"
          />
        </button>
        <div class="hidden min-w-0 min-[360px]:block pl-1">
          <h1 class="truncate text-[17px] font-semibold leading-tight tracking-[-0.03em] text-[var(--mn-ink)] sm:text-xl">MagicNet</h1>
          <p class="hidden truncate text-[11px] text-[var(--mn-ink-faint)] sm:block">Root network workspace</p>
        </div>
      </div>

      <div class="mn-chrome flex items-center gap-0.5 rounded-md p-0.5">
        <Button
          size="sm"
          class="size-11 px-0 sm:w-auto sm:px-4"
          :loading="state.task === '创建 GitHub issue'"
          aria-label="创建 GitHub Issue"
          title="Create GitHub Issue"
          @click="createIssue"
        >
          <Bug :size="16" /><span class="hidden sm:inline">Create Issue</span>
        </Button>
        <Button
          variant="ghost"
          size="sm"
          class="size-11 px-0 sm:w-auto sm:px-4"
          :loading="state.task === '刷新面板'"
          aria-label="刷新面板"
          title="刷新面板"
          @click="refreshAll"
        >
          <Activity :size="16" /><span class="hidden sm:inline">刷新</span>
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="size-11 px-0 sm:w-auto sm:px-4"
          aria-label="打开悄悄话"
          title="打开悄悄话"
          @click="openExternal(AUTHOR_WHISPER_URL, '悄悄话')"
        >
          <MessageCircle :size="16" /><span class="hidden sm:inline">悄悄话</span>
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="size-11 px-0 sm:w-auto sm:px-4"
          aria-label="打开 GitHub"
          title="打开 GitHub"
          @click="openExternal(REPO, 'GitHub')"
        >
          <Github :size="16" /><span class="hidden sm:inline">GitHub</span>
        </Button>
      </div>
    </header>

    <section class="runtime-cockpit mn-chrome relative z-20 mb-5 grid gap-3 rounded-md p-1 md:sticky md:top-4 md:grid-cols-[minmax(220px,1.05fr)_minmax(0,1fr)_auto] md:items-center md:gap-2">
      <div class="rounded-[5px] bg-[color-mix(in_srgb,var(--mn-cactus)_28%,var(--mn-carrier))] px-4 py-3 shadow-[inset_0_0_0_1px_color-mix(in_srgb,var(--mn-cactus)_45%,transparent)]">
        <div class="flex items-center justify-between gap-3">
          <div class="min-w-0 flex-1">
            <span class="text-[9px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-faint)]">Runtime status</span>
            <div class="mt-1.5 flex min-w-0 items-center gap-2.5">
              <span :class="['size-2.5 shrink-0 rounded-full', statusDotClass]" />
              <strong class="w-0 min-w-0 flex-1 truncate text-lg font-semibold tracking-[-0.03em] text-[var(--mn-ink)]">
                {{ state.runtime.singBoxState === "sing-box" ? "sing-box online" : state.runtime.singBoxState === "unknown" ? "状态未知" : state.runtime.singBoxState }}
              </strong>
            </div>
          </div>
          <Badge :tone="statusTone">{{ state.runtime.singBoxState }}</Badge>
        </div>
      </div>

      <div class="grid min-w-0 grid-cols-2 gap-2 px-2 pb-2 md:px-3 md:pb-0">
        <div class="min-w-0">
          <span class="text-[9px] font-semibold uppercase tracking-[0.2em] text-[var(--mn-ink-faint)]">Mode</span>
          <code class="mn-code mt-1 block truncate text-xs md:text-sm">{{ state.runtime.transparentMode }}</code>
        </div>
        <div class="min-w-0">
          <span class="text-[9px] font-semibold uppercase tracking-[0.2em] text-[var(--mn-ink-faint)]">Core</span>
          <code class="mn-code mt-1 block truncate text-xs md:text-sm">{{ state.runtime.singBox }}</code>
        </div>
        <div class="col-span-2 flex min-w-0 items-center gap-2 text-xs leading-5 text-[var(--mn-ink-muted)] md:text-sm">
          <ScrollText class="shrink-0 text-[var(--mn-clay)]" :size="14" />
          <span class="min-w-0 truncate" :title="statusMessage">{{ statusMessage }}</span>
        </div>
      </div>

      <Button
        v-if="state.backgroundTask.log"
        variant="outline"
        size="sm"
        class="mx-2 mb-2 md:mx-1 md:mb-0"
        @click="setTab('output')"
      >
        <Terminal :size="15" />后台日志
      </Button>
    </section>

    <main class="grid min-w-0 gap-5 md:grid-cols-[190px_minmax(0,1fr)] md:items-start md:gap-6">
      <nav class="desktop-rail mn-chrome sticky top-36 hidden gap-1 rounded-md p-1.5 md:grid" aria-label="MagicNet 页面">
        <div class="px-3 pb-1 pt-2 text-[9px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-faint)]">常用工作区</div>
        <button
          v-for="item in primaryTabs"
          :key="item.key"
          :data-tab="item.key"
          :class="[
            'flex min-h-11 min-w-0 items-center gap-3 rounded-[5px] px-3 text-sm font-medium transition-[transform,color,background-color,opacity] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))] active:scale-[0.98]',
            activeTab === item.key ? 'mn-nav-active' : 'mn-nav-idle',
          ]"
          @click="setTab(item.key)"
        >
          <component :is="item.icon" :size="18" />
          <span>{{ item.label }}</span>
        </button>

        <div class="mt-3 px-3 pb-1 text-[9px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-faint)]">进阶工具</div>
        <button
          v-for="item in advancedTabs"
          :key="item.key"
          :data-tab="item.key"
          :class="[
            'flex min-h-11 min-w-0 items-center gap-3 rounded-[5px] px-3 text-sm font-medium transition-[transform,color,background-color,opacity] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))] active:scale-[0.98]',
            activeTab === item.key ? 'mn-nav-advanced-active' : 'mn-nav-idle',
          ]"
          @click="setTab(item.key)"
        >
          <component :is="item.icon" :size="18" />
          <span>{{ item.label }}</span>
        </button>
      </nav>

      <!-- No :key remount + no page-enter animation on every tab switch -->
      <section class="page-surface min-w-0 overflow-hidden">
        <Suspense>
          <component :is="activeComponent" @goto-output="setTab('output')" />
          <template #fallback>
            <div class="mn-chrome rounded-md p-8 text-sm text-[var(--mn-ink-muted)]">加载面板…</div>
          </template>
        </Suspense>
      </section>
    </main>

    <nav class="mobile-nav mn-chrome fixed inset-x-3 bottom-[max(0.75rem,env(safe-area-inset-bottom))] z-30 grid grid-cols-6 gap-1 rounded-md p-1 md:hidden" aria-label="MagicNet 移动导航">
      <button
        v-for="item in primaryTabs"
        :key="item.key"
        :data-tab="item.key"
        :class="[
          'flex min-h-11 min-w-0 flex-col items-center justify-center gap-0.5 rounded-[5px] px-1 text-[10px] font-medium transition-[transform,color,background-color,opacity] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))] active:scale-[0.95]',
          activeTab === item.key ? 'mn-nav-active' : 'mn-nav-idle',
        ]"
        @click="setTab(item.key)"
      >
        <component :is="item.icon" :size="18" />
        <span>{{ item.label }}</span>
      </button>
      <button
        ref="advancedNavTrigger"
        :class="[
          'flex min-h-11 min-w-0 flex-col items-center justify-center gap-0.5 rounded-[5px] px-1 text-[10px] font-medium transition-[transform,color,background-color,opacity] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))] active:scale-[0.95]',
          activeAdvancedTab ? 'mn-nav-advanced-active' : 'mn-nav-idle',
        ]"
        aria-haspopup="dialog"
        :aria-expanded="showAdvancedNav"
        @click="openAdvancedNav"
      >
        <component :is="activeAdvancedTab?.icon || MoreHorizontal" :size="18" />
        <span>{{ activeAdvancedTab?.label || "更多" }}</span>
      </button>
    </nav>

    <Transition name="sheet">
      <div v-if="showAdvancedNav" class="fixed inset-0 z-40 md:hidden">
        <button class="absolute inset-0 size-full bg-[color-mix(in_srgb,var(--mn-ink)_35%,transparent)]" type="button" aria-label="关闭进阶导航" @click="closeAdvancedNav()" />
        <div ref="advancedDialog" class="mn-chrome absolute inset-x-3 bottom-[max(0.75rem,env(safe-area-inset-bottom))] rounded-md p-1.5 pb-2" role="dialog" aria-modal="true" aria-label="进阶导航" tabindex="-1">
          <div class="flex items-center justify-between px-3 pb-2 pt-2">
            <div>
              <span class="text-[9px] font-semibold uppercase tracking-[0.22em] text-[var(--mn-ink-faint)]">Advanced workspace</span>
              <h2 class="mt-1 text-lg font-semibold tracking-[-0.03em] text-[var(--mn-ink)]">进阶工具</h2>
            </div>
            <Button data-dialog-initial-focus variant="ghost" size="icon" aria-label="关闭进阶导航" @click="closeAdvancedNav()"><X :size="18" /></Button>
          </div>
          <div class="grid grid-cols-2 gap-1.5">
            <button
              v-for="item in advancedTabs"
              :key="item.key"
              :data-tab="item.key"
              :class="[
                'flex min-h-11 min-w-0 items-center gap-3 rounded-[5px] px-4 text-sm font-medium transition-[transform,color,background-color,opacity] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-heather)_70%,var(--mn-ink))] active:scale-[0.97]',
                activeTab === item.key ? 'mn-nav-active' : 'mn-inset-soft text-[var(--mn-ink-soft)]',
              ]"
              @click="setTab(item.key)"
            >
              <component :is="item.icon" :size="19" />
              <span>{{ item.label }}</span>
            </button>
          </div>
        </div>
      </div>
    </Transition>

    <Transition name="toast">
      <aside v-if="easterEggVisible" class="mn-chrome fixed bottom-28 right-3 z-50 max-w-[calc(100vw-1.5rem)] rounded-md p-1 md:bottom-8 md:right-8 md:max-w-sm" role="status" aria-live="polite">
        <div class="flex items-start gap-3 rounded-[5px] bg-[color-mix(in_srgb,var(--mn-cactus)_18%,var(--mn-carrier))] p-4">
          <div class="grid size-10 shrink-0 place-items-center overflow-hidden rounded-sm bg-[var(--mn-cactus)]">
            <img src="/magicnet-network-card.svg" alt="" class="size-10 object-cover" width="40" height="40" decoding="async" />
          </div>
          <div class="min-w-0 flex-1">
            <strong class="text-sm font-semibold text-[var(--mn-ink)]">{{ easterEggPayload.title }}</strong>
            <p class="mt-1 text-xs leading-5 text-[var(--mn-ink-muted)]">{{ easterEggPayload.body }}</p>
            <p class="mt-2 text-[10px] uppercase tracking-[0.16em] text-[var(--mn-ink-faint)]">
              visitors · SOL · Grok 4.5 · Kimi K3
            </p>
          </div>
          <button class="grid size-11 shrink-0 place-items-center rounded-[5px] text-[var(--mn-ink-faint)] transition-[transform,color,background-color,opacity] duration-200 ease-[cubic-bezier(0.22,1,0.36,1)] hover:bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] hover:text-[var(--mn-ink)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color-mix(in_srgb,var(--mn-cactus)_70%,var(--mn-ink))] active:scale-[0.94]" type="button" aria-label="关闭彩蛋" @click="closeEasterEgg">
            <X :size="16" />
          </button>
        </div>
      </aside>
    </Transition>
  </div>
</template>
