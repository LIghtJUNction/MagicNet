<script setup lang="ts">
import {
  Bug,
  Gauge,
  GitBranch,
  Github,
  MessageCircle,
  Monitor,
  Moon,
  MoreHorizontal,
  RefreshCw,
  ScrollText,
  Settings,
  Stethoscope,
  Sun,
  X,
} from "lucide-vue-next";
import { computed, defineAsyncComponent, nextTick, onMounted, onUnmounted, ref, type Component } from "vue";
import { t } from "@/i18n";
import LanguageSelect from "@/components/LanguageSelect.vue";
import { MAGICNET_LOGO_URL } from "@/branding";
import IssueReporterDialog from "@/components/IssueReporterDialog.vue";
import OnboardingDialog from "@/components/OnboardingDialog.vue";
import OpenSourceSupportNote from "@/components/OpenSourceSupportNote.vue";
import Button from "@/components/ui/Button.vue";
import StatusDot from "@/components/ui/StatusDot.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { setPendingSubscriptionDraft } from "@/components/pages/subscriptionDraft";
import { useTheme } from "@/composables/useTheme";
import { useMobileKeyboard } from "@/composables/useMobileKeyboard";
import { restoreFocusAfterUpdate, trapFocusWithin } from "@/lib/focus";

type TabKey = "control" | "about" | "config" | "apps" | "block" | "chain" | "subs" | "tools" | "health" | "webui" | "output";
type WorkspaceKey = "run" | "route" | "configure" | "diagnose";
type OnboardingPreference = "dismissed" | "completed";

type TabDefinition = {
  key: TabKey;
  label: string;
  workspace: WorkspaceKey;
};

type WorkspaceDefinition = {
  key: WorkspaceKey;
  label: string;
  mobileLabel?: string;
  icon: Component;
};

const ONBOARDING_STORAGE_KEY = "magicnet.webui.onboarding.v1";

const pageLoaders: Record<TabKey, () => Promise<{ default: Component }>> = {
  control: () => import("@/components/pages/ControlPage.vue"),
  about: () => import("@/components/pages/AboutPage.vue"),
  config: () => import("@/components/pages/ConfigPage.vue"),
  apps: () => import("@/components/pages/AppsPage.vue"),
  block: () => import("@/components/pages/BlocklistPage.vue"),
  chain: () => import("@/components/pages/ProxyChainPage.vue"),
  subs: () => import("@/components/pages/SubscriptionsPage.vue"),
  tools: () => import("@/components/pages/ToolsPage.vue"),
  webui: () => import("@/components/pages/WebuiPage.vue"),
  health: () => import("@/components/pages/DiagnosticsPage.vue"),
  output: () => import("@/components/pages/OutputPage.vue"),
};

/** Lazy page components keep inactive workspaces off the first-load critical path. */
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

const tabs: readonly TabDefinition[] = [
  { key: "control", label: "概览", workspace: "run" },
  { key: "about", label: "流量路径", workspace: "run" },
  { key: "apps", label: "应用", workspace: "route" },
  { key: "block", label: "拦截规则", workspace: "route" },
  { key: "chain", label: "链式代理", workspace: "route" },
  { key: "subs", label: "订阅", workspace: "configure" },
  { key: "config", label: "配置文件", workspace: "configure" },
  { key: "webui", label: "管理面板", workspace: "configure" },
  { key: "health", label: "健康检查", workspace: "diagnose" },
  { key: "tools", label: "工具", workspace: "diagnose" },
  { key: "output", label: "最近输出", workspace: "diagnose" },
];

const workspaces: readonly WorkspaceDefinition[] = [
  {
    key: "run",
    label: "运行",
    icon: Gauge,
  },
  {
    key: "route",
    label: "路由",
    icon: GitBranch,
  },
  {
    key: "configure",
    label: "配置",
    mobileLabel: "订阅",
    icon: Settings,
  },
  {
    key: "diagnose",
    label: "诊断",
    icon: Stethoscope,
  },
];

