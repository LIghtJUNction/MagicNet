<script setup lang="ts">
import {
  AlertTriangle,
  Check,
  ClipboardPaste,
  Clock3,
  Database,
  DownloadCloud,
  RefreshCw,
  Save,
  ShieldCheck,
} from "lucide-vue-next";
import { computed, ref, shallowRef, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import {
  isSubscriptionBackgroundArgs,
  subscriptionLifecycleRunning,
} from "@/composables/backgroundTasks";
import { MODULE_DIR } from "@/constants";
import {
  bytesToBase64,
  copyText,
  execFailed,
  readClipboardText,
} from "@/utils";
import {
  buildSubscriptionPreview,
  buildSubscriptionApplyLaunch,
  buildSubscriptionPayloadPlan,
  buildSubscriptionSavePlan,
  formatSubscriptionSummary,
  reconcileSubscriptionEditor,
  summarizeSubscriptionInput,
  type PendingSubscriptionApply,
  type SubscriptionPreview,
} from "./subscriptionPreview";

type ScheduleValue = "off" | "12" | "24" | "48" | "72";

const { state, runShell, runCli, startBackgroundCli, refreshSubs } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const singBoxText = ref("");
const lastLoadedSnapshot = ref("");
const dirty = ref(false);
const loadedOnce = ref(false);
const syncingEditor = ref(false);
const editRevision = ref(0);
const pendingApply = shallowRef<PendingSubscriptionApply | null>(null);
const summaryCopied = ref(false);
const scheduleValue = ref<ScheduleValue>("off");
const scheduleDirty = ref(false);

const inputSummary = computed(() => summarizeSubscriptionInput(singBoxText.value));
const subscriptionPreview = computed<SubscriptionPreview[]>(() => buildSubscriptionPreview(singBoxText.value).slice(0, 8));
const savePlan = computed(() => buildSubscriptionSavePlan(singBoxText.value));
const configured = computed(() => state.subscriptions.configuredCount > 0 || state.subscriptions.singBoxUrls.length > 0);
const canonicalDraft = computed(() => savePlan.value.lines.join("\n"));
const canApply = computed(() => {
  if (savePlan.value.status === "idle" || savePlan.value.status === "error") return false;
  const loadedPlan = buildSubscriptionSavePlan(lastLoadedSnapshot.value);
  const loadedCanonical = loadedPlan.status === "idle" || loadedPlan.status === "error"
    ? lastLoadedSnapshot.value.trim()
    : loadedPlan.lines.join("\n");
  return !configured.value || canonicalDraft.value !== loadedCanonical;
});
const applyLabel = computed(() => configured.value ? "保存并应用" : "保存并首次启用");
const scheduleChanged = computed(() => scheduleValue.value !== state.subscriptions.scheduleIntervalHours);
const lifecycleStatus = computed(() => {
  if (subscriptionLifecycleRunning(state.backgroundTask, state.subscriptions.updateRunning)) return "running";
  if (state.backgroundTask.status === "timeout" && isSubscriptionBackgroundArgs(state.backgroundTask.args)) return "timeout";
  if (state.subscriptions.lastResult === "success") return "done";
  if (["failed", "interrupted"].includes(state.subscriptions.lastResult)) return "error";
  return configured.value ? "idle" : "empty";
});
const lifecycleLabel = computed(() => ({
  empty: "等待首次配置",
  idle: "订阅已配置",
  running: "正在应用或刷新",
  done: "最近一次成功",
  error: "最近一次失败",
  timeout: "后台待对账",
}[lifecycleStatus.value] || lifecycleStatus.value));
const lifecycleTone = computed(() => {
  if (lifecycleStatus.value === "done" || lifecycleStatus.value === "idle") return "emerald";
  if (lifecycleStatus.value === "error") return "rose";
  if (lifecycleStatus.value === "timeout") return "amber";
  if (lifecycleStatus.value === "running") return "cyan";
  return "amber";
});
const lifecycleDotClass = computed(() => ({
  emerald: "bg-emerald-300",
  rose: "bg-rose-300",
  cyan: "bg-cyan-300",
  amber: "bg-amber-300",
}[lifecycleTone.value]));
const scheduleMeaning = computed(() => {
  if (!state.subscriptions.scheduleEnabled) return "自动刷新关闭。首次启用订阅不会改动此设置。";
  if (!state.subscriptions.scheduleOwnerValid) return "计划已保存，但后台 owner 状态不一致；请重新保存计划或检查输出。";
  if (state.subscriptions.scheduleRunning) return `后台刷新守护已就绪；每轮完成后按 ${state.subscriptions.scheduleIntervalHours} 小时间隔再次等待。`;
  return "计划已开启，但后台守护尚未就绪。";
});

watch(() => state.subscriptions.singBoxUrls, (urls) => {
  const snapshot = urls.join("\n");
  const next = reconcileSubscriptionEditor({
    draft: singBoxText.value,
    lastLoadedSnapshot: lastLoadedSnapshot.value,
    deviceSnapshot: snapshot,
    dirty: dirty.value,
    loadedOnce: loadedOnce.value,
    editRevision: editRevision.value,
    pendingApply: pendingApply.value,
  });
  if (next.syncedDraft) {
    syncingEditor.value = true;
    singBoxText.value = next.draft;
    syncingEditor.value = false;
  }
  lastLoadedSnapshot.value = next.lastLoadedSnapshot;
  dirty.value = next.dirty;
  loadedOnce.value = next.loadedOnce;
  pendingApply.value = next.pendingApply;
}, { immediate: true, deep: true });

watch(singBoxText, (value) => {
  summaryCopied.value = false;
  if (!syncingEditor.value) {
    editRevision.value += 1;
    dirty.value = value !== lastLoadedSnapshot.value;
  }
}, { flush: "sync" });

watch(() => state.subscriptions.scheduleIntervalHours, (value) => {
  if (!scheduleDirty.value || value === scheduleValue.value) {
    scheduleValue.value = value;
    scheduleDirty.value = false;
  }
}, { immediate: true });

watch(() => state.backgroundTask.status, async (status) => {
  if (!isSubscriptionBackgroundArgs(state.backgroundTask.args)) return;
  if (status === "done" && pendingApply.value) await refreshSubs(true);
  if (status === "error") pendingApply.value = null;
});

function previewTone(status: SubscriptionPreview["status"]): string {
  if (status === "ok") return "bg-emerald-400/[0.07] text-emerald-100 ring-emerald-300/15";
  if (status === "duplicate") return "bg-amber-400/[0.07] text-amber-100 ring-amber-300/15";
  return "bg-rose-400/[0.07] text-rose-100 ring-rose-300/15";
}

function formatEpoch(epoch: number): string {
  if (!epoch) return "尚无记录";
  return new Date(epoch * 1000).toLocaleString([], {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

type StagedPayload = { payload: string; cleanupCommand: string };

async function cleanupPayload(command: string): Promise<void> {
  await runShell(command, "清理订阅私有载荷", true, "su -M -c '[cleanup private subscription payload]'");
}

async function stagePrivatePayload(encoded: string): Promise<StagedPayload | null> {
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
  const directory = `${MODULE_DIR}/.state/webui-subscription-payload`;
  const payload = `${directory}/magicnet-webui-${stamp}.b64`;
  const plan = buildSubscriptionPayloadPlan(encoded, directory, payload);
  let result = await runShell(
    plan.prepareCommand,
    "准备订阅私有载荷",
    true,
    "su -M -c '[prepare private subscription payload]'",
  );
  if (execFailed(result)) {
    await cleanupPayload(plan.cleanupCommand);
    state.output = "订阅私有载荷准备失败，已执行尽力清理；订阅没有提交。";
    return null;
  }
  for (const command of plan.appendCommands) {
    result = await runShell(
      command,
      "写入订阅私有载荷",
      true,
      "su -M -c '[write redacted subscription payload]'",
    );
    if (execFailed(result)) {
      await cleanupPayload(plan.cleanupCommand);
      state.output = "订阅私有载荷写入失败，已执行尽力清理；订阅没有提交。";
      return null;
    }
  }
  return { payload, cleanupCommand: plan.cleanupCommand };
}

async function applySubscriptions(): Promise<void> {
  if (!canApply.value) return;
  await withAction("apply-subscriptions", async () => {
    const snapshot = canonicalDraft.value;
    if (singBoxText.value !== snapshot) {
      syncingEditor.value = true;
      singBoxText.value = snapshot;
      syncingEditor.value = false;
    }
    const attempt = { snapshot, revision: editRevision.value };
    pendingApply.value = attempt;
    const encoded = bytesToBase64(new TextEncoder().encode(`${snapshot}\n`));
    const staged = await stagePrivatePayload(encoded);
    if (!staged) {
      if (pendingApply.value === attempt) pendingApply.value = null;
      return;
    }
    const launch = buildSubscriptionApplyLaunch(staged.payload);
    const result = await startBackgroundCli(
      launch.args,
      configured.value ? "应用订阅配置" : "首次启用订阅",
      launch.preview,
      launch.displayArgs,
      launch.cleanupCommand,
    );
    if (execFailed(result)) {
      await cleanupPayload(launch.cleanupCommand);
      if (pendingApply.value === attempt) pendingApply.value = null;
      return;
    }
    state.output = "订阅已投递到后台。成功后 URL 会保存在设备本地订阅配置；私有临时载荷仅用于本次提交，并在后台命令结束时清理。";
  });
}

async function pasteSubscriptions(): Promise<void> {
  await withAction("paste-subscriptions", async () => {
    const text = (await readClipboardText()).trim();
    if (!text) {
      state.output = "剪贴板为空或不可读取。";
      return;
    }
    singBoxText.value = text;
    state.output = `已读取 ${text.split(/\r?\n/).filter((line) => line.trim()).length} 行；界面不会回显剪贴板原文到输出日志。`;
  });
}

function normalizeSubscriptions(): void {
  if (savePlan.value.status === "idle" || savePlan.value.status === "error") {
    state.output = savePlan.value.message;
    return;
  }
  singBoxText.value = canonicalDraft.value;
  state.output = `已规范化：保留 ${savePlan.value.lines.length} 个唯一订阅来源。`;
}

async function copySummary(): Promise<void> {
  summaryCopied.value = await copyText(formatSubscriptionSummary(singBoxText.value, subscriptionPreview.value));
  state.output = summaryCopied.value ? "订阅脱敏摘要已复制。" : "剪贴板不可用，脱敏摘要未复制。";
}

async function updateAll(): Promise<void> {
  if (!configured.value) return;
  await withAction("update-all", async () => {
    await startBackgroundCli("sub update-all", "立即刷新订阅", "", "sub update-all");
  });
}

async function saveSchedule(): Promise<void> {
  if (!scheduleChanged.value) return;
  await withAction("save-schedule", async () => {
    const result = await runCli(`sub schedule set ${scheduleValue.value}`, "保存自动刷新计划");
    if (execFailed(result)) return;
    await refreshSubs(true);
    scheduleDirty.value = false;
  });
}
</script>

<template>
  <div class="grid min-w-0 gap-4">
    <PageHeader
      overline="Subscription lifecycle"
      title="订阅生命周期"
      description="URL 成功后保存在设备本地配置；提交使用可清理的私有临时载荷。"
    />

    <section class="lifecycle-strip hidden min-w-0 gap-px rounded-md bg-white/[0.055] p-px ring-1 ring-white/[0.07] lg:grid lg:grid-cols-4" aria-label="订阅生命周期概览">
      <div class="min-w-0 rounded-[5px] bg-[#0b0d0e] px-4 py-3.5">
        <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Lifecycle</span>
        <div class="mt-2 flex items-center gap-2">
          <span :class="['size-2 rounded-full', lifecycleDotClass, lifecycleStatus === 'running' ? 'motion-safe:animate-pulse' : '']" />
          <strong class="truncate text-sm text-zinc-100">{{ lifecycleLabel }}</strong>
        </div>
      </div>
      <div class="min-w-0 rounded-[5px] bg-[#0b0d0e] px-4 py-3.5">
        <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Sources / Cache</span>
        <p class="mt-2 text-sm text-zinc-200"><strong class="text-white">{{ state.subscriptions.configuredCount }}</strong> 来源 · <strong class="text-white">{{ state.subscriptions.cacheCount }}</strong> 缓存</p>
      </div>
      <div class="min-w-0 rounded-[5px] bg-[#0b0d0e] px-4 py-3.5">
        <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Last result</span>
        <p class="mt-2 truncate text-sm text-zinc-200">{{ state.subscriptions.lastResult }} · {{ state.subscriptions.lastPhase }}</p>
      </div>
      <div class="min-w-0 rounded-[5px] bg-[#0b0d0e] px-4 py-3.5">
        <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Automatic refresh</span>
        <p class="mt-2 text-sm" :class="state.subscriptions.scheduleOwnerValid ? 'text-zinc-200' : 'text-amber-200'">
          {{ state.subscriptions.scheduleEnabled ? `${state.subscriptions.scheduleIntervalHours} 小时` : '关闭' }} · {{ state.subscriptions.scheduleRunning ? 'running' : 'stopped' }}
        </p>
      </div>
    </section>

    <div class="grid min-w-0 gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(280px,1fr)] lg:items-start">
      <Card class="min-w-0">
        <div class="flex min-w-0 flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Secure source editor</span>
            <h3 class="mt-1 text-lg font-semibold tracking-[-0.02em] text-zinc-100">sing-box 订阅来源</h3>
            <p class="mt-1 text-sm leading-6 text-zinc-500">最多 5 个，一行一个。保存会原子应用；失败时保留当前有效配置。</p>
          </div>
          <div class="flex items-center gap-2 self-start">
            <span class="inline-flex min-h-7 items-center rounded-sm bg-white/[0.045] px-2 text-xs ring-1 ring-white/[0.07]" :class="dirty ? 'text-amber-200' : 'text-zinc-500'">
              {{ dirty ? '有未保存更改' : '已与设备同步' }}
            </span>
            <Button variant="outline" size="icon" :loading="isRunning('refresh-subs')" aria-label="读取订阅状态" @click="withAction('refresh-subs', () => refreshSubs())">
              <RefreshCw :size="15" />
            </Button>
          </div>
        </div>

        <div v-if="!configured" class="mt-3 grid grid-cols-3 gap-1 rounded-md bg-amber-400/[0.055] p-1 ring-1 ring-amber-300/15" aria-label="首次启用步骤">
          <div v-for="(step, index) in ['粘贴 URL', '看脱敏预览', '保存并启用']" :key="step" class="min-w-0 rounded-[5px] bg-[#0d0e0f] px-2 py-2 text-center">
            <span class="block text-[10px] font-semibold text-amber-200">0{{ index + 1 }}</span>
            <span class="mt-0.5 block text-[10px] leading-4 text-zinc-400 sm:text-xs">{{ step }}</span>
          </div>
        </div>

        <Textarea
          v-model="singBoxText"
          class="mt-4 min-h-44"
          spellcheck="false"
          autocomplete="off"
          placeholder="https://example.com/subscription"
          aria-label="sing-box 订阅 URL，每行一个"
        />

        <Button class="mt-3 w-full lg:hidden" :disabled="!canApply" :loading="isRunning('apply-subscriptions')" @click="applySubscriptions">
          <Save :size="16" />{{ applyLabel }}
        </Button>

        <div class="mt-2 grid grid-cols-2 gap-px rounded-md bg-white/[0.055] p-px text-xs sm:grid-cols-4">
          <span class="rounded-[5px] bg-[#090b0c] px-3 py-2 text-zinc-500">输入 <strong class="text-zinc-200">{{ inputSummary.raw }}</strong></span>
          <span class="rounded-[5px] bg-[#090b0c] px-3 py-2 text-zinc-500">有效 <strong class="text-emerald-200">{{ inputSummary.valid }}</strong></span>
          <span class="rounded-[5px] bg-[#090b0c] px-3 py-2 text-zinc-500">重复 <strong class="text-amber-200">{{ inputSummary.duplicate }}</strong></span>
          <span class="rounded-[5px] bg-[#090b0c] px-3 py-2 text-zinc-500">超限 <strong class="text-rose-200">{{ inputSummary.overLimit }}</strong></span>
        </div>

        <div class="mt-3 rounded-md bg-[#090b0c] p-1 ring-1 ring-white/[0.07]">
          <div class="flex items-start gap-2 rounded-[5px] bg-white/[0.018] px-3 py-2.5">
            <ShieldCheck :size="16" class="mt-0.5 shrink-0 text-cyan-300" />
            <div class="min-w-0">
              <p class="text-sm font-medium text-zinc-200">脱敏预览</p>
              <p class="mt-0.5 text-xs leading-5 text-zinc-600">仅显示 protocol + hostname；path、query、hash 始终隐藏。</p>
            </div>
          </div>
          <div v-if="subscriptionPreview.length" class="mt-1 grid gap-1 sm:grid-cols-2">
            <div v-for="item in subscriptionPreview" :key="item.key" :class="['min-w-0 rounded-[5px] p-3 ring-1', previewTone(item.status)]">
              <div class="flex min-w-0 items-center gap-2 text-xs">
                <span class="shrink-0 text-zinc-600">#{{ item.index }}</span>
                <strong class="min-w-0 truncate">{{ item.label }}</strong>
              </div>
              <p class="mt-1 text-[11px] leading-4 opacity-65">{{ item.notes.join(' · ') }}</p>
            </div>
          </div>
          <p v-else class="px-3 py-4 text-xs text-zinc-600">输入后将在这里显示不含敏感路径的来源摘要。</p>
        </div>

        <div class="mt-4 flex min-w-0 flex-col gap-2 sm:flex-row sm:flex-wrap">
          <Button class="hidden w-full sm:w-auto lg:inline-flex" :disabled="!canApply" :loading="isRunning('apply-subscriptions')" @click="applySubscriptions">
            <Save :size="16" />{{ applyLabel }}
          </Button>
          <Button variant="secondary" class="w-full sm:w-auto" :loading="isRunning('paste-subscriptions')" @click="pasteSubscriptions">
            <ClipboardPaste :size="16" />粘贴
          </Button>
          <Button variant="outline" class="w-full sm:w-auto" :disabled="!singBoxText.trim()" @click="normalizeSubscriptions">规范化</Button>
          <Button variant="outline" class="w-full sm:w-auto" :disabled="!subscriptionPreview.length" @click="copySummary">
            <ShieldCheck :size="16" />{{ summaryCopied ? '摘要已复制' : '复制脱敏摘要' }}
          </Button>
        </div>
      </Card>

      <section class="lifecycle-strip grid min-w-0 gap-px rounded-md bg-white/[0.055] p-px ring-1 ring-white/[0.07] sm:grid-cols-2 lg:hidden" aria-label="订阅生命周期概览">
        <div class="min-w-0 rounded-[5px] bg-[#0b0d0e] px-4 py-3">
          <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Lifecycle</span>
          <div class="mt-2 flex items-center gap-2">
            <span :class="['size-2 rounded-full', lifecycleDotClass, lifecycleStatus === 'running' ? 'motion-safe:animate-pulse' : '']" />
            <strong class="truncate text-sm text-zinc-100">{{ lifecycleLabel }}</strong>
          </div>
        </div>
        <div class="min-w-0 rounded-[5px] bg-[#0b0d0e] px-4 py-3">
          <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Sources / Cache</span>
          <p class="mt-2 text-sm text-zinc-200"><strong class="text-white">{{ state.subscriptions.configuredCount }}</strong> 来源 · <strong class="text-white">{{ state.subscriptions.cacheCount }}</strong> 缓存</p>
        </div>
        <div class="min-w-0 rounded-[5px] bg-[#0b0d0e] px-4 py-3">
          <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Last result</span>
          <p class="mt-2 truncate text-sm text-zinc-200">{{ state.subscriptions.lastResult }} · {{ state.subscriptions.lastPhase }}</p>
        </div>
        <div class="min-w-0 rounded-[5px] bg-[#0b0d0e] px-4 py-3">
          <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Automatic refresh</span>
          <p class="mt-2 text-sm" :class="state.subscriptions.scheduleOwnerValid ? 'text-zinc-200' : 'text-amber-200'">
            {{ state.subscriptions.scheduleEnabled ? `${state.subscriptions.scheduleIntervalHours} 小时` : '关闭' }} · {{ state.subscriptions.scheduleRunning ? 'running' : 'stopped' }}
          </p>
        </div>
      </section>

      <aside class="grid min-w-0 gap-4">
        <Card>
          <div class="flex items-center justify-between gap-3">
            <div>
              <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Lifecycle record</span>
              <h3 class="mt-1 text-base font-semibold text-zinc-100">应用与刷新</h3>
            </div>
            <DownloadCloud :size="18" :class="lifecycleStatus === 'running' ? 'motion-safe:animate-pulse text-cyan-300' : 'text-zinc-600'" />
          </div>

          <dl class="mt-4 grid grid-cols-2 gap-px rounded-md bg-white/[0.055] p-px text-xs">
            <div class="rounded-[5px] bg-[#090b0c] p-3"><dt class="text-zinc-600">阶段</dt><dd class="mt-1 break-words text-zinc-200">{{ state.subscriptions.lastPhase }}</dd></div>
            <div class="rounded-[5px] bg-[#090b0c] p-3"><dt class="text-zinc-600">结果</dt><dd class="mt-1 break-words text-zinc-200">{{ state.subscriptions.lastResult }}</dd></div>
            <div class="rounded-[5px] bg-[#090b0c] p-3"><dt class="text-zinc-600">来源 / 导入</dt><dd class="mt-1 text-zinc-200">{{ state.subscriptions.lastSourceCount }} / {{ state.subscriptions.lastImportedCount }}</dd></div>
            <div class="rounded-[5px] bg-[#090b0c] p-3"><dt class="text-zinc-600">跳过 / 强身份缓存</dt><dd class="mt-1 text-zinc-200">{{ state.subscriptions.lastSkippedCount }} / {{ state.subscriptions.cacheProvenanceCount }}</dd></div>
          </dl>
          <div v-if="lifecycleStatus === 'timeout'" class="mt-3 rounded-md bg-amber-300/[0.055] p-3 text-xs leading-5 text-amber-100 ring-1 ring-amber-300/15">
            WebUI 只停止了日志跟踪，未判定设备侧任务失败。点击上方刷新按钮重新读取订阅阶段；完整过程仍可在“输出”的后台日志中核对。
          </div>
          <div class="mt-3 space-y-1 text-xs leading-5 text-zinc-500">
            <p>尝试：{{ formatEpoch(state.subscriptions.lastAttemptEpoch) }}</p>
            <p>成功：{{ formatEpoch(state.subscriptions.lastSuccessEpoch) }}</p>
            <p class="break-words">原因：{{ state.subscriptions.lastReason }}</p>
            <p class="break-words">缓存来源：{{ state.subscriptions.cacheSource }}</p>
            <p class="truncate" :title="state.subscriptions.lastGenerationId">代次：{{ state.subscriptions.lastGenerationId }}</p>
          </div>
          <Button v-if="configured" variant="outline" class="mt-4 w-full" :loading="isRunning('update-all')" @click="updateAll">
            <RefreshCw :size="16" />立即刷新
          </Button>
        </Card>

        <Card>
          <div class="flex items-start gap-3">
            <Clock3 :size="18" class="mt-0.5 shrink-0 text-zinc-500" />
            <div class="min-w-0">
              <span class="text-[10px] uppercase tracking-[0.17em] text-zinc-600">Automatic refresh</span>
              <h3 class="mt-1 text-base font-semibold text-zinc-100">自动刷新计划</h3>
            </div>
          </div>

          <label class="mt-4 block text-xs font-medium text-zinc-400" for="subscription-schedule">刷新间隔</label>
          <select
            id="subscription-schedule"
            v-model="scheduleValue"
            class="mt-2 min-h-11 w-full rounded-md bg-[#080a0b] px-3 text-sm text-zinc-100 outline-none ring-1 ring-inset ring-white/[0.09] transition-[box-shadow,background-color] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] focus:bg-[#0b0e0f] focus:ring-emerald-300/55"
            @change="scheduleDirty = true"
          >
            <option value="off">关闭</option>
            <option value="12">每 12 小时</option>
            <option value="24">每 24 小时</option>
            <option value="48">每 48 小时</option>
            <option value="72">每 72 小时</option>
          </select>

          <div class="mt-3 rounded-md bg-[#090b0c] p-3 ring-1 ring-white/[0.07]">
            <div class="flex items-center gap-2 text-xs">
              <Check v-if="state.subscriptions.scheduleOwnerValid" :size="15" class="text-emerald-300" />
              <AlertTriangle v-else :size="15" class="text-amber-300" />
              <span :class="state.subscriptions.scheduleOwnerValid ? 'text-zinc-300' : 'text-amber-200'">
                enabled={{ state.subscriptions.scheduleEnabled ? 1 : 0 }} · running={{ state.subscriptions.scheduleRunning ? 1 : 0 }} · owner={{ state.subscriptions.scheduleOwner }}
              </span>
            </div>
            <p class="mt-2 text-xs leading-5 text-zinc-500">{{ scheduleMeaning }}</p>
          </div>

          <Button class="mt-4 w-full" :disabled="!scheduleChanged" :loading="isRunning('save-schedule')" @click="saveSchedule">
            <Clock3 :size="16" />保存自动刷新设置
          </Button>
        </Card>

        <div class="flex items-start gap-3 rounded-md bg-cyan-300/[0.045] p-3 text-xs leading-5 text-zinc-500 ring-1 ring-cyan-300/10">
          <Database :size="16" class="mt-0.5 shrink-0 text-cyan-300" />
          <p>计划只表示刷新节奏，不承诺精确“下次时间”；系统休眠、重启或正在运行的任务都会影响实际触发时刻。</p>
        </div>
      </aside>
    </div>
  </div>
</template>
