<script setup lang="ts">
import { computed, ref } from "vue";
import { Bug, Copy, ExternalLink, FileText, RadioTower, RefreshCw, Server } from "lucide-vue-next";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { sanitizeDiagnosticText } from "@/composables/issueDrafts";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import ConnectionsPanel from "./ConnectionsPanel.vue";
import NodeDelayPanel from "./NodeDelayPanel.vue";
import ProxyGroupsPanel from "./ProxyGroupsPanel.vue";
import TrafficStatsPanel from "./TrafficStatsPanel.vue";

const { state, refreshHealth, refreshMcp, refreshPing, runCli, createIssue, openExternal } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const supportBundle = ref("");
const supportCopied = ref(false);
const supportIssuesCopied = ref(false);
const supportSummary = computed(() => {
  const text = supportBundle.value;
  return {
    lines: text ? text.split(/\r?\n/).length : 0,
    chars: text.length
  };
});
const supportIssueLines = computed(() => supportBundle.value
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter((line) => /\b(warn|warning|fail|failed|error|fatal|panic)\b/i.test(line))
  .slice(0, 40));

const assistants = [
  ["ChatGPT", "https://chatgpt.com/"],
  ["Gemini", "https://gemini.google.com/"],
  ["Kimi", "https://www.kimi.com/"],
  ["Qwen", "https://chat.qwen.ai/"],
  ["DeepSeek", "https://chat.deepseek.com/"]
];

async function copyContextUnlocked(): Promise<void> {
  const text = await runCli("support bundle", "生成诊断上下文", true);
  const sanitized = sanitizeDiagnosticText(text);
  supportBundle.value = sanitized;
  supportCopied.value = false;
  supportIssuesCopied.value = false;
  state.output = await copyText(sanitized) ? "脱敏诊断上下文已复制。" : "剪贴板不可用，脱敏诊断上下文已生成但未复制。";
}

async function copyContext(): Promise<void> {
  await withAction("copy-context", copyContextUnlocked);
}

async function refreshSupportBundle(): Promise<void> {
  await withAction("support-bundle", async () => {
    const text = await runCli("support bundle", "生成支持包", true);
    supportBundle.value = sanitizeDiagnosticText(text);
    supportCopied.value = false;
    supportIssuesCopied.value = false;
    state.output = "脱敏支持包已生成，可在诊断页预览。";
  });
}

async function copySupportBundle(): Promise<void> {
  if (!supportBundle.value) return;
  supportCopied.value = await copyText(supportBundle.value);
  state.output = supportCopied.value ? "脱敏支持包已复制。" : "剪贴板不可用，脱敏支持包未复制。";
}

async function copySupportIssues(): Promise<void> {
  const text = supportIssueLines.value.join("\n");
  if (!text) return;
  supportIssuesCopied.value = await copyText(text);
  state.output = supportIssuesCopied.value ? "支持包问题摘要已复制。" : "剪贴板不可用，问题摘要未复制。";
}

async function refreshDiagnostics(): Promise<void> {
  await refreshMcp(true);
  await refreshHealth();
}

