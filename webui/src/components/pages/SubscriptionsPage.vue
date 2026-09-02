<script setup lang="ts">
import {
  ClipboardPaste,
  FileUp,
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
} from "@/composables/backgroundTasks";
import {
  copyText,
  execFailed,
  readClipboardText,
} from "@/utils";
import {
  buildSubscriptionPreview,
  buildSubscriptionApplyLaunch,
  buildSubscriptionSavePlan,
  formatSubscriptionSummary,
  reconcileSubscriptionEditor,
  summarizeSubscriptionInput,
  type PendingSubscriptionApply,
  type SubscriptionPreview,
} from "./subscriptionPreview";
import {
  MAX_LOCAL_SUBSCRIPTION_BYTES,
  buildLocalSubscriptionApplyLaunch,
  parseLocalSubscriptionFile,
} from "./localSubscriptionFile";
import SubscriptionFilterCard from "./subscriptions/SubscriptionFilterCard.vue";
import SubscriptionUserAgentCard from "./subscriptions/SubscriptionUserAgentCard.vue";
import SubscriptionScheduleCard from "./subscriptions/SubscriptionScheduleCard.vue";
import SubscriptionLifecycleStrip from "./subscriptions/SubscriptionLifecycleStrip.vue";
import SubscriptionLifecycleRecord from "./subscriptions/SubscriptionLifecycleRecord.vue";
import { pendingSubscriptionDraft, takePendingSubscriptionDraft } from "./subscriptionDraft";

// 默认节点过滤词与提示（清空并保存即可关闭过滤）：
const filterPresets = ["免费", "free", "HK", "香港", "TW", "台湾"] as const;

const {
  state,
  startPrivateBackgroundCli,
  stagePrivatePayload,
  removePrivatePayload,
  refreshSubs,
} = useMagicNet();
const { isRunning, withAction } = useActionLock();
const singBoxText = ref("");
const lastLoadedSnapshot = ref("");
const dirty = ref(false);
const loadedOnce = ref(false);
const syncingEditor = ref(false);
const editRevision = ref(0);
const pendingApply = shallowRef<PendingSubscriptionApply | null>(null);
const summaryCopied = ref(false);
const subscriptionFileInput = ref<HTMLInputElement | null>(null);
const userAgentCardRef = ref<InstanceType<typeof SubscriptionUserAgentCard> | null>(null);

function acceptOnboardingDraft(value: string | null): void {
  if (value === null) return;
  singBoxText.value = value;
  dirty.value = true;
  loadedOnce.value = true;
}

acceptOnboardingDraft(takePendingSubscriptionDraft());
watch(pendingSubscriptionDraft, (value) => {
  if (value === null) return;
  acceptOnboardingDraft(takePendingSubscriptionDraft());
});

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

watch(() => state.backgroundTask.status, async (status) => {
  if (!isSubscriptionBackgroundArgs(state.backgroundTask.args)) return;
  if (status === "done") await refreshSubs(true);
  if (status === "error") pendingApply.value = null;
});

function previewTone(status: SubscriptionPreview["status"]): string {
  if (status === "ok") return "bg-[color-mix(in_srgb,var(--mn-cactus)_30%,var(--mn-carrier))] text-[var(--mn-success)] ring-[color-mix(in_srgb,var(--mn-cactus)_45%,transparent)]";
  if (status === "duplicate") return "bg-[color-mix(in_srgb,var(--mn-oat)_40%,var(--mn-carrier))] text-[var(--mn-warning)] ring-[color-mix(in_srgb,var(--mn-oat)_50%,transparent)]";
  return "bg-[color-mix(in_srgb,var(--mn-coral)_45%,var(--mn-carrier))] text-[var(--mn-danger)] ring-[color-mix(in_srgb,var(--mn-coral)_50%,transparent)]";
}

async function stageSubscriptionPayload(snapshot: string) {
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
  const staged = await stagePrivatePayload(
    "subscription",
    `magicnet-webui-${stamp}.b64`,
    `${snapshot}\n`,
    "订阅私有载荷",
  );
  if (!staged) {
    state.output = "订阅私有载荷准备失败，订阅没有提交。";
    return null;
  }
  return staged;
}

