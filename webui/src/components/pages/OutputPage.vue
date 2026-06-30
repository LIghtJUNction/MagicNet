<script setup lang="ts">
import { Copy } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { backgroundLogCommand, formatBackgroundDuration, formatBackgroundTime } from "@/composables/backgroundTasks";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";

const { state, compactOutput, runShell } = useMagicNet();

async function copyOutput(): Promise<void> {
  state.output = await copyText(state.output) ? `${state.output}\n\n[info] 输出已复制。` : `${state.output}\n\n[warn] 剪贴板不可用。`;
}

async function copyBackgroundLogPath(): Promise<void> {
  if (!state.backgroundTask.log) return;
  state.output = await copyText(state.backgroundTask.log)
    ? `${state.output}\n\n[info] 后台日志路径已复制。`
    : `${state.output}\n\n[warn] 剪贴板不可用。`;
}

async function refreshBackgroundLog(): Promise<void> {
  const { log, args, label } = state.backgroundTask;
  if (!log) return;
  const text = await runShell(backgroundLogCommand(log, args), `刷新后台日志 ${label}`, true);
  state.backgroundTask.updatedAt = Date.now();
  state.output = `后台日志已刷新：${label}\n\n${text || "日志为空。"}`;
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Command Output" title="最近输出" description="所有后台命令的状态和结果集中显示在这里。">
      <Button variant="outline" @click="copyOutput"><Copy :size="17" />复制输出</Button>
    </PageHeader>
    <Card v-if="state.backgroundTask.log" class="grid gap-3">
      <div class="flex min-w-0 flex-wrap items-center justify-between gap-3">
        <div class="min-w-0">
          <p class="text-sm font-semibold">最近后台任务</p>
          <p class="mt-1 text-sm text-zinc-400">{{ state.backgroundTask.label }} · {{ state.backgroundTask.status }}</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <Button variant="secondary" size="sm" @click="refreshBackgroundLog">刷新日志</Button>
          <Button variant="outline" size="sm" @click="copyBackgroundLogPath"><Copy :size="15" />复制路径</Button>
        </div>
      </div>
      <div class="grid gap-2 text-xs text-zinc-400 sm:grid-cols-3">
        <span>开始 {{ formatBackgroundTime(state.backgroundTask.startedAt) }}</span>
        <span>更新 {{ formatBackgroundTime(state.backgroundTask.updatedAt) }}</span>
        <span>耗时 {{ formatBackgroundDuration(state.backgroundTask) }}</span>
      </div>
      <div class="grid gap-2 text-xs text-zinc-400">
        <code class="break-all rounded-md bg-black px-3 py-2 text-zinc-200">{{ state.backgroundTask.log }}</code>
        <code class="break-all rounded-md bg-black px-3 py-2 text-zinc-200">{{ state.backgroundTask.args }}</code>
      </div>
    </Card>
    <Card>
      <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm text-zinc-400">
        <span>{{ state.phase }}</span>
        <code class="min-w-0 truncate text-zinc-300">{{ state.lastCommand || "等待执行" }}</code>
      </div>
      <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ compactOutput(state.output, 5000) }}</pre>
    </Card>
  </div>
</template>
