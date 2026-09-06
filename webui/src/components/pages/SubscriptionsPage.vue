<script setup lang="ts">
import { t } from "@/i18n";
import {
  ClipboardPaste,
  FileUp,
  RefreshCw,
  Save,
  ShieldCheck,
  ChevronDown,
  Plus,
  Settings2,
} from "lucide-vue-next";
import { computed, nextTick, ref, shallowRef, watch } from "vue";
import Button from "@/components/ui/Button.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import {
  isSubscriptionBackgroundArgs,
  subscriptionLifecycleRunning,
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
import SubscriptionUsageList from "./subscriptions/SubscriptionUsageList.vue";
import { buildSubscriptionUsageOverview } from "@/composables/subscriptionUsage";
import SubscriptionLifecycleRecord from "./subscriptions/SubscriptionLifecycleRecord.vue";
import { pendingSubscriptionDraft, takePendingSubscriptionDraft } from "./subscriptionDraft";

// 默认节点过滤词与提示（清空并保存即可关闭过滤）：
const filterPresets = ["免费", "free", "HK", "香港", "TW", "台湾"] as const;

const {
  state,
  startPrivateBackgroundCli,
  startBackgroundCli,
  stagePrivatePayload,
  removePrivatePayload,
  refreshSubs,
} = useMagicNet();
const { isRunning, withAction } = useActionLock();
const singBoxText = ref("");
const editorOpen = ref(false);
const editorPanel = ref<HTMLElement | null>(null);
const manageSourcesButton = ref<InstanceType<typeof Button> | null>(null);
const actionMessage = ref("");
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
  editorOpen.value = true;
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
const applyLabel = computed(() => configured.value ? t("保存并应用") : t("添加并启用"));
const usageRows = computed(() => buildSubscriptionUsageOverview(state.subscriptions));
const lifecycleRunning = computed(() => subscriptionLifecycleRunning(state.backgroundTask, state.subscriptions.updateRunning));
const sourceCount = computed(() => state.subscriptions.sourceMode === "local" ? 1 : usageRows.value.length);
const lifecycleMessage = computed(() => {
  if (lifecycleRunning.value) return t("正在更新订阅，完成后用量与节点会自动刷新。");
  if (state.backgroundTask.status === "timeout" && isSubscriptionBackgroundArgs(state.backgroundTask.args)) {
    return t("更新仍可能在后台进行，可重新读取状态确认。");
  }
  if (["failed", "interrupted"].includes(state.subscriptions.lastResult)) return t("最近一次更新未完成，当前仍保留原有配置。");
  return "";
});

async function openEditor(): Promise<void> {
  actionMessage.value = "";
  editorOpen.value = true;
  await nextTick();
  editorPanel.value?.scrollIntoView({ block: "nearest" });
  editorPanel.value?.querySelector("textarea")?.focus({ preventScroll: true });
}

async function closeEditor(): Promise<void> {
  const restoreFocus = editorPanel.value?.contains(document.activeElement);
  editorOpen.value = false;
  await nextTick();
  if (restoreFocus) manageSourcesButton.value?.$el.focus({ preventScroll: true });
}

function cancelEditing(): void {
  singBoxText.value = lastLoadedSnapshot.value;
  actionMessage.value = "";
  void closeEditor();
}

function showActionMessage(message: string): void {
  actionMessage.value = message;
  state.output = message;
}

async function updateSubscriptions(): Promise<void> {
  if (!configured.value || lifecycleRunning.value) return;
  await withAction("update-all", () => startBackgroundCli("sub update-all", t("更新订阅"), "", "sub update-all"));
}