const {
  state,
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
  closeIssueReporter,
  submitIssue,
  openExternal,
  REPO,
  AUTHOR_WHISPER_URL,
} = useMagicNet();
const { preference: themePreference, label: themeLabel, cycleTheme } = useTheme();
const { keyboardOpen } = useMobileKeyboard();

function readTabFromLocation(): TabKey | null {
  if (typeof window === "undefined") return null;
  const key = window.location.hash.replace(/^#\/?/, "");
  return tabs.some((item) => item.key === key) ? key as TabKey : null;
}

function writeTabToLocation(tab: TabKey, replace = false): void {
  if (typeof window === "undefined") return;
  const hash = `#/${tab}`;
  if (window.location.hash === hash) return;
  const method = replace ? "replaceState" : "pushState";
  window.history[method]({ tab }, "", hash);
}

const activeTab = ref<TabKey>(readTabFromLocation() ?? "control");
const lastTabByWorkspace = ref<Record<WorkspaceKey, TabKey>>({
  run: "control",
  route: "apps",
  configure: "subs",
  diagnose: "health",
});
const showUtilityMenu = ref(false);
const showOnboarding = ref(false);
const utilityDialog = ref<HTMLElement | null>(null);
const utilityMenuTrigger = ref<HTMLElement | null>(null);
const onboardingTrigger = ref<HTMLElement | null>(null);

const easterEggVisitors = [
  {
    name: "GPT-6",
    title: "GPT-6 到此一游",
    body: "少画几个框，多留一点位置给内容。",
  },
  {
    name: "SOL",
    title: "准备好你的太阳镜 😎",
    body: "SOL 到此一游 · 光太亮，别直视内核。",
  },
  {
    name: "Grok 4.5",
    title: "Grok 4.5 到此一游 ✨",
    body: "xAI 路过 MagicNet · 路由已嗅探，彩蛋已落盘。",
  },
  {
    name: "Kimi K3",
    title: "Kimi K3 到此一游 🌙",
    body: "月之暗面打卡成功 · 上下文很长，短签也行。",
  },
  {
    name: "Fable 5",
    title: "Fable 5 到此一游 📖",
    body: "Claude Fable 5 翻过这页 · 故事继续，彩蛋已签收。",
  },
] as const;

const easterEggVisible = ref(false);
const easterEggShownIndex = ref(0);
let easterEggNextIndex = 0;
const easterEggPayload = computed(
  () => easterEggVisitors[easterEggShownIndex.value] ?? easterEggVisitors[0],
);
let brandClickCount = 0;
let brandClickWindowStartedAt = 0;
let easterEggTimer: number | undefined;
let bodyOverflowBeforeDialog = "";

const activeTabDefinition = computed(
  () => tabs.find((item) => item.key === activeTab.value) ?? tabs[0],
);
const activeWorkspace = computed(
  () => workspaces.find((item) => item.key === activeTabDefinition.value.workspace) ?? workspaces[0],
);
const activeSectionTabs = computed(() =>
  tabs.filter((item) => item.workspace === activeWorkspace.value.key),
);
const activeComponent = computed(() => asyncPages[activeTab.value]);

const statusMessage = computed(() => (state.task ? t("正在执行：{task}", { task: t(state.task) }) : t(state.notice)));
const runtimeStateLabel = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return t("sing-box 运行中");
  if (state.runtime.singBoxState === "stopped") return t("已停止");
  return t("状态未知");
});
const routeStackState = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "active";
  if (state.runtime.singBoxState === "stopped") return "stopped";
  return "unknown";
});
const transparentRouteData = computed(() => {
  if (state.runtime.transparentMode === "tun") return "magicnet0";
  if (state.runtime.transparentMode === "ebpf") return state.runtime.transparentEffectiveMode;
  return "unknown";
});
const statusDotTone = computed(() => {
  if (state.runtime.singBoxState === "sing-box") return "ok" as const;
  if (state.runtime.singBoxState === "stopped") return "stop" as const;
  return "unknown" as const;
});

