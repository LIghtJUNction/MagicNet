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
  Zap
} from "lucide-vue-next";
import { computed, nextTick, onMounted, onUnmounted, ref } from "vue";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import ControlPage from "@/components/pages/ControlPage.vue";
import ConfigPage from "@/components/pages/ConfigPage.vue";
import AppsPage from "@/components/pages/AppsPage.vue";
import BlocklistPage from "@/components/pages/BlocklistPage.vue";
import SubscriptionsPage from "@/components/pages/SubscriptionsPage.vue";
import DiagnosticsPage from "@/components/pages/DiagnosticsPage.vue";
import OutputPage from "@/components/pages/OutputPage.vue";
import ToolsPage from "@/components/pages/ToolsPage.vue";
import WebuiPage from "@/components/pages/WebuiPage.vue";
import RankingPage from "@/components/pages/RankingPage.vue";
import { useMagicNet } from "@/composables/useMagicNet";

type TabKey = "control" | "config" | "apps" | "block" | "subs" | "rank" | "tools" | "health" | "webui" | "output";

const { state, statusTone, refreshAll, refreshStatus, refreshApps, refreshBlock, refreshSubs, refreshHealth, refreshMcp, refreshDns, refreshWarp, createIssue, openExternal, REPO, AUTHOR_WHISPER_URL } = useMagicNet();
const activeTab = ref<TabKey>("control");
const showAdvancedNav = ref(false);
const easterEggVisible = ref(false);
let brandClickCount = 0;
let brandClickWindowStartedAt = 0;
let easterEggTimer: number | undefined;

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
  { key: "output", label: "输出", icon: Terminal, group: "advanced" }
] as const;

const primaryTabs = computed(() => tabs.filter((item) => item.group === "primary"));
const advancedTabs = computed(() => tabs.filter((item) => item.group === "advanced"));
const activeAdvancedTab = computed(() => advancedTabs.value.find((item) => item.key === activeTab.value));

const activeComponent = computed(() => ({
  control: ControlPage,
  config: ConfigPage,
  apps: AppsPage,
  block: BlocklistPage,
  subs: SubscriptionsPage,
  rank: RankingPage,
  tools: ToolsPage,
  webui: WebuiPage,
  health: DiagnosticsPage,
  output: OutputPage
}[activeTab.value]));

const statusMessage = computed(() => state.task ? `正在执行：${state.task}` : state.notice || "等待操作");

function setTab(tab: TabKey): void {
  activeTab.value = tab;
  showAdvancedNav.value = false;
  warmActiveTab(tab);
  void nextTick(() => {
    const target = Array.from(
      document.querySelectorAll<HTMLElement>(`[data-tab="${tab}"]`),
    ).find((item) => item.offsetParent !== null);
    target?.scrollIntoView({ block: "nearest", inline: "center" });
  });
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
  easterEggVisible.value = true;
  if (easterEggTimer !== undefined) window.clearTimeout(easterEggTimer);
  easterEggTimer = window.setTimeout(closeEasterEgg, 4600);
}

function handleEscape(event: KeyboardEvent): void {
  if (event.key !== "Escape") return;
  showAdvancedNav.value = false;
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
});

onUnmounted(() => {
  document.removeEventListener("keydown", handleEscape);
  if (easterEggTimer !== undefined) window.clearTimeout(easterEggTimer);
});
</script>