watch(() => state.subscriptions.singBoxUrls, (urls) => {
  const snapshot = urls.join("\n");
  const hadPending = pendingApply.value !== null;
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
  if (hadPending && next.pendingApply === null && !next.dirty) void closeEditor();
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

async function stageSubscriptionPayload(snapshot: string) {
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
  const staged = await stagePrivatePayload(
    "subscription",
    `magicnet-webui-${stamp}.b64`,
    `${snapshot}\n`,
    t("订阅私有载荷"),
  );
  if (!staged) {
    showActionMessage(t("订阅准备失败，请重试。当前配置没有改变。"));
    return null;
  }
  return staged;
}

async function applySubscriptions(): Promise<void> {
  if (!canApply.value) return;
  await withAction("apply-subscriptions", async () => {
    actionMessage.value = "";
    if (userAgentCardRef.value?.userAgentChanged && !(await userAgentCardRef.value.persistUserAgent())) {
      showActionMessage(t("请求标识保存失败，请在订阅设置中检查后重试。"));
      return;
    }
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
      configured.value ? t("应用订阅配置") : t("首次启用订阅"),
      launch.preview,
      launch.displayArgs,
      launch.lifecycleArgs,
    );
    if (execFailed(result)) {
      const cleaned = await removePrivatePayload("subscription", staged.basename, t("订阅私有载荷"));
      showActionMessage(cleaned ? t("订阅未能提交，请重试。") : t("订阅未投递，且私有临时数据清理未确认。"));
      if (pendingApply.value === attempt) pendingApply.value = null;
      return;
    }
    showActionMessage(t("已提交订阅。验证通过后生效，可在更新记录中查看结果。"));
  });
}

async function pasteSubscriptions(): Promise<void> {
  await withAction("paste-subscriptions", async () => {
    const text = (await readClipboardText()).trim();
    if (!text) {
      showActionMessage(t("剪贴板为空或不可读取，可以长按输入框粘贴。"));
      return;
    }
    singBoxText.value = text;
    showActionMessage(t("已粘贴 {value} 行，请检查后保存。", { value: text.split(/\r?\n/).filter((line) => line.trim()).length }));
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
    actionMessage.value = "";
    try {
      if (file.size > MAX_LOCAL_SUBSCRIPTION_BYTES) throw new Error(t("文件超过 8 MiB 限制。"));
      const imported = parseLocalSubscriptionFile(
        file.name,
        new Uint8Array(await file.arrayBuffer()),
      );
      const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
      const staged = await stagePrivatePayload(
        "subscription",
        `magicnet-local-${stamp}.txt`,
        imported.text,
        t("本地订阅源"),
        16 * 1024,
      );
      if (!staged) {
        showActionMessage(t("文件准备失败，请重试。当前配置没有改变。"));
        return;
      }
      const launch = buildLocalSubscriptionApplyLaunch(staged.basename);
      const result = await startPrivateBackgroundCli(
        launch.args,
        t("应用本地订阅源"),
        launch.preview,
        launch.displayArgs,
        launch.lifecycleArgs,
      );
      if (execFailed(result)) {
        await removePrivatePayload("subscription", staged.basename, t("本地订阅源"));
        showActionMessage(t("文件未能提交，请重试。"));
        return;
      }
      state.notice = t("本地订阅源已投递");
      showActionMessage(t("已提交 {value} 文件，验证成功后会切换到本地模式。", { value: imported.format }));
    } catch (error) {
      showActionMessage(t("导入错误：{value}", { value: error instanceof Error ? error.message : String(error) }));
    }
  });
}

function normalizeSubscriptions(): void {
  if (savePlan.value.status === "idle" || savePlan.value.status === "error") {
    showActionMessage(savePlan.value.message);
    return;
  }
  singBoxText.value = canonicalDraft.value;
  showActionMessage(t("已整理为 {value} 个订阅来源。", { value: savePlan.value.lines.length }));
}

async function copySummary(): Promise<void> {
  summaryCopied.value = await copyText(formatSubscriptionSummary(singBoxText.value, subscriptionPreview.value));
  showActionMessage(summaryCopied.value ? t("来源摘要已复制。") : t("剪贴板不可用，来源摘要未复制。"));
}
</script>

<template>
  <div class="subscriptions-page">
    <PageHeader :title="t('订阅')">
      <template #actions>
        <Button v-if="configured" ref="manageSourcesButton" variant="outline" :aria-expanded="editorOpen" aria-controls="subscription-editor" @click="openEditor">
          <Plus :size="16" />{{ t("管理来源") }} </Button>
        <Button v-if="configured" :loading="lifecycleRunning || isRunning('update-all')" :disabled="state.busy" @click="updateSubscriptions">
          <RefreshCw :size="16" />{{ t("更新订阅") }} </Button>
      </template>
    </PageHeader>

    <div v-if="configured" class="subscription-summary">
      <span>{{ t("{value} 个来源", { value: sourceCount }) }}<span v-if="state.subscriptions.lastImportedCount > 0"> {{ t("· {value} 个节点", { value: state.subscriptions.lastImportedCount }) }}</span></span>
      <span v-if="dirty" class="unsaved-note">{{ t("有未保存的更改") }}</span>
      <Button variant="ghost" size="icon" :loading="isRunning('refresh-subs')" :aria-label="t('重新读取订阅状态')" @click="withAction('refresh-subs', () => refreshSubs())">
        <RefreshCw :size="15" />
      </Button>
    </div>

    <p v-if="lifecycleMessage" class="subscription-feedback" role="status" :data-error="!lifecycleRunning">
      {{ lifecycleMessage }}
    </p>
    <p v-if="actionMessage" class="subscription-feedback" role="status">{{ actionMessage }}</p>

    <SubscriptionUsageList v-if="configured" :rows="usageRows" :local="state.subscriptions.sourceMode === 'local'" />
    <p v-if="configured && state.subscriptions.sourceMode !== 'local'" class="usage-footnote">{{ t("用量与到期时间由服务商提供，更新订阅时同步。") }}</p>

    <section v-if="editorOpen || !configured" id="subscription-editor" ref="editorPanel" class="source-editor" :aria-label="t('编辑订阅来源')">
      <div class="editor-heading">
        <div>
          <h3>{{ configured ? t("管理订阅来源") : t("添加第一个订阅") }}</h3>
          <p>{{ t("粘贴订阅链接，每行一个，最多 5 个。也可导入本地文件。") }}</p>
        </div>
      </div>
      <Textarea
        v-model="singBoxText"
        class="source-textarea"
        spellcheck="false"
        autocomplete="off"
        autocapitalize="none"
        autocorrect="off"
        inputmode="url"
        placeholder="https://example.com/subscription"
        :aria-label="t('sing-box 订阅 URL，每行一个')"
        aria-describedby="subscription-validation"
      />
      <div id="subscription-validation" class="editor-validation" role="status" :data-error="savePlan.status === 'error'">
        <span>{{ savePlan.status === 'idle' ? t("支持 HTTPS 订阅链接") : savePlan.message }}</span>
        <span v-if="inputSummary.duplicate || inputSummary.overLimit">{{ t("有效 {value} · 重复 {value2} · 超限 {value3}", { value: inputSummary.valid, value2: inputSummary.duplicate, value3: inputSummary.overLimit }) }}</span>
      </div>
      <div class="editor-actions">
        <input ref="subscriptionFileInput" class="hidden" type="file" accept=".yaml,.yml,.txt,.list,.conf,application/yaml,text/yaml,text/plain" @change="importLocalSubscriptions">
        <div class="source-import-actions">
          <Button variant="outline" :loading="isRunning('paste-subscriptions')" @click="pasteSubscriptions"><ClipboardPaste :size="16" />{{ t("粘贴链接") }}</Button>
          <Button variant="outline" :loading="isRunning('apply-local-subscription')" :disabled="lifecycleRunning" @click="chooseLocalSubscriptions"><FileUp :size="16" />{{ t("导入文件") }}</Button>
        </div>
        <div class="source-save-actions">
          <Button v-if="configured" variant="ghost" :disabled="lifecycleRunning" @click="cancelEditing">{{ t("取消") }}</Button>
          <Button :disabled="!canApply || lifecycleRunning" :loading="isRunning('apply-subscriptions')" @click="applySubscriptions"><Save :size="16" />{{ applyLabel }}</Button>
        </div>
      </div>
      <details v-if="subscriptionPreview.length" class="source-preview">
        <summary>{{ t("检查来源") }} <ChevronDown :size="15" /></summary>
        <ul>
          <li v-for="item in subscriptionPreview" :key="item.key" :data-invalid="item.status === 'invalid' || item.status === 'over-limit'">
            <span>{{ item.index }}.</span><strong>{{ item.label }}</strong>
            <span>{{ item.status === 'ok' ? t("有效") : item.status === 'duplicate' ? t("重复") : item.status === 'over-limit' ? t("超出数量限制") : t("请检查链接") }}</span>
          </li>
        </ul>
        <div class="preview-actions">
          <Button variant="ghost" :disabled="!singBoxText.trim()" @click="normalizeSubscriptions">{{ t("去重并整理") }}</Button>
          <Button variant="ghost" @click="copySummary"><ShieldCheck :size="15" />{{ summaryCopied ? t("已复制") : t("复制来源摘要") }}</Button>
        </div>
      </details>
    </section>

    <div class="subscription-settings">
      <details class="settings-section">
        <summary><span><RefreshCw :size="17" />{{ t("更新记录") }}</span><ChevronDown :size="17" /></summary>
        <SubscriptionLifecycleRecord :configured="configured" />
      </details>
      <details class="settings-section">
        <summary><span><Settings2 :size="17" />{{ t("订阅设置") }}</span><ChevronDown :size="17" /></summary>
        <div class="subscription-settings-content">
          <SubscriptionScheduleCard />
          <SubscriptionFilterCard :configured="configured" />
          <SubscriptionUserAgentCard ref="userAgentCardRef" :configured="configured" />
        </div>
      </details>
    </div>
  </div>
</template>

<style scoped>
.subscriptions-page { width: 100%; max-width: 880px; min-width: 0; margin: 0 auto; }
.subscription-summary { display: flex; align-items: center; gap: 12px; margin: 8px 0 14px; color: var(--mn-ink-muted); font-size: .875rem; }
.subscription-summary > :last-child { margin-left: auto; }
.unsaved-note { color: var(--mn-warning); }
.subscription-feedback { margin: 16px 0; border-left: 2px solid var(--mn-info); padding: 10px 14px; color: var(--mn-ink-soft); background: var(--mn-surface-sunken); font-size: .875rem; line-height: 1.65; }
.subscription-feedback[data-error="true"] { border-left-color: var(--mn-warning); }
.usage-footnote { margin: 0 0 28px; color: var(--mn-ink-muted); font-size: .8125rem; line-height: 1.6; }
.source-editor { margin: 24px 0; padding: 24px 0; border-top: 1px solid var(--mn-border); scroll-margin-top: 120px; }
.editor-heading h3 { margin: 0; font-size: 1rem; font-weight: 600; }
.editor-heading p { margin: 8px 0 0; color: var(--mn-ink-muted); font-size: .875rem; line-height: 1.65; }
.source-textarea { margin-top: 20px; min-height: 144px; font-size: max(16px, .875rem); line-height: 1.7; overflow-wrap: anywhere; }
.editor-validation { display: flex; flex-wrap: wrap; gap: 6px 16px; margin: 10px 0 18px; color: var(--mn-ink-muted); font-size: .8125rem; }
.editor-validation[data-error="true"] { color: var(--mn-danger); }
.editor-actions, .source-import-actions, .source-save-actions, .preview-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.editor-actions { justify-content: space-between; }
.source-preview { margin-top: 18px; padding-top: 10px; border-top: 1px solid var(--mn-border); }
.source-preview summary, .settings-section > summary { min-height: 48px; display: flex; align-items: center; justify-content: space-between; gap: 12px; cursor: pointer; list-style: none; font-size: .875rem; color: var(--mn-ink-soft); }
summary::-webkit-details-marker { display: none; }
summary:focus-visible { outline: 2px solid var(--mn-focus); outline-offset: 4px; border-radius: 2px; }
details[open] > summary > svg:last-child { transform: rotate(180deg); }
.source-preview ul { margin: 10px 0; padding: 0; list-style: none; }
.source-preview li { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 10px; padding: 8px 0; color: var(--mn-ink-muted); font-size: .8125rem; }
.source-preview li strong { font-weight: 500; color: var(--mn-ink-soft); overflow-wrap: anywhere; }
.source-preview li[data-invalid="true"] { color: var(--mn-danger); }
.subscription-settings { margin-top: 28px; }
.settings-section { border-top: 1px solid var(--mn-border); }
.settings-section > summary { min-height: 62px; font-size: .9375rem; font-weight: 500; }
.settings-section > summary > span { display: inline-flex; align-items: center; gap: 12px; }
.settings-section > summary > svg { color: var(--mn-ink-muted); }
.subscription-settings-content { display: grid; gap: 16px; padding-bottom: 20px; }
@media (max-width: 600px) {
  .source-editor { padding: 24px 0; }
  .source-save-actions { order: -1; }
  .editor-actions { align-items: stretch; gap: 16px; }
  .source-import-actions, .source-save-actions { width: 100%; }
  .source-import-actions > *, .source-save-actions > :last-child { flex: 1; }
  .subscription-summary { flex-wrap: wrap; gap: 6px; }
}
</style>