function setTab(tab: TabKey, options: { updateLocation?: boolean } = {}): void {
  if (tab !== activeTab.value) {
    activeTab.value = tab;
    const definition = tabs.find((item) => item.key === tab);
    if (definition) lastTabByWorkspace.value[definition.workspace] = tab;
    warmActiveTab(tab);
  }
  if (options.updateLocation !== false) writeTabToLocation(tab);
  void nextTick(() => {
    const target = Array.from(
      document.querySelectorAll<HTMLElement>(`[data-tab="${tab}"]`),
    ).find((item) => item.offsetParent !== null);
    target?.scrollIntoView({ block: "nearest", inline: "center" });
  });
}

function setWorkspace(workspace: WorkspaceKey): void {
  setTab(workspace === "configure" ? "subs" : lastTabByWorkspace.value[workspace]);
}

function syncTabFromLocation(): void {
  const tab = readTabFromLocation();
  if (tab) setTab(tab, { updateLocation: false });
}

function readOnboardingPreference(): OnboardingPreference | null {
  if (typeof window === "undefined") return null;
  try {
    const stored = window.localStorage.getItem(ONBOARDING_STORAGE_KEY);
    if (stored === "dismissed" || stored === "completed") return stored;
  } catch {
    return null;
  }
  return null;
}

function persistOnboardingPreference(value: OnboardingPreference): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(ONBOARDING_STORAGE_KEY, value);
  } catch {
    // Ignore storage failures; the dialog remains usable for the current session.
  }
}

function restoreOnboardingTriggerFocus(): void {
  const trigger = onboardingTrigger.value;
  onboardingTrigger.value = null;
  restoreFocusAfterUpdate(trigger);
}

function launchOnboarding(trigger: HTMLElement | null = null): void {
  onboardingTrigger.value = trigger;
  showOnboarding.value = true;
}

async function requestOnboarding(event?: MouseEvent): Promise<void> {
  const trigger = event?.currentTarget instanceof HTMLElement ? event.currentTarget : null;
  if (showUtilityMenu.value) {
    closeUtilityMenu(false);
    await nextTick();
    launchOnboarding(utilityMenuTrigger.value);
    return;
  }
  launchOnboarding(trigger);
}

function closeOnboarding(preference: OnboardingPreference = "dismissed"): void {
  if (!showOnboarding.value) return;
  persistOnboardingPreference(preference);
  showOnboarding.value = false;
  restoreOnboardingTriggerFocus();
}

function handleOnboardingSubmit(value: string): void {
  setPendingSubscriptionDraft(value);
  closeOnboarding("completed");
  setTab("subs");
}

async function requestIssue(): Promise<void> {
  if (showUtilityMenu.value) closeUtilityMenu(false);
  await createIssue();
}

async function openUtilityMenu(event: MouseEvent): Promise<void> {
  if (event.currentTarget instanceof HTMLElement) {
    utilityMenuTrigger.value = event.currentTarget;
  }
  bodyOverflowBeforeDialog = document.body.style.overflow;
  document.body.style.overflow = "hidden";
  showUtilityMenu.value = true;
  await nextTick();
  const initial = utilityDialog.value?.querySelector<HTMLElement>("[data-dialog-initial-focus]");
  (initial || utilityDialog.value)?.focus();
}

function closeUtilityMenu(restoreFocus = true): void {
  if (!showUtilityMenu.value) return;
  showUtilityMenu.value = false;
  document.body.style.overflow = bodyOverflowBeforeDialog;
  const trigger = utilityMenuTrigger.value;
  if (restoreFocus) restoreFocusAfterUpdate(trigger);
}

function trapUtilityMenuFocus(event: KeyboardEvent): void {
  if (!showUtilityMenu.value) return;
  trapFocusWithin(event, utilityDialog.value);
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
  easterEggShownIndex.value = easterEggNextIndex % easterEggVisitors.length;
  easterEggNextIndex = (easterEggShownIndex.value + 1) % easterEggVisitors.length;
  easterEggVisible.value = true;
  if (easterEggTimer !== undefined) window.clearTimeout(easterEggTimer);
  easterEggTimer = window.setTimeout(closeEasterEgg, 5200);
}

