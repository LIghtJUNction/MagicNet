<script setup lang="ts">
import { Copy } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";

const { state, compactOutput } = useMagicNet();

async function copyOutput(): Promise<void> {
  state.output = await copyText(state.output) ? `${state.output}\n\n[info] 输出已复制。` : `${state.output}\n\n[warn] 剪贴板不可用。`;
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Command Output" title="最近输出" description="所有后台命令的状态和结果集中显示在这里。">
      <Button variant="outline" @click="copyOutput"><Copy :size="17" />复制输出</Button>
    </PageHeader>
    <Card>
      <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm text-zinc-400">
        <span>{{ state.phase }}</span>
        <code class="min-w-0 truncate text-zinc-300">{{ state.lastCommand || "等待执行" }}</code>
      </div>
      <pre class="mt-2 max-h-[58vh] overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ compactOutput(state.output, 5000) }}</pre>
    </Card>
  </div>
</template>