async function applySubscriptions(): Promise<void> {
  if (!canApply.value) return;
  await withAction("apply-subscriptions", async () => {
    if (userAgentCardRef.value?.userAgentChanged && !(await userAgentCardRef.value.persistUserAgent())) return;
    const snapshot = canonicalDraft.value;
    if (singBoxText.value !== snapshot) {
      syncingEditor.value = true;
      singBoxText.value = snapshot;
      syncingEditor.value = false;
    }
    const attempt = { snapshot, revision: editRevision.value };
    pendingApply.value = attempt;
    const staged = await stageSubscriptionPayload(snapshot);
    if (!staged) {
      if (pendingApply.value === attempt) pendingApply.value = null;
      return;
    }
    const launch = buildSubscriptionApplyLaunch(staged.basename);
    const result = await startPrivateBackgroundCli(
      launch.args,
      configured.value ? "应用订阅配置" : "首次启用订阅",
      launch.preview,
      launch.displayArgs,
      launch.lifecycleArgs,
    );
    if (execFailed(result)) {
      const cleaned = await removePrivatePayload("subscription", staged.basename, "订阅私有载荷");
      if (!cleaned) state.output = "订阅未投递，且私有临时数据清理未确认。";
      if (pendingApply.value === attempt) pendingApply.value = null;
      return;
    }
    state.output = "订阅已投递到后台。成功后 URL 会保存在设备本地订阅配置；设备侧私有载荷只用于本次提交，并由受控命令清理。";
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

function chooseLocalSubscriptions(): void {
  subscriptionFileInput.value?.click();
}

async function importLocalSubscriptions(event: Event): Promise<void> {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (!file) return;

  await withAction("apply-local-subscription", async () => {
    try {
      if (file.size > MAX_LOCAL_SUBSCRIPTION_BYTES) throw new Error("文件超过 8 MiB 限制。");
      const imported = parseLocalSubscriptionFile(
        file.name,
        new Uint8Array(await file.arrayBuffer()),
      );
      const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
      const staged = await stagePrivatePayload(
        "subscription",
        `magicnet-local-${stamp}.txt`,
        imported.text,
        "本地订阅源",
        16 * 1024,
      );
      if (!staged) {
        state.output = "本地订阅源准备失败，当前配置没有改变。";
        return;
      }
      const launch = buildLocalSubscriptionApplyLaunch(staged.basename);
      const result = await startPrivateBackgroundCli(
        launch.args,
        "应用本地订阅源",
        launch.preview,
        launch.displayArgs,
        launch.lifecycleArgs,
      );
      if (execFailed(result)) {
        await removePrivatePayload("subscription", staged.basename, "本地订阅源");
        return;
      }
      state.notice = "本地订阅源已投递";
      state.output = `已安全投递 ${imported.format} 格式本地订阅源；验证成功后会切换到本地模式。`;
    } catch (error) {
      state.output = `导入错误：${error instanceof Error ? error.message : String(error)}`;
    }
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
</script>

<template>
  <div class="grid min-w-0 gap-4">
    <PageHeader
      overline="Subscription lifecycle"
      title="订阅生命周期"
      description="添加订阅链接或本地文件。验证失败不会替换现有配置。"
    />

    <section class="lifecycle-strip hidden min-w-0 gap-px rounded-md bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] p-px ring-1 ring-[color-mix(in_srgb,var(--mn-ink)_10%,transparent)] lg:grid lg:grid-cols-4" aria-label="订阅生命周期概览">
      <SubscriptionLifecycleStrip :configured="configured" />
    </section>

    <div class="grid min-w-0 gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(280px,1fr)] lg:items-start">
      <Card class="min-w-0">
        <div class="flex min-w-0 flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <span class="text-[10px] uppercase tracking-[0.17em] text-[var(--mn-ink-faint)]">Secure source editor</span>
            <h3 class="mt-1 text-lg font-semibold tracking-[-0.02em] text-[var(--mn-ink)]">sing-box 订阅来源</h3>
            <p class="mt-1 text-sm leading-6 text-[var(--mn-ink-muted)]">URL 最多 5 个，一行一个；也可直接导入 Clash YAML、base64 或分享链接文件。失败时保留当前有效配置。</p>
          </div>
          <div class="flex items-center gap-2 self-start">
            <span class="inline-flex min-h-7 items-center rounded-sm bg-[color-mix(in_srgb,var(--mn-ink)_5%,transparent)] px-2 text-xs ring-1 ring-[color-mix(in_srgb,var(--mn-ink)_10%,transparent)]" :class="dirty ? 'text-[var(--mn-warning)]' : 'text-[var(--mn-ink-muted)]'">
              {{ dirty ? '有未保存更改' : '已与设备同步' }}
            </span>
            <Button variant="outline" size="icon" :loading="isRunning('refresh-subs')" aria-label="读取订阅状态" @click="withAction('refresh-subs', () => refreshSubs())">
              <RefreshCw :size="15" />
            </Button>
          </div>
        </div>

        <div v-if="!configured" class="mt-3 grid grid-cols-3 gap-1 rounded-md bg-[color-mix(in_srgb,var(--mn-oat)_35%,var(--mn-carrier))] p-1 ring-1 ring-[color-mix(in_srgb,var(--mn-oat)_45%,transparent)]" aria-label="首次启用步骤">
          <div v-for="(step, index) in ['粘贴 URL', '看脱敏预览', '保存并启用']" :key="step" class="min-w-0 rounded-[5px] bg-[var(--mn-ivory)] px-2 py-2 text-center">
            <span class="block text-[10px] font-semibold text-[var(--mn-warning)]">0{{ index + 1 }}</span>
            <span class="mt-0.5 block text-[10px] leading-4 text-[var(--mn-ink-muted)] sm:text-xs">{{ step }}</span>
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

        <div class="mt-2 grid grid-cols-2 gap-px rounded-md bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] p-px text-xs sm:grid-cols-4">
          <span class="rounded-[5px] bg-[var(--mn-ivory)] px-3 py-2 text-[var(--mn-ink-muted)]">输入 <strong class="text-[var(--mn-ink-soft)]">{{ inputSummary.raw }}</strong></span>
          <span class="rounded-[5px] bg-[var(--mn-ivory)] px-3 py-2 text-[var(--mn-ink-muted)]">有效 <strong class="text-[var(--mn-success)]">{{ inputSummary.valid }}</strong></span>
          <span class="rounded-[5px] bg-[var(--mn-ivory)] px-3 py-2 text-[var(--mn-ink-muted)]">重复 <strong class="text-[var(--mn-warning)]">{{ inputSummary.duplicate }}</strong></span>
          <span class="rounded-[5px] bg-[var(--mn-ivory)] px-3 py-2 text-[var(--mn-ink-muted)]">超限 <strong class="text-[var(--mn-danger)]">{{ inputSummary.overLimit }}</strong></span>
        </div>

        <div class="mt-3 rounded-md bg-[var(--mn-ivory)] p-1 ring-1 ring-[color-mix(in_srgb,var(--mn-ink)_10%,transparent)]">
          <div class="flex items-start gap-2 rounded-[5px] bg-[color-mix(in_srgb,var(--mn-ink)_3%,transparent)] px-3 py-2.5">
            <ShieldCheck :size="16" class="mt-0.5 shrink-0 text-[var(--mn-info)]" />
            <div class="min-w-0">
              <p class="text-sm font-medium text-[var(--mn-ink-soft)]">脱敏预览</p>
              <p class="mt-0.5 text-xs leading-5 text-[var(--mn-ink-faint)]">仅显示 protocol + hostname；path、query、hash 始终隐藏。</p>
            </div>
          </div>
          <div v-if="subscriptionPreview.length" class="mt-1 grid gap-1 sm:grid-cols-2">
            <div v-for="item in subscriptionPreview" :key="item.key" :class="['min-w-0 rounded-[5px] p-3 ring-1', previewTone(item.status)]">
              <div class="flex min-w-0 items-center gap-2 text-xs">
                <span class="shrink-0 text-[var(--mn-ink-faint)]">#{{ item.index }}</span>
                <strong class="min-w-0 truncate">{{ item.label }}</strong>
              </div>
              <p class="mt-1 text-[11px] leading-4 opacity-65">{{ item.notes.join(' · ') }}</p>
            </div>
          </div>
          <p v-else class="px-3 py-4 text-xs text-[var(--mn-ink-faint)]">输入后将在这里显示不含敏感路径的来源摘要。</p>
        </div>

        <div class="mt-4 flex min-w-0 flex-col gap-2 sm:flex-row sm:flex-wrap">
          <input
            ref="subscriptionFileInput"
            class="hidden"
            type="file"
            accept=".yaml,.yml,.txt,.list,.conf,application/yaml,text/yaml,text/plain"
            @change="importLocalSubscriptions"
          >
          <Button class="hidden w-full sm:w-auto lg:inline-flex" :disabled="!canApply" :loading="isRunning('apply-subscriptions')" @click="applySubscriptions">
            <Save :size="16" />{{ applyLabel }}
          </Button>
          <Button variant="secondary" class="w-full sm:w-auto" :loading="isRunning('paste-subscriptions')" @click="pasteSubscriptions">
            <ClipboardPaste :size="16" />粘贴
          </Button>
          <Button variant="secondary" class="w-full sm:w-auto" :loading="isRunning('apply-local-subscription')" @click="chooseLocalSubscriptions">
            <FileUp :size="16" />导入本地文件
          </Button>
          <Button variant="outline" class="w-full sm:w-auto" :disabled="!singBoxText.trim()" @click="normalizeSubscriptions">规范化</Button>
          <Button variant="outline" class="w-full sm:w-auto" :disabled="!subscriptionPreview.length" @click="copySummary">
            <ShieldCheck :size="16" />{{ summaryCopied ? '摘要已复制' : '复制脱敏摘要' }}
          </Button>
        </div>
      </Card>

      <section class="lifecycle-strip grid min-w-0 gap-px rounded-md bg-[color-mix(in_srgb,var(--mn-ink)_6%,transparent)] p-px ring-1 ring-[color-mix(in_srgb,var(--mn-ink)_10%,transparent)] sm:grid-cols-2 lg:hidden" aria-label="订阅生命周期概览">
        <SubscriptionLifecycleStrip :configured="configured" />
      </section>

      <aside class="grid min-w-0 gap-4">
        <SubscriptionLifecycleRecord :configured="configured" />
        <SubscriptionFilterCard :configured="configured" />
        <SubscriptionUserAgentCard ref="userAgentCardRef" :configured="configured" />
        <SubscriptionScheduleCard />
      </aside>
    </div>
  </div>
</template>
