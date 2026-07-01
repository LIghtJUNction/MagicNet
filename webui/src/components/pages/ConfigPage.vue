<script setup lang="ts">
import { Braces, DownloadCloud, Github, RefreshCw, Save } from "lucide-vue-next";
import { computed, ref } from "vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import Textarea from "@/components/ui/Textarea.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import ToolActionConfirmCard from "./ToolActionConfirmCard.vue";
import type { PendingToolAction } from "./toolActions";

const { state, loadConfig, saveConfig, syncConfigTemplate, openExternal, REPO } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const pendingConfigAction = ref<PendingToolAction | null>(null);
const localJsonStatus = ref("");
const configStats = computed(() => {
  const text = state.config.text;
  const lines = text ? text.split(/\r?\n/).length : 0;
  return {
    lines,
    chars: text.length,
    sizeKiB: (new TextEncoder().encode(text).length / 1024).toFixed(1)
  };
});

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

function issueUrl(): string {
  const sanitized = state.config.text
    .replace(/https?:\/\/\S+/g, "[filtered-url]")
    .replace(/(password|token|secret|uuid)["':= ]+[^,\n]+/gi, "$1=[filtered]");
  const body = [
    "已尝试过滤 URL、token、secret、password 等敏感字段；创建前仍需人工检查，避免提交私有订阅或密钥。",
    "",
    "## Target",
    state.config.target,
    "",
    "## Sanitized Config",
    "```",
    sanitized.slice(0, 12000),
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