async function askAi(url: string, name: string): Promise<void> {
  await withAction(`ask-${name}`, async () => {
    await copyContextUnlocked();
    await openExternal(url, name);
  });
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Diagnostics" title="诊断" description="运行健康检查、连通性测试，并复制脱敏上下文给 AI。">
      <template #actions>
        <Button variant="outline" :loading="isRunning('health')" @click="withAction('health', refreshDiagnostics)"><RefreshCw :size="17" />健康检查</Button>
        <Button :loading="isRunning('ping')" @click="withAction('ping', () => refreshPing())"><RadioTower :size="17" />连通性测试</Button>
        <Button :loading="isRunning('create-issue')" @click="withAction('create-issue', createIssue)"><Bug :size="17" />创建 Issue</Button>
        <Button variant="outline" :loading="isRunning('copy-context')" @click="copyContext"><Copy :size="17" />复制上下文</Button>
      </template>
    </PageHeader>

    <Card>
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-md border border-zinc-800 bg-zinc-950 p-3">
        <div class="min-w-0">
          <h3 class="inline-flex items-center gap-2 text-base font-semibold"><Server :size="17" /> MCP 服务器</h3>
          <p class="mt-1 break-all text-sm text-zinc-400">pid={{ state.mcp.pid }} · {{ state.mcp.url }}</p>
        </div>
        <Badge :tone="state.mcp.pid !== 'stopped' ? 'success' : 'warning'">{{ state.mcp.pid !== "stopped" ? "已开启" : "未开启" }}</Badge>
      </div>
      <div class="flex flex-col gap-3">
        <div>
          <h3 class="text-base font-semibold">询问 AI</h3>
          <p class="mt-1 text-sm leading-6 text-zinc-400">先复制脱敏上下文，再用系统浏览器打开。</p>
        </div>
        <div class="grid grid-cols-2 gap-2 sm:grid-cols-5">
        <Button v-for="[name, url] in assistants" :key="name" variant="secondary" size="sm" :loading="isRunning(`ask-${name}`)" @click="askAi(url, name)">
          <ExternalLink :size="15" />{{ name }}
        </Button>
        </div>
      </div>
    </Card>

    <Card class="grid gap-3">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="inline-flex items-center gap-2 text-base font-semibold"><FileText :size="17" /> 支持包预览</h3>
          <p class="mt-1 text-sm leading-6 text-zinc-400">
            真实调用 <code>support bundle</code>，在本页只展示脱敏后的诊断上下文。
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <Button size="sm" variant="outline" :loading="isRunning('support-bundle')" @click="refreshSupportBundle">
            <RefreshCw :size="15" />生成
          </Button>
          <Button size="sm" variant="secondary" :disabled="!supportBundle" @click="copySupportBundle">
            <Copy :size="15" />{{ supportCopied ? "已复制" : "复制" }}
          </Button>
          <Button size="sm" variant="outline" :disabled="!supportIssueLines.length" @click="copySupportIssues">
            <Copy :size="15" />{{ supportIssuesCopied ? "已复制摘要" : "复制问题" }}
          </Button>
        </div>
      </div>
      <div v-if="supportBundle" class="grid gap-2 text-xs text-zinc-500 sm:grid-cols-3">
        <span>{{ supportSummary.lines }} 行</span>
        <span>{{ supportSummary.chars }} 字符</span>
        <span>{{ supportIssueLines.length }} 条问题线索</span>
      </div>
      <div v-if="supportIssueLines.length" class="rounded-md border border-amber-500/30 bg-amber-500/10 p-3">
        <p class="text-xs font-semibold uppercase tracking-wide text-amber-200">问题摘要</p>
        <pre class="mt-2 max-h-32 overflow-auto text-xs leading-5 text-amber-50 whitespace-pre-wrap">{{ supportIssueLines.join("\n") }}</pre>
      </div>
      <pre class="max-h-72 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ supportBundle || "点击生成查看脱敏支持包。" }}</pre>
    </Card>

    <TrafficStatsPanel />
    <ConnectionsPanel />
    <ProxyGroupsPanel />
    <NodeDelayPanel />

    <div class="grid gap-3 sm:grid-cols-2">
      <Card v-for="item in state.health" :key="item.key">
        <div class="flex items-start justify-between gap-3">
          <h3 class="min-w-0 break-words text-base font-semibold">{{ item.key }}</h3>
          <Badge :tone="item.status === 'ok' ? 'success' : item.status === 'fail' ? 'danger' : 'warning'">{{ item.status }}</Badge>
        </div>
        <p class="mt-2 break-words text-sm leading-6 text-zinc-300">{{ item.detail }}</p>
      </Card>
      <Card v-if="!state.health.length">
        <p class="text-sm text-zinc-400">还没有诊断结果。</p>
      </Card>
    </div>

    <Card v-if="state.pingtest">
      <h3 class="text-base font-semibold">连通性输出</h3>
      <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ state.pingtest }}</pre>
    </Card>
  </div>
</template>
