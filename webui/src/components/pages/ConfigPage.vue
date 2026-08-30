<script setup lang="ts">
import { Braces, Copy, DownloadCloud, FileUp, Github, ListTree, RefreshCw, Save } from "lucide-vue-next";
import { computed, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import InsightChip from "@/components/ui/InsightChip.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import ConfigCodeEditor from "@/components/ConfigCodeEditor.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";
import { buildConfigAudit, buildConfigOutline, buildUnifiedConfigDiff, MAX_CONFIG_ISSUE_DIFF_BYTES, sanitizeConfigText } from "./configEditorInsights";
import { MAX_LOCAL_CONFIG_BYTES, parseLocalConfigFile } from "./configFileImport";

const { state, loadConfig, saveConfig, syncConfigTemplate, openExternal, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const pendingConfigAction = ref<PendingToolAction | null>(null);
const configFileInput = ref<HTMLInputElement | null>(null);
const localJsonStatus = ref("");
const configSyntaxValid = ref(true);
const configAnalysisPending = ref(false);
const analyzedConfigText = ref("");
const sanitizedCopied = ref(false);
const auditCopied = ref(false);
const issueBaseline = ref("");
const configStats = computed(() => {
  const text = analyzedConfigText.value;
  const lines = text ? text.split(/\r?\n/).length : 0;
  return {
    lines,
    chars: text.length,
    sizeKiB: (new TextEncoder().encode(text).length / 1024).toFixed(1)
  };
});
const configOutline = computed(() => buildConfigOutline(analyzedConfigText.value));
const configAudit = computed(() => buildConfigAudit(analyzedConfigText.value));

function requestConfigAction(action: PendingToolAction): void {
  pendingConfigAction.value = action;
}

function cancelConfigAction(): void {
  pendingConfigAction.value = null;
}

async function confirmConfigAction(): Promise<void> {
  const action = pendingConfigAction.value;
  if (!action) return;
  if (action.key === "save-config" && !configSyntaxValid.value) {
    pendingConfigAction.value = null;
    state.output = "请先修正编辑器中标出的 JSON 语法错误。";
    return;
  }
  try {
    await action.run();
  } finally {
    pendingConfigAction.value = null;
  }
}

function requestSaveConfig(): void {
  if (!configSyntaxValid.value) {
    state.output = "请先修正编辑器中标出的 JSON 语法错误。";
    return;
  }
  requestConfigAction({
    key: "save-config",
    title: "校验并保存配置",
    detail: `会把当前编辑器内容写入 ${state.config.path || "sing-box config.json"}，通过 sing-box check 后覆盖运行配置。`,
    command: `config-editor save-file ${state.config.target} <editor-temp-file>`,
    run: () => withAction("save-config", () => saveConfig()),
  });
}

function updateConfigSyntaxState(syntax: { valid: boolean; checking: boolean }): void {
  configSyntaxValid.value = syntax.valid;
  configAnalysisPending.value = syntax.checking;
  if (!syntax.checking) analyzedConfigText.value = state.config.text;
}

async function loadConfigForEditing(): Promise<void> {
  await loadConfig();
  if (!state.config.dirty && state.config.text) issueBaseline.value = state.config.text;
}

function requestSyncTemplate(): void {
  requestConfigAction({
    key: "sync-template",
    title: "同步上游配置模板",
    detail: "会用上游模板更新当前目标配置，并重新加载编辑器内容。",
    command: `config-editor sync-template ${state.config.target}`,
    run: () => withAction("sync-template", () => syncConfigTemplate()),
  });
}

function formatConfigJson(): void {
  try {
    const parsed = JSON.parse(state.config.text);
    state.config.text = `${JSON.stringify(parsed, null, 2)}\n`;
    state.config.dirty = true;
    localJsonStatus.value = "本地 JSON 格式化完成；保存前仍会执行 sing-box check。";
  } catch (error) {
    localJsonStatus.value = `JSON 语法错误：${error instanceof Error ? error.message : String(error)}`;
  }
}

function chooseLocalConfig(): void {
  configFileInput.value?.click();
}

async function importLocalConfig(event: Event): Promise<void> {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (!file) return;

  try {
    if (file.size > MAX_LOCAL_CONFIG_BYTES) {
      throw new Error("文件超过 4 MiB 限制。");
    }
    const imported = parseLocalConfigFile(file.name, new Uint8Array(await file.arrayBuffer()));
    state.config.text = imported.text;
    state.config.dirty = true;
    state.config.status = `已导入 ${imported.fileName}，尚未保存`;
    state.config.validation = {
      status: "idle",
      summary: "本地 JSON 已导入编辑器，点击“校验并保存”后才会写入运行配置。",
      checkedAt: "",
    };
    configSyntaxValid.value = true;
    localJsonStatus.value = `${imported.fileName} 已导入（${(imported.sizeBytes / 1024).toFixed(1)} KiB），尚未保存。`;
    state.notice = "本地 JSON 已导入编辑器";
    state.output = "导入完成，运行配置没有被修改；请检查内容后点击“校验并保存”。";
  } catch (error) {
    localJsonStatus.value = `导入错误：${error instanceof Error ? error.message : String(error)}`;
    state.output = localJsonStatus.value;
  }
}

async function copySanitizedConfig(): Promise<void> {
  const sanitizedConfig = sanitizeConfigText(state.config.text);
  if (!sanitizedConfig) return;
  sanitizedCopied.value = await copyText(sanitizedConfig);
  state.output = sanitizedCopied.value ? "脱敏配置片段已复制。" : "剪贴板不可用，脱敏配置未复制。";
}

async function copyConfigAudit(): Promise<void> {
  const report = [
    "MagicNet config audit",
    `target=${sanitizeConfigText(state.config.target)}`,
    `path=${sanitizeConfigText(state.config.path)}`,
    `status=${sanitizeConfigText(configAudit.value.status)}`,
    `summary=${sanitizeConfigText(configAudit.value.summary)}`,
    "",
    "[items]",
    ...configAudit.value.items.map((item) => `${sanitizeConfigText(item.label)}=${sanitizeConfigText(item.value)} (${item.tone})`),
    "",
    `[outbound_tags] ${sanitizeConfigText(configAudit.value.outboundTags.join(", ")) || "none"}`
  ].join("\n");
  auditCopied.value = await copyText(report);
  state.output = auditCopied.value ? "配置审计摘要已复制。" : "剪贴板不可用，配置审计摘要未复制。";
}

async function openConfigIssue(): Promise<void> {
  if (!issueBaseline.value) {
    state.output = "请先加载配置，再生成 Diff Issue。";
    return;
  }
  let diff: string;
  try {
    diff = buildUnifiedConfigDiff(issueBaseline.value, state.config.text);
  } catch (error) {
    state.output = `无法生成安全 Diff：${error instanceof Error ? error.message : String(error)}`;
    return;
  }
  if (!diff) {
    state.output = "配置没有可提交的变更。";
    return;
  }
  if (new TextEncoder().encode(diff).length > MAX_CONFIG_ISSUE_DIFF_BYTES) {
    state.output = "安全 Diff 超过 24 KiB，未复制或打开 Issue；请缩小单次配置变更。";
    return;
  }
  const copied = await copyText(`\`\`\`diff\n${diff}\n\`\`\``);
  const body = [
    "## Proposed Change",
    "",
    copied ? "脱敏 unified diff 已复制到剪贴板，请粘贴到此处。" : "剪贴板不可用，请返回 MagicNet 重新复制脱敏 diff。",
    "",
    `Target: ${state.config.target}`,
    "",
    "创建前仍需人工检查，避免提交私有订阅、密钥或节点信息。"
  ].join("\n");
  openExternal(`${REPO}/issues/new?${new URLSearchParams({ title: `配置变更建议：${state.config.target}`, body }).toString()}`, "配置 Diff Issue");
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Validated Editor" title="配置编辑器" description="可直接导入本地 sing-box JSON，无需 URL；订阅链接请到订阅页填写。">
      <div class="flex flex-wrap items-center gap-2">
        <input ref="configFileInput" class="hidden" type="file" accept=".json,application/json" @change="importLocalConfig">
        <Button variant="outline" :loading="isRunning('load-config')" @click="withAction('load-config', loadConfigForEditing)"><RefreshCw :size="17" />{{ isRunning('load-config') ? '加载中' : '加载配置' }}</Button>
        <Button variant="outline" @click="chooseLocalConfig"><FileUp :size="17" />导入本地 JSON</Button>
        <Button variant="outline" :loading="isRunning('sync-template')" @click="requestSyncTemplate"><DownloadCloud :size="17" />{{ isRunning('sync-template') ? '同步中' : '同步上游模板' }}</Button>
        <Button variant="outline" :disabled="!state.config.text" @click="formatConfigJson"><Braces :size="17" />格式化 JSON</Button>
        <Button variant="outline" :disabled="!state.config.text" @click="copySanitizedConfig"><Copy :size="17" />{{ sanitizedCopied ? '已复制脱敏' : '复制脱敏' }}</Button>
        <Button :disabled="!configSyntaxValid" :loading="isRunning('save-config')" @click="requestSaveConfig"><Save :size="17" />{{ isRunning('save-config') ? '校验中' : '校验并保存' }}</Button>
        <Button variant="outline" @click="openConfigIssue"><Github :size="17" />创建 Diff Issue</Button>
      </div>
    </PageHeader>

    <ToolActionConfirmCard
      v-if="pendingConfigAction"
      :action="pendingConfigAction"
      :loading="isRunning(pendingConfigAction.key)"
      @cancel="cancelConfigAction"
      @confirm="confirmConfigAction"
    />

    <Card class="grid gap-3">
      <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm text-[var(--mn-ink-muted)]">
        <span class="h-9 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] px-3 py-2 text-sm text-[var(--mn-ink)]">sing-box</span>
        <input class="h-9 min-w-0 flex-1 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-carrier)] px-3 text-xs text-[var(--mn-ink-soft)]" readonly :value="state.config.path">
        <span class="shrink-0">{{ state.config.status }}</span>
        <span v-if="state.config.dirty" class="shrink-0 rounded bg-[color-mix(in_srgb,var(--mn-oat)_55%,var(--mn-carrier))] px-2 py-1 text-xs text-[var(--mn-warning)]">未保存</span>
      </div>
      <div class="rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 text-sm leading-6 text-[var(--mn-ink-muted)]">
        <p>sing-box 配置文件是 JSON。没有订阅 URL 时可选择自己的本地配置文件；导入只会替换编辑器草稿，点击“校验并保存”并通过 sing-box check 后才会覆盖运行配置。</p>
      </div>
      <div class="grid gap-2 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 sm:grid-cols-[9rem_minmax(0,1fr)]">
        <div>
          <p class="text-xs text-[var(--mn-ink-muted)]">校验状态</p>
          <p
            class="mt-1 inline-flex rounded px-2 py-1 text-xs"
            :class="{
              'bg-[color-mix(in_srgb,var(--mn-cactus)_40%,var(--mn-carrier))] text-[var(--mn-success)]': state.config.validation.status === 'ok',
              'bg-[color-mix(in_srgb,var(--mn-coral)_55%,var(--mn-carrier))] text-[var(--mn-danger)]': state.config.validation.status === 'error',
              'bg-[var(--mn-carrier-deep)] text-[var(--mn-ink-soft)]': state.config.validation.status === 'idle',
            }"
          >
            {{ state.config.validation.status === 'ok' ? '通过' : state.config.validation.status === 'error' ? '失败' : '未校验' }}
          </p>
        </div>
        <div class="min-w-0">
          <p class="text-xs text-[var(--mn-ink-muted)]">最近结果 {{ state.config.validation.checkedAt }}</p>
          <p class="mt-1 break-words text-sm text-[var(--mn-ink-soft)]">{{ state.config.validation.summary }}</p>
        </div>
      </div>
      <div class="grid gap-2 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 text-xs text-[var(--mn-ink-muted)] sm:grid-cols-4">
        <span>{{ configStats.lines }} 行</span>
        <span>{{ configStats.chars }} 字符</span>
        <span>{{ configStats.sizeKiB }} KiB</span>
        <span class="break-words" :class="localJsonStatus.includes('错误') ? 'text-[var(--mn-danger)]' : 'text-[var(--mn-ink-muted)]'">
          {{ configAnalysisPending ? "结构分析中…" : localJsonStatus || "尚未导入或格式化本地 JSON" }}
        </span>
      </div>
      <div class="grid gap-3 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 text-sm text-[var(--mn-ink-muted)]">
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <ListTree :size="16" class="text-[var(--mn-ink-muted)]" />
          <span class="font-medium text-[var(--mn-ink-soft)]">结构摘要</span>
          <span
            class="rounded px-2 py-1 text-xs"
            :class="{
              'bg-[color-mix(in_srgb,var(--mn-cactus)_40%,var(--mn-carrier))] text-[var(--mn-success)]': configOutline.status === 'ok',
              'bg-[color-mix(in_srgb,var(--mn-coral)_55%,var(--mn-carrier))] text-[var(--mn-danger)]': configOutline.status === 'error',
              'bg-[var(--mn-carrier-deep)] text-[var(--mn-ink-soft)]': configOutline.status === 'idle',
            }"
          >
            {{ configOutline.status === 'ok' ? '可解析' : configOutline.status === 'error' ? '需修正' : '待加载' }}
          </span>
          <span class="min-w-0 break-words text-xs text-[var(--mn-ink-muted)]">{{ configOutline.summary }}</span>
        </div>
        <div class="grid gap-2 text-xs text-[var(--mn-ink-muted)] sm:grid-cols-4">
          <span v-for="item in configOutline.counts" :key="item.label" class="rounded border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] px-2 py-1">
            {{ item.label }}: <b class="font-medium text-[var(--mn-ink-soft)]">{{ item.value }}</b>
          </span>
        </div>
        <p class="break-words text-xs text-[var(--mn-ink-muted)]">
          顶层键：{{ configOutline.keys.length ? configOutline.keys.join(", ") : "无" }}
        </p>
      </div>
      <div class="grid gap-3 rounded-md border border-[color-mix(in_srgb,var(--mn-ink)_12%,transparent)] bg-[var(--mn-ivory)] p-3 text-sm text-[var(--mn-ink-muted)]">
        <div class="flex min-w-0 flex-wrap items-center justify-between gap-2">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="font-medium text-[var(--mn-ink-soft)]">运行审计</span>
            <span
              class="rounded px-2 py-1 text-xs"
              :class="{
                'bg-[color-mix(in_srgb,var(--mn-cactus)_40%,var(--mn-carrier))] text-[var(--mn-success)]': configAudit.status === 'ok',
                'bg-[color-mix(in_srgb,var(--mn-oat)_55%,var(--mn-carrier))] text-[var(--mn-warning)]': configAudit.status === 'warning',
                'bg-[color-mix(in_srgb,var(--mn-coral)_55%,var(--mn-carrier))] text-[var(--mn-danger)]': configAudit.status === 'error',
                'bg-[var(--mn-carrier-deep)] text-[var(--mn-ink-soft)]': configAudit.status === 'idle',
              }"
            >
              {{ configAudit.status === 'ok' ? '齐全' : configAudit.status === 'warning' ? '需确认' : configAudit.status === 'error' ? '不可解析' : '待加载' }}
            </span>
            <span class="min-w-0 break-words text-xs text-[var(--mn-ink-muted)]">{{ configAudit.summary }}</span>
          </div>
          <Button variant="outline" :disabled="configAnalysisPending || !configAudit.items.length" @click="copyConfigAudit"><Copy :size="16" />{{ auditCopied ? '已复制审计' : '复制审计' }}</Button>
        </div>
        <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <InsightChip
            v-for="item in configAudit.items"
            :key="item.label"
            :label="item.label"
            :value="item.value"
            :tone="item.tone"
          />
        </div>
        <p class="break-words text-xs text-[var(--mn-ink-muted)]">
          出站 tag：{{ configAudit.outboundTags.length ? configAudit.outboundTags.join(", ") : "无" }}
        </p>
      </div>
      <ConfigCodeEditor
        v-model="state.config.text"
        @syntax-state="updateConfigSyntaxState"
        @update:model-value="state.config.dirty = true"
      />
    </Card>
  </div>
</template>
