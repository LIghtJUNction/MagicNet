<script setup lang="ts">
import { Braces, Copy, DownloadCloud, Github, ListTree, RefreshCw, Save } from "lucide-vue-next";
import { computed, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";
import { buildConfigAudit, buildConfigOutline, sanitizeConfigText } from "./configEditorInsights";

const { state, loadConfig, saveConfig, syncConfigTemplate, openExternal, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const pendingConfigAction = ref<PendingToolAction | null>(null);
const localJsonStatus = ref("");
const sanitizedCopied = ref(false);
const auditCopied = ref(false);
const configStats = computed(() => {
  const text = state.config.text;
  const lines = text ? text.split(/\r?\n/).length : 0;
  return {
    lines,
    chars: text.length,
    sizeKiB: (new TextEncoder().encode(text).length / 1024).toFixed(1)
  };
});
const sanitizedConfig = computed(() => sanitizeConfigText(state.config.text));
const configOutline = computed(() => buildConfigOutline(state.config.text));
const configAudit = computed(() => buildConfigAudit(state.config.text));

function requestConfigAction(action: PendingToolAction): void {
  pendingConfigAction.value = action;
}

function cancelConfigAction(): void {
  pendingConfigAction.value = null;
}

async function confirmConfigAction(): Promise<void> {
  const action = pendingConfigAction.value;
  if (!action) return;
  try {
    await action.run();
  } finally {
    pendingConfigAction.value = null;
  }
}

function requestSaveConfig(): void {
  requestConfigAction({
    key: "save-config",
    title: "校验并保存配置",
    detail: `会把当前编辑器内容写入 ${state.config.path || "sing-box config.json"}，通过 sing-box check 后覆盖运行配置。`,
    command: `config-editor save-file ${state.config.target} <editor-temp-file>`,
    run: () => withAction("save-config", () => saveConfig()),
  });
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

async function copySanitizedConfig(): Promise<void> {
  if (!sanitizedConfig.value) return;
  sanitizedCopied.value = await copyText(sanitizedConfig.value);
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

function issueUrl(): string {
  const body = [
    "已尝试过滤 URL、token、secret、password 等敏感字段；创建前仍需人工检查，避免提交私有订阅或密钥。",
    "",
    "## Target",
    state.config.target,
    "",
    "## Sanitized Config",
    "```",
    sanitizedConfig.value.slice(0, 12000),
    "```"
  ].join("\n");
  return `${REPO}/issues/new?${new URLSearchParams({ title: `配置变更建议：${state.config.target}`, body }).toString()}`;
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Validated Editor" title="配置编辑器" description="高级配置入口：编辑 sing-box config.json；订阅链接请到订阅页填写。">
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="outline" :loading="isRunning('load-config')" @click="withAction('load-config', () => loadConfig())"><RefreshCw :size="17" />{{ isRunning('load-config') ? '加载中' : '加载配置' }}</Button>
        <Button variant="outline" :loading="isRunning('sync-template')" @click="requestSyncTemplate"><DownloadCloud :size="17" />{{ isRunning('sync-template') ? '同步中' : '同步上游模板' }}</Button>
        <Button variant="outline" :disabled="!state.config.text" @click="formatConfigJson"><Braces :size="17" />格式化 JSON</Button>
        <Button variant="outline" :disabled="!state.config.text" @click="copySanitizedConfig"><Copy :size="17" />{{ sanitizedCopied ? '已复制脱敏' : '复制脱敏' }}</Button>
        <Button :loading="isRunning('save-config')" @click="requestSaveConfig"><Save :size="17" />{{ isRunning('save-config') ? '校验中' : '校验并保存' }}</Button>
        <Button variant="outline" @click="openExternal(issueUrl(), '配置 Diff Issue')"><Github :size="17" />创建 Diff Issue</Button>
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
      <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm text-zinc-400">
        <span class="h-9 rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 text-sm text-zinc-100">sing-box</span>
        <input class="h-9 min-w-0 flex-1 rounded-md border border-zinc-800 bg-zinc-900 px-3 text-xs text-zinc-300" readonly :value="state.config.path">
        <span class="shrink-0">{{ state.config.status }}</span>
        <span v-if="state.config.dirty" class="shrink-0 rounded bg-amber-500/15 px-2 py-1 text-xs text-amber-200">未保存</span>
      </div>
      <div class="rounded-md border border-zinc-800 bg-zinc-950 p-3 text-sm leading-6 text-zinc-400">
        <p>sing-box 配置文件是 JSON。点击“加载配置”读取真实文件，修改后点“校验并保存”，会先执行 sing-box check，通过后才覆盖。</p>
      </div>
      <div class="grid gap-2 rounded-md border border-zinc-800 bg-zinc-950 p-3 sm:grid-cols-[9rem_minmax(0,1fr)]">
        <div>
          <p class="text-xs text-zinc-500">校验状态</p>
          <p
            class="mt-1 inline-flex rounded px-2 py-1 text-xs"
            :class="{
              'bg-emerald-500/15 text-emerald-200': state.config.validation.status === 'ok',
              'bg-red-500/15 text-red-200': state.config.validation.status === 'error',
              'bg-zinc-800 text-zinc-300': state.config.validation.status === 'idle',
            }"
          >
            {{ state.config.validation.status === 'ok' ? '通过' : state.config.validation.status === 'error' ? '失败' : '未校验' }}
          </p>
        </div>
        <div class="min-w-0">
          <p class="text-xs text-zinc-500">最近结果 {{ state.config.validation.checkedAt }}</p>
          <p class="mt-1 break-words text-sm text-zinc-300">{{ state.config.validation.summary }}</p>
        </div>
      </div>
      <div class="grid gap-2 rounded-md border border-zinc-800 bg-zinc-950 p-3 text-xs text-zinc-500 sm:grid-cols-4">
        <span>{{ configStats.lines }} 行</span>
        <span>{{ configStats.chars }} 字符</span>
        <span>{{ configStats.sizeKiB }} KiB</span>
        <span class="break-words" :class="localJsonStatus.includes('错误') ? 'text-red-300' : 'text-zinc-400'">{{ localJsonStatus || "尚未执行本地格式化" }}</span>
      </div>
      <div class="grid gap-3 rounded-md border border-zinc-800 bg-zinc-950 p-3 text-sm text-zinc-400">
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <ListTree :size="16" class="text-zinc-500" />
          <span class="font-medium text-zinc-200">结构摘要</span>
          <span
            class="rounded px-2 py-1 text-xs"
            :class="{
              'bg-emerald-500/15 text-emerald-200': configOutline.status === 'ok',
              'bg-red-500/15 text-red-200': configOutline.status === 'error',
              'bg-zinc-800 text-zinc-300': configOutline.status === 'idle',
            }"
          >
            {{ configOutline.status === 'ok' ? '可解析' : configOutline.status === 'error' ? '需修正' : '待加载' }}
          </span>
          <span class="min-w-0 break-words text-xs text-zinc-500">{{ configOutline.summary }}</span>
        </div>
        <div class="grid gap-2 text-xs text-zinc-500 sm:grid-cols-4">
          <span v-for="item in configOutline.counts" :key="item.label" class="rounded border border-zinc-800 px-2 py-1">
            {{ item.label }}: <b class="font-medium text-zinc-300">{{ item.value }}</b>
          </span>
        </div>
        <p class="break-words text-xs text-zinc-500">
          顶层键：{{ configOutline.keys.length ? configOutline.keys.join(", ") : "无" }}
        </p>
      </div>
      <div class="grid gap-3 rounded-md border border-zinc-800 bg-zinc-950 p-3 text-sm text-zinc-400">
        <div class="flex min-w-0 flex-wrap items-center justify-between gap-2">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="font-medium text-zinc-200">运行审计</span>
            <span
              class="rounded px-2 py-1 text-xs"
              :class="{
                'bg-emerald-500/15 text-emerald-200': configAudit.status === 'ok',
                'bg-amber-500/15 text-amber-200': configAudit.status === 'warning',
                'bg-red-500/15 text-red-200': configAudit.status === 'error',
                'bg-zinc-800 text-zinc-300': configAudit.status === 'idle',
              }"
            >
              {{ configAudit.status === 'ok' ? '齐全' : configAudit.status === 'warning' ? '需确认' : configAudit.status === 'error' ? '不可解析' : '待加载' }}
            </span>
            <span class="min-w-0 break-words text-xs text-zinc-500">{{ configAudit.summary }}</span>
          </div>
          <Button variant="outline" :disabled="!configAudit.items.length" @click="copyConfigAudit"><Copy :size="16" />{{ auditCopied ? '已复制审计' : '复制审计' }}</Button>
        </div>
        <div class="grid gap-2 text-xs sm:grid-cols-2 lg:grid-cols-4">
          <span
            v-for="item in configAudit.items"
            :key="item.label"
            class="rounded border px-2 py-1"
            :class="{
              'border-emerald-500/30 text-emerald-200': item.tone === 'success',
              'border-amber-500/30 text-amber-200': item.tone === 'warning',
              'border-red-500/30 text-red-200': item.tone === 'danger',
              'border-zinc-800 text-zinc-400': item.tone === 'neutral',
            }"
          >
            {{ item.label }}: <b class="font-medium">{{ item.value }}</b>
          </span>
        </div>
        <p class="break-words text-xs text-zinc-500">
          出站 tag：{{ configAudit.outboundTags.length ? configAudit.outboundTags.join(", ") : "无" }}
        </p>
      </div>
      <Textarea
        v-model="state.config.text"
        class="min-h-[58vh] overflow-auto whitespace-pre text-sm leading-6"
        spellcheck="false"
        placeholder="点击加载配置读取真实文件"
        @input="state.config.dirty = true"
      />
    </Card>
  </div>
</template>
