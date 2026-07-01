<script setup lang="ts">
import { computed, ref } from "vue";
import { Copy, FileText, RefreshCw } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import { useActionLock } from "@/composables/useActionLock";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";

const { runCli, state, compactOutput } = useMagicNet();
const { isRunning, withAction } = useActionLock();
const target = ref<"sing-box" | "mcp">("sing-box");
const lines = ref("120");
const query = ref("");
const level = ref<"all" | "warn" | "error">("all");
const output = ref("");
const copied = ref(false);
const lastLabel = ref("");

const commandPreview = computed(() => {
  const count = normalizedLines();
  return target.value === "mcp" ? `mcp logs ${count}` : `service logs sing-box ${count}`;
});
const logLines = computed(() => output.value.split(/\r?\n/).filter(Boolean));
const filteredLines = computed(() => logLines.value.filter((line) => {
  const lower = line.toLowerCase();
  const keyword = query.value.trim().toLowerCase();
  const matchesKeyword = !keyword || lower.includes(keyword);
  const matchesLevel = level.value === "all"
    || (level.value === "warn" && /\b(warn|warning)\b/i.test(line))
    || (level.value === "error" && /\b(error|failed|fatal|panic)\b/i.test(line));
  return matchesKeyword && matchesLevel;
}));
const warningCount = computed(() => logLines.value.filter((line) => /\b(warn|warning)\b/i.test(line)).length);
const errorCount = computed(() => logLines.value.filter((line) => /\b(error|failed|fatal|panic)\b/i.test(line)).length);
const visibleOutput = computed(() => filteredLines.value.join("\n"));

async function refreshLogs(): Promise<void> {
  const command = commandPreview.value;
  const label = target.value === "mcp" ? "读取 MCP 日志" : "读取 sing-box 日志";
  await withAction("runtime-logs", async () => {
    output.value = await runCli(command, label);
    lastLabel.value = label;
    copied.value = false;
  });
}

async function copyLogs(): Promise<void> {
  copied.value = await copyText(visibleOutput.value || output.value);
  state.output = copied.value ? "运行日志已复制。" : "剪贴板不可用，运行日志未复制。";
}

function normalizedLines(): number {
  const parsed = Number(lines.value);
  if (!Number.isFinite(parsed)) return 120;
  return Math.max(20, Math.min(1000, Math.round(parsed)));
}
</script>

<template>
  <Card class="grid gap-3">
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 class="inline-flex items-center gap-2 text-base font-semibold"><FileText :size="17" /> 运行日志</h3>
        <p class="mt-1 text-sm leading-6 text-zinc-400">
          真实读取设备侧日志尾部，用于排查 sing-box 和 MCP。
        </p>
      </div>
      <Button size="sm" variant="outline" :loading="isRunning('runtime-logs')" @click="refreshLogs">
        <RefreshCw :size="15" />刷新
      </Button>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_7rem_auto]">
      <select v-model="target" class="h-10 min-w-0 rounded-md border border-zinc-800 bg-zinc-950 px-3 text-sm text-zinc-100">
        <option value="sing-box">sing-box</option>
        <option value="mcp">MCP</option>
      </select>
      <Input v-model="lines" inputmode="numeric" placeholder="120" />
      <Button variant="secondary" :disabled="!output" @click="copyLogs">
        <Copy :size="15" />{{ copied ? "已复制" : "复制" }}
      </Button>
    </div>

    <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_8rem]">
      <Input v-model="query" placeholder="过滤关键字，例如 error / dns / selector" spellcheck="false" />
      <select v-model="level" class="h-10 min-w-0 rounded-md border border-zinc-800 bg-zinc-950 px-3 text-sm text-zinc-100">
        <option value="all">全部</option>
        <option value="warn">警告</option>
        <option value="error">错误</option>
      </select>
    </div>

    <div v-if="output" class="grid gap-2 text-xs text-zinc-400 sm:grid-cols-4">
      <span>日志 {{ logLines.length }} 行</span>
      <span>命中 {{ filteredLines.length }} 行</span>
      <span class="text-amber-300">警告 {{ warningCount }}</span>
      <span class="text-red-300">错误 {{ errorCount }}</span>
    </div>

    <code class="break-all rounded-md bg-black px-3 py-2 text-xs text-zinc-400">{{ commandPreview }}</code>
    <pre class="max-h-72 overflow-auto rounded-md bg-black p-3 text-xs leading-6 text-zinc-200 whitespace-pre-wrap">{{ output ? compactOutput(visibleOutput || "没有匹配的日志行。", 9000) : `${lastLabel || "选择目标后点击刷新。"} ` }}</pre>
  </Card>
</template>
