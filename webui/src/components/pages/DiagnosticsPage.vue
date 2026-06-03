<script setup lang="ts">
import { Copy, ExternalLink, RadioTower, RefreshCw, Server } from "lucide-vue-next";
import Badge from "@/components/ui/Badge.vue";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";

const { state, refreshHealth, refreshMcp, refreshPing, runCli, openExternal } = useMagicNet();
const { isRunning, withAction } = useActionLock();

const assistants = [
  ["ChatGPT", "https://chatgpt.com/"],
  ["Gemini", "https://gemini.google.com/"],
  ["Kimi", "https://www.kimi.com/"],
  ["Qwen", "https://chat.qwen.ai/"],
  ["DeepSeek", "https://chat.deepseek.com/"]
];

async function copyContextUnlocked(): Promise<void> {
  const text = await runCli("support bundle", "生成诊断上下文", true);
  state.output = await copyText(text) ? "诊断上下文已复制。" : "剪贴板不可用，诊断上下文已生成但未复制。";
}

async function copyContext(): Promise<void> {
  await withAction("copy-context", copyContextUnlocked);
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
