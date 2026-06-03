<script setup lang="ts">
import {
  Activity,
  Ban,
  DownloadCloud,
  MonitorCog,
  Gauge,
  Github,
  ListFilter,
  MessageCircle,
  Medal,
  ScrollText,
  Settings,
  Stethoscope,
  Terminal,
  Zap
} from "lucide-vue-next";
import { computed, nextTick, onMounted, ref } from "vue";
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

const { state, statusTone, refreshAll, refreshStatus, refreshApps, refreshBlock, refreshSubs, refreshHealth, refreshCapture, refreshCerts, refreshMcp, openExternal, REPO, AUTHOR_WHISPER_URL } = useMagicNet();
const activeTab = ref<TabKey>("control");

const tabs = [
  { key: "control", label: "控制", icon: Gauge },
  { key: "config", label: "配置", icon: Settings },
  { key: "apps", label: "应用", icon: ListFilter },
  { key: "block", label: "黑名单", icon: Ban },
  { key: "subs", label: "订阅", icon: DownloadCloud },
  { key: "rank", label: "排行", icon: Medal },
  { key: "tools", label: "工具", icon: Stethoscope },
  { key: "webui", label: "面板", icon: MonitorCog },
  { key: "health", label: "诊断", icon: Stethoscope },
  { key: "output", label: "输出", icon: Terminal }
] as const;

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
const shortStatusMessage = computed(() => {
  const message = statusMessage.value;
  return message.length > 38 ? `${message.slice(0, 34)}...` : message;
});

function setTab(tab: TabKey): void {
  activeTab.value = tab;
  warmActiveTab(tab);
  void nextTick(() => {
    document
      .querySelector(`[data-tab="${tab}"]`)
      ?.scrollIntoView({ block: "nearest", inline: "center" });
  });
}

function warmActiveTab(tab: TabKey): void {
  if (tab === "apps") void refreshApps(true);
  if (tab === "block") void refreshBlock(true);
  if (tab === "subs") void refreshSubs(true);
  if (tab === "health") {
    void refreshMcp(true);
    void refreshHealth(true);
  }
}

onMounted(() => {
  void refreshStatus();
});
</script>

<template>
  <div class="mx-auto w-full max-w-6xl p-3 pb-28 md:p-5">
    <header class="mb-3 flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
      <div class="flex min-w-0 items-center gap-3">
        <div class="grid size-11 place-items-center rounded-md border border-zinc-800 bg-zinc-950"><Zap :size="24" /></div>
        <div>
          <h1 class="text-2xl font-semibold leading-tight">MagicNet</h1>
          <p class="text-sm text-zinc-400">Android root transparent proxy control</p>
        </div>
      </div>
      <div class="grid grid-cols-3 gap-2 sm:flex sm:flex-wrap sm:items-center">
        <Button variant="ghost" size="sm" class="px-2" :loading="state.task === '刷新面板'" @click="refreshAll">
          <Activity :size="16" />刷新
        </Button>
        <Button variant="outline" size="sm" class="px-2" @click="openExternal(AUTHOR_WHISPER_URL, '悄悄话')">
          <MessageCircle :size="16" />悄悄话
        </Button>
        <Button variant="outline" size="sm" class="px-2" @click="openExternal(REPO, 'GitHub')">
          <Github :size="16" />GitHub
        </Button>
      </div>
    </header>

    <section class="sticky top-0 z-20 mb-4 grid min-h-14 grid-cols-[minmax(0,1fr)_auto] items-center gap-2 rounded-md border border-zinc-800 bg-zinc-950/90 px-3 py-2 shadow-lg shadow-black/20 backdrop-blur md:flex md:overflow-x-auto">
      <div class="grid min-w-0 gap-0.5 md:min-w-28">
        <span class="text-[11px] font-bold uppercase tracking-wide text-zinc-500">Runtime</span>
        <strong class="text-sm">{{ state.runtime.core === "unknown" ? "状态未知" : state.runtime.core }}</strong>
      </div>
      <Badge :tone="statusTone">{{ state.runtime.core }}</Badge>
      <span class="hidden items-center gap-1 whitespace-nowrap text-sm text-zinc-400 md:inline-flex">sing-box <code class="text-zinc-100">{{ state.runtime.singBox }}</code></span>
      <span class="hidden items-center gap-1 whitespace-nowrap text-sm text-zinc-400 md:inline-flex">mihomo <code class="text-zinc-100">{{ state.runtime.mihomo }}</code></span>
      <span class="hidden items-center gap-1 whitespace-nowrap text-sm text-zinc-400 md:inline-flex">模式 <code class="text-zinc-100">{{ state.runtime.transparentMode }}</code></span>
      <span class="col-span-2 flex min-w-0 items-center gap-1 overflow-hidden text-sm leading-5 text-zinc-400 md:col-span-1">
        <ScrollText class="shrink-0" :size="15" />
        <span class="min-w-0 truncate" :title="statusMessage">{{ shortStatusMessage }}</span>
      </span>
    </section>

    <main class="block md:flex md:items-start md:gap-4">
      <nav class="fixed inset-x-3 bottom-3 z-30 flex gap-1 overflow-x-auto rounded-md border border-zinc-800 bg-zinc-950/95 p-1 shadow-2xl shadow-black/40 backdrop-blur md:sticky md:top-20 md:inset-auto md:w-40 md:flex-none md:grid md:grid-cols-1 md:p-1.5" aria-label="MagicNet 页面">
        <button
          v-for="item in tabs"
          :key="item.key"
          :data-tab="item.key"
          :disabled="false"
          :class="[
            'flex min-h-11 min-w-[4.25rem] shrink-0 flex-col items-center justify-center gap-0.5 rounded-md px-2 text-[10px] text-zinc-400 transition-colors md:min-h-10 md:w-auto md:min-w-0 md:flex-row md:justify-start md:gap-1 md:px-2 md:text-sm',
            activeTab === item.key ? 'bg-zinc-800 text-zinc-50' : 'hover:bg-zinc-900'
          ]"
          @click="setTab(item.key)"
        >
          <component :is="item.icon" :size="18" />
          <span>{{ item.label }}</span>
        </button>
      </nav>

      <section class="min-w-0 flex-1 overflow-hidden">
        <component :is="activeComponent" @goto-output="setTab('output')" />
      </section>
    </main>
  </div>
</template>