function dismissActionMenus(event: PointerEvent): void {
  if (!(event.target instanceof Node)) return;
  for (const menu of document.querySelectorAll<HTMLDetailsElement>(".config-action-menu[open]")) {
    if (!menu.contains(event.target)) menu.open = false;
  }
}

function handleEscape(event: KeyboardEvent): void {
  if (event.key === "Tab") {
    trapUtilityMenuFocus(event);
    return;
  }
  if (event.key !== "Escape") return;
  if (showUtilityMenu.value) {
    event.preventDefault();
    closeUtilityMenu();
    return;
  }
  const menu = document.querySelector<HTMLDetailsElement>(".config-action-menu[open]");
  if (menu) {
    event.preventDefault();
    menu.open = false;
    menu.querySelector("summary")?.focus();
    return;
  }
  closeEasterEgg();
}

function prefetchTab(tab: TabKey): void {
  void pageLoaders[tab]();
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
  document.addEventListener("pointerdown", dismissActionMenus);
  window.addEventListener("popstate", syncTabFromLocation);
  window.addEventListener("hashchange", syncTabFromLocation);
  writeTabToLocation(activeTab.value, true);
  void pageLoaders[activeTab.value]();
  if (state.hasKsu && !readOnboardingPreference()) {
    void nextTick(() => {
      if (!showOnboarding.value) launchOnboarding();
    });
  }
  const warm = () => {
    void pageLoaders.config();
    void pageLoaders.apps();
    void pageLoaders.health();
  };
  if (typeof requestIdleCallback === "function") requestIdleCallback(warm, { timeout: 2500 });
  else window.setTimeout(warm, 800);
});

onUnmounted(() => {
  document.removeEventListener("keydown", handleEscape);
  document.removeEventListener("pointerdown", dismissActionMenus);
  window.removeEventListener("popstate", syncTabFromLocation);
  window.removeEventListener("hashchange", syncTabFromLocation);
  if (easterEggTimer !== undefined) window.clearTimeout(easterEggTimer);
  if (showUtilityMenu.value) document.body.style.overflow = bodyOverflowBeforeDialog;
});
</script>