<template>
  <div class="relative mx-auto min-h-dvh w-full max-w-[1500px] px-3 pb-28 pt-3 sm:px-5 md:px-7 md:pb-12 md:pt-6">
    <header class="mb-5 flex flex-nowrap items-center justify-between gap-1 md:mb-7">
      <div class="flex min-w-0 items-center gap-1 rounded-full bg-white/[0.045] p-0.5 pr-1.5 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.07),inset_0_1px_0_rgba(255,255,255,0.06)]">
        <button
          class="brand-mark grid size-[49px] shrink-0 place-items-center rounded-full bg-gradient-to-br from-emerald-300 via-cyan-300 to-rose-300 text-[#05110e] shadow-[inset_0_1px_0_rgba(255,255,255,0.7),0_8px_24px_rgba(34,211,238,0.14)] transition-[transform,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-200/80 active:scale-[0.94]"
          type="button"
          aria-label="MagicNet 品牌标记"
          title="MagicNet"
          @click="handleBrandMarkClick"
        >
          <Zap :size="21" />
        </button>
        <div class="hidden min-w-0 min-[360px]:block">
          <h1 class="truncate text-[17px] font-semibold leading-tight tracking-[-0.03em] text-white sm:text-xl">MagicNet</h1>
          <p class="hidden truncate text-[11px] text-zinc-500 sm:block">Root network workspace</p>
        </div>
      </div>

      <div class="flex items-center gap-0.5 rounded-full bg-[#0b0c0e]/90 p-0.5 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.07)]">
        <Button
          size="sm"
          class="size-[49px] px-0 sm:w-auto sm:px-4"
          :loading="state.task === '创建 GitHub issue'"
          aria-label="创建 GitHub Issue"
          title="创建 GitHub Issue"
          @click="createIssue"
        >
          <Bug :size="16" /><span class="hidden sm:inline">创建 Issue</span>
        </Button>
        <Button
          variant="ghost"
          size="sm"
          class="size-[49px] px-0 sm:w-auto sm:px-4"
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
          class="size-[49px] px-0 sm:w-auto sm:px-4"
          aria-label="打开悄悄话"
          title="打开悄悄话"
          @click="openExternal(AUTHOR_WHISPER_URL, '悄悄话')"
        >
          <MessageCircle :size="16" /><span class="hidden sm:inline">悄悄话</span>
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="size-[49px] px-0 sm:w-auto sm:px-4"
          aria-label="打开 GitHub"
          title="打开 GitHub"
          @click="openExternal(REPO, 'GitHub')"
        >
          <Github :size="16" /><span class="hidden sm:inline">GitHub</span>
        </Button>
      </div>
    </header>

    <section class="runtime-cockpit relative z-20 mb-5 grid gap-4 rounded-[2rem] bg-[#0b0d0f]/94 p-2 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.08),inset_0_0_0_7px_rgba(255,255,255,0.018),0_18px_60px_rgba(0,0,0,0.16)] md:sticky md:top-4 md:grid-cols-[minmax(220px,1.05fr)_minmax(0,1fr)_auto] md:items-center md:gap-2 md:backdrop-blur-xl">
      <div class="rounded-[1.55rem] bg-gradient-to-br from-emerald-400/[0.09] via-white/[0.025] to-cyan-400/[0.07] px-4 py-3 shadow-[inset_0_0_0_1px_rgba(110,231,183,0.09)]">
        <div class="flex items-center justify-between gap-3">
          <div class="min-w-0 flex-1">
            <span class="text-[9px] font-semibold uppercase tracking-[0.22em] text-zinc-500">Runtime status</span>
            <div class="mt-1.5 flex min-w-0 items-center gap-2.5">
              <span :class="['size-2.5 shrink-0 rounded-full shadow-[0_0_18px_currentColor]', state.runtime.singBoxState === 'sing-box' ? 'bg-emerald-300 text-emerald-300' : state.runtime.singBoxState === 'stopped' ? 'bg-rose-300 text-rose-300' : 'bg-amber-300 text-amber-300']" />
              <strong class="w-0 min-w-0 flex-1 truncate text-lg font-semibold tracking-[-0.03em] text-white">
                {{ state.runtime.singBoxState === "sing-box" ? "sing-box online" : state.runtime.singBoxState === "unknown" ? "状态未知" : state.runtime.singBoxState }}
              </strong>
            </div>
          </div>
          <Badge :tone="statusTone">{{ state.runtime.singBoxState }}</Badge>
        </div>
      </div>

      <div class="grid min-w-0 grid-cols-2 gap-2 px-2 pb-2 md:px-3 md:pb-0">
        <div class="min-w-0">
          <span class="text-[9px] font-semibold uppercase tracking-[0.2em] text-zinc-600">Mode</span>
          <code class="mt-1 block truncate text-xs text-cyan-100 md:text-sm">{{ state.runtime.transparentMode }}</code>
        </div>
        <div class="min-w-0">
          <span class="text-[9px] font-semibold uppercase tracking-[0.2em] text-zinc-600">Core</span>
          <code class="mt-1 block truncate text-xs text-zinc-300 md:text-sm">{{ state.runtime.singBox }}</code>
        </div>
        <div class="col-span-2 flex min-w-0 items-center gap-2 text-xs leading-5 text-zinc-400 md:text-sm">
          <ScrollText class="shrink-0 text-rose-300" :size="14" />
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
      <nav class="desktop-rail sticky top-36 hidden gap-1.5 rounded-[2rem] bg-[#0b0c0e]/92 p-2 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.075),inset_0_0_0_7px_rgba(255,255,255,0.018),0_24px_70px_rgba(0,0,0,0.22)] backdrop-blur-xl md:grid" aria-label="MagicNet 页面">
        <div class="px-3 pb-1 pt-2 text-[9px] font-semibold uppercase tracking-[0.22em] text-zinc-600">常用工作区</div>
        <button
          v-for="item in primaryTabs"
          :key="item.key"
          :data-tab="item.key"
          :class="[
            'flex min-h-12 min-w-0 items-center gap-3 rounded-[1.25rem] px-3 text-sm font-medium transition-[transform,color,background-color,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300/60 active:scale-[0.98]',
            activeTab === item.key ? 'bg-gradient-to-r from-emerald-300 to-cyan-300 text-[#06110e] shadow-[inset_0_1px_0_rgba(255,255,255,0.5)]' : 'text-zinc-400 hover:bg-white/[0.06] hover:text-white',
          ]"
          @click="setTab(item.key)"
        >
          <component :is="item.icon" :size="18" />
          <span>{{ item.label }}</span>
        </button>

        <div class="mt-3 px-3 pb-1 text-[9px] font-semibold uppercase tracking-[0.22em] text-zinc-600">进阶工具</div>
        <button
          v-for="item in advancedTabs"
          :key="item.key"
          :data-tab="item.key"
          :class="[
            'flex min-h-12 min-w-0 items-center gap-3 rounded-[1.25rem] px-3 text-sm font-medium transition-[transform,color,background-color,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300/60 active:scale-[0.98]',
            activeTab === item.key ? 'bg-white/[0.1] text-cyan-100 shadow-[inset_0_0_0_1px_rgba(103,232,249,0.16)]' : 'text-zinc-500 hover:bg-white/[0.05] hover:text-zinc-200',
          ]"
          @click="setTab(item.key)"
        >
          <component :is="item.icon" :size="18" />
          <span>{{ item.label }}</span>
        </button>
      </nav>

      <section class="page-enter min-w-0 overflow-hidden">
        <component :is="activeComponent" :key="activeTab" @goto-output="setTab('output')" />
      </section>
    </main>

    <nav class="mobile-nav fixed inset-x-3 bottom-[max(0.75rem,env(safe-area-inset-bottom))] z-30 grid grid-cols-6 gap-1 rounded-[1.8rem] bg-[#0b0c0e]/90 p-1.5 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.1),0_18px_55px_rgba(0,0,0,0.38)] backdrop-blur-2xl md:hidden" aria-label="MagicNet 移动导航">
      <button
        v-for="item in primaryTabs"
        :key="item.key"
        :data-tab="item.key"
        :class="[
          'flex min-h-12 min-w-0 flex-col items-center justify-center gap-0.5 rounded-[1.2rem] px-1 text-[10px] font-medium transition-[transform,color,background-color,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300/60 active:scale-[0.95]',
          activeTab === item.key ? 'bg-gradient-to-b from-emerald-300 to-cyan-300 text-[#06110e]' : 'text-zinc-500',
        ]"
        @click="setTab(item.key)"
      >
        <component :is="item.icon" :size="18" />
        <span>{{ item.label }}</span>
      </button>
      <button
        :class="[
          'flex min-h-12 min-w-0 flex-col items-center justify-center gap-0.5 rounded-[1.2rem] px-1 text-[10px] font-medium transition-[transform,color,background-color,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300/60 active:scale-[0.95]',
          activeAdvancedTab ? 'bg-white/[0.1] text-cyan-200' : 'text-zinc-500',
        ]"
        aria-haspopup="dialog"
        :aria-expanded="showAdvancedNav"
        @click="showAdvancedNav = true"
      >
        <component :is="activeAdvancedTab?.icon || MoreHorizontal" :size="18" />
        <span>{{ activeAdvancedTab?.label || "更多" }}</span>
      </button>
    </nav>

    <Transition name="sheet">
      <div v-if="showAdvancedNav" class="fixed inset-0 z-40 md:hidden" role="dialog" aria-modal="true" aria-label="进阶导航">
        <button class="absolute inset-0 size-full bg-black/70 backdrop-blur-sm" type="button" aria-label="关闭进阶导航" @click="showAdvancedNav = false" />
        <div class="absolute inset-x-3 bottom-[max(0.75rem,env(safe-area-inset-bottom))] rounded-[2rem] bg-[#0b0c0e]/96 p-2 pb-3 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.1),0_26px_80px_rgba(0,0,0,0.42)] backdrop-blur-2xl">
          <div class="flex items-center justify-between px-3 pb-2 pt-2">
            <div>
              <span class="text-[9px] font-semibold uppercase tracking-[0.22em] text-zinc-600">Advanced workspace</span>
              <h2 class="mt-1 text-lg font-semibold tracking-[-0.03em] text-white">进阶工具</h2>
            </div>
            <Button variant="ghost" size="icon" aria-label="关闭进阶导航" @click="showAdvancedNav = false"><X :size="18" /></Button>
          </div>
          <div class="grid grid-cols-2 gap-1.5">
            <button
              v-for="item in advancedTabs"
              :key="item.key"
              :data-tab="item.key"
              :class="[
                'flex min-h-14 min-w-0 items-center gap-3 rounded-[1.35rem] px-4 text-sm font-medium transition-[transform,color,background-color,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/60 active:scale-[0.97]',
                activeTab === item.key ? 'bg-gradient-to-r from-emerald-300 to-cyan-300 text-[#06110e]' : 'bg-white/[0.045] text-zinc-300',
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
      <aside v-if="easterEggVisible" class="fixed bottom-28 right-3 z-50 max-w-[calc(100vw-1.5rem)] rounded-[1.75rem] bg-[#0b0c0e]/94 p-1.5 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.1),0_22px_70px_rgba(0,0,0,0.38)] backdrop-blur-2xl md:bottom-8 md:right-8 md:max-w-sm" role="status" aria-live="polite">
        <div class="flex items-start gap-3 rounded-[1.4rem] bg-gradient-to-br from-rose-400/10 via-white/[0.025] to-cyan-400/10 p-4">
          <div class="grid size-10 shrink-0 place-items-center rounded-full bg-gradient-to-br from-rose-300 to-cyan-300 text-lg text-[#070809]">😎</div>
          <div class="min-w-0 flex-1">
            <strong class="text-sm font-semibold text-white">准备好你的太阳镜 😎</strong>
            <p class="mt-1 text-xs leading-5 text-zinc-400">SOL 到此一游 · 光太亮，别直视内核。</p>
          </div>
          <button class="grid size-[49px] shrink-0 place-items-center rounded-full text-zinc-500 transition-[transform,color,background-color,opacity] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] hover:bg-white/[0.07] hover:text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/60 active:scale-[0.94]" type="button" aria-label="关闭彩蛋" @click="closeEasterEgg">
            <X :size="16" />
          </button>
        </div>
      </aside>
    </Transition>
  </div>
</template>