<template>
  <div class="mn-shell" :class="{ 'mn-keyboard-open': keyboardOpen }">
    <header class="mn-command-bar">
      <div class="mn-brand-lockup">
        <button
          class="mn-brand-mark brand-mark"
          type="button"
          :aria-label="t('MagicNet 品牌标记')"
          title="MagicNet"
          @click="handleBrandMarkClick"
        >
          <img
            :src="MAGICNET_LOGO_URL"
            alt=""
            width="42"
            height="42"
            decoding="async"
          />
        </button>
        <div class="mn-brand-copy">
          <h1>MagicNet</h1>
        </div>
      </div>

      <div class="mn-global-actions">
        <LanguageSelect class="mn-language-header" />
        <Button
          variant="ghost"
          size="icon"
          :aria-label="t('外观主题：{theme}，点击切换', { theme: themeLabel })"
          :title="t('外观：{theme}（亮色 → 暗色 → 跟随系统）', { theme: themeLabel })"
          @click="cycleTheme"
        >
          <Sun v-if="themePreference === 'light'" :size="17" aria-hidden="true" />
          <Moon v-else-if="themePreference === 'dark'" :size="17" aria-hidden="true" />
          <Monitor v-else :size="17" aria-hidden="true" />
        </Button>
        <Button
          variant="ghost"
          size="icon"
          :loading="state.task === '刷新面板'"
          :aria-label="t('刷新面板')"
          :title="t('刷新面板')"
          @click="refreshAll"
        >
          <RefreshCw :size="17" aria-hidden="true" />
        </Button>
        <Button
          class="mn-desktop-action"
          variant="outline"
          size="sm"
          :aria-label="t('打开新手引导')"
          @click="requestOnboarding"
        >
          <ScrollText :size="16" aria-hidden="true" />{{ t('引导') }}
        </Button>
        <Button
          class="mn-desktop-action"
          variant="outline"
          size="sm"
          :loading="state.task === '创建 GitHub issue'"
          :aria-label="t('创建 GitHub Issue')"
          @click="createIssue"
        >
          <Bug :size="16" aria-hidden="true" />{{ t('反馈') }}
        </Button>
        <Button
          class="mn-desktop-action"
          variant="outline"
          size="sm"
          :aria-label="t('打开 GitHub')"
          @click="openExternal(REPO, 'GitHub')"
        >
          <Github :size="16" aria-hidden="true" />GitHub
        </Button>
        <Button
          class="mn-more-action"
          variant="ghost"
          size="icon"
          :aria-label="t('打开系统工具')"
          aria-haspopup="dialog"
          :aria-expanded="showUtilityMenu"
          @click="openUtilityMenu"
        >
          <MoreHorizontal :size="18" aria-hidden="true" />
        </Button>
      </div>
    </header>

    <section
      v-if="state.hasKsu && (activeTab !== 'control' || state.task || state.backgroundTask.status === 'running')"
      class="mn-runtime-brief"
      :data-state="routeStackState"
      role="status"
      aria-live="polite"
      aria-atomic="true"
      :aria-label="t('MagicNet 运行状态')"
    >
      <div class="mn-runtime-state">
        <StatusDot :tone="statusDotTone" />
        <strong>{{ runtimeStateLabel }}</strong>
      </div>
      <span class="mn-runtime-mode" :title="t('数据面：{mode}', { mode: transparentRouteData })">{{ state.runtime.transparentMode === 'unknown' ? t('模式未知') : state.runtime.transparentMode === 'ebpf' ? 'eBPF' : 'TUN' }}</span>
      <p v-if="statusMessage">{{ statusMessage }}</p>
      <Button
        v-if="state.backgroundTask.log"
        variant="ghost"
        size="sm"
        @click="setTab('output')"
      >
        {{ t('查看输出') }}
      </Button>
    </section>

    <div class="mn-workspace-frame">
      <aside class="desktop-rail" :aria-label="t('MagicNet 工作区')">
        <nav :aria-label="t('全部页面')">
          <div v-for="workspace in workspaces" :key="workspace.key" class="mn-nav-group">
            <div class="mn-rail-label">
              <component :is="workspace.icon" :size="15" aria-hidden="true" />
              <span>{{ t(workspace.label) }}</span>
            </div>
            <button
              v-for="item in tabs.filter((tab) => tab.workspace === workspace.key)"
              :key="item.key"
              :data-tab="item.key"
              :class="activeTab === item.key ? 'mn-nav-active' : 'mn-nav-idle'"
              type="button"
              :aria-current="activeTab === item.key ? 'page' : undefined"
              @pointerenter="prefetchTab(item.key)"
              @focus="prefetchTab(item.key)"
              @click="setTab(item.key)"
            >
              <span>{{ t(item.label) }}</span>
            </button>
          </div>
        </nav>
      </aside>

      <main class="mn-workspace-main">
        <header class="mn-workspace-header">
          <nav class="mn-section-tabs" :aria-label="t('{workspace}分区', { workspace: t(activeWorkspace.label) })">
            <button
              v-for="item in activeSectionTabs"
              :key="item.key"
              :data-tab="item.key"
              :class="activeTab === item.key ? 'is-active' : undefined"
              type="button"
              :aria-current="activeTab === item.key ? 'page' : undefined"
              @pointerenter="prefetchTab(item.key)"
              @focus="prefetchTab(item.key)"
              @click="setTab(item.key)"
            >
              <span>{{ t(item.label) }}</span>
            </button>
          </nav>
        </header>

        <!-- KeepAlive preserves form state across all four workspaces. -->
        <section class="page-surface" :data-page="activeTab">
          <Suspense>
            <KeepAlive :max="11">
              <component
                :is="activeComponent"
                @goto-output="setTab('output')"
                @goto-tab="setTab"
              />
            </KeepAlive>
            <template #fallback>
              <div class="mn-loading-panel" role="status">{{ t('正在加载…') }}</div>
            </template>
          </Suspense>
        </section>
      </main>
    </div>

    <nav v-show="!keyboardOpen" class="mobile-nav" :aria-label="t('MagicNet 移动导航')">
      <button
        v-for="workspace in workspaces"
        :key="workspace.key"
        :data-workspace="workspace.key"
        :class="activeWorkspace.key === workspace.key ? 'mn-nav-active' : 'mn-nav-idle'"
        type="button"
        :aria-current="activeWorkspace.key === workspace.key ? 'page' : undefined"
        @click="setWorkspace(workspace.key)"
      >
        <component :is="workspace.icon" :size="19" aria-hidden="true" />
        <span>{{ t(workspace.mobileLabel ?? workspace.label) }}</span>
      </button>
    </nav>

    <Transition name="sheet">
      <div v-if="showUtilityMenu" class="mn-sheet-layer">
        <button class="mn-overlay" type="button" :aria-label="t('关闭系统工具')" @click="closeUtilityMenu()" />
        <div
          ref="utilityDialog"
          class="mn-utility-sheet"
          role="dialog"
          aria-modal="true"
          :aria-label="t('系统工具')"
          tabindex="-1"
        >
          <div class="mn-sheet-header">
            <div>
              <h2>{{ t('系统工具') }}</h2>
            </div>
            <Button data-dialog-initial-focus variant="ghost" size="icon" :aria-label="t('关闭系统工具')" @click="closeUtilityMenu()">
              <X :size="18" aria-hidden="true" />
            </Button>
          </div>
          <div class="mn-language-setting">
            <span>{{ t('语言') }}</span>
            <LanguageSelect />
          </div>
          <div class="mn-utility-grid">
            <Button variant="outline" @click="requestOnboarding">
              <ScrollText :size="18" aria-hidden="true" />{{ t('新手引导') }}
            </Button>
            <Button variant="outline" :loading="state.task === '创建 GitHub issue'" @click="requestIssue">
              <Bug :size="18" aria-hidden="true" />{{ t('反馈问题') }}
            </Button>
            <Button variant="outline" @click="openExternal(AUTHOR_WHISPER_URL, '悄悄话')">
              <MessageCircle :size="18" aria-hidden="true" />{{ t('悄悄话') }}
            </Button>
            <Button variant="outline" @click="openExternal(REPO, 'GitHub')">
              <Github :size="18" aria-hidden="true" />GitHub
            </Button>
          </div>
          <OpenSourceSupportNote />
        </div>
      </div>
    </Transition>

    <OnboardingDialog
      v-if="showOnboarding"
      @dismiss="closeOnboarding()"
      @submit="handleOnboardingSubmit"
    />

    <IssueReporterDialog
      v-if="state.issueReporter.open"
      :loading="state.task === '创建 GitHub issue'"
      @cancel="closeIssueReporter"
      @confirm="submitIssue"
    />

    <Transition name="toast">
      <aside v-if="easterEggVisible" class="mn-easter-egg" role="status" aria-live="polite">
        <div class="mn-easter-mark">
          <img :src="MAGICNET_LOGO_URL" alt="" width="38" height="38" decoding="async" />
        </div>
        <div class="mn-easter-copy">
          <strong>{{ t(easterEggPayload.title) }}</strong>
          <p>{{ t(easterEggPayload.body) }}</p>
          <p class="mn-visitor-line">
            <span>{{ t('来访') }}</span>
            <template v-for="(visitor, index) in easterEggVisitors" :key="visitor.name">
              <span aria-hidden="true">/</span>
              <span :class="index === easterEggShownIndex ? 'is-current' : undefined">{{ visitor.name }}</span>
            </template>
          </p>
        </div>
        <button type="button" :aria-label="t('关闭彩蛋')" @click="closeEasterEgg">
          <X :size="16" aria-hidden="true" />
        </button>
      </aside>
    </Transition>
  </div>
</template>
