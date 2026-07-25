<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Copy, Search, X } from "lucide-vue-next";
import Button from "@/components/ui/Button.vue";
import Card from "@/components/ui/Card.vue";
import Input from "@/components/ui/Input.vue";
import PageHeader from "@/components/ui/PageHeader.vue";
import { backgroundLogCommand, formatBackgroundDuration, formatBackgroundTime } from "@/composables/backgroundTasks";
import { useMagicNet } from "@/composables/useMagicNet";
import { copyText } from "@/utils";
import RuntimeLogsPanel from "./RuntimeLogsPanel.vue";
import { buildOutputDiagnostic, outputDiagnosticTone, sanitizeOutputText } from "./outputDiagnostics";

const { state, compactOutput, runShell } = useMagicNet();
const outputQuery = ref("");
const copied = ref(false);
const issueCopied = ref(false);
const issuePattern = /\b(warn|warning|fail|failed|error|fatal|panic|denied|timeout|not found)\b/i;

const outputLines = computed(() => state.output.split(/\r?\n/));
const outputStats = computed(() => {
  const nonEmpty = outputLines.value.filter((line) => line.trim());
  const issueLines = nonEmpty.filter((line) => issuePattern.test(line));
  return {
    lines: outputLines.value.length,
    chars: state.output.length,
    issueLines: issueLines.length
  };
});
const filteredOutput = computed(() => {
  const query = outputQuery.value.trim().toLowerCase();
  if (!query) return state.output;
  return outputLines.value.filter((line) => line.toLowerCase().includes(query)).join("\n");
});
const outputDiagnostic = computed(() => buildOutputDiagnostic({
  phase: state.phase,
  lines: outputStats.value.lines,
  chars: outputStats.value.chars,
  issueLines: outputStats.value.issueLines,
  filtered: Boolean(outputQuery.value.trim())
}));
const issueSummary = computed(() => outputLines.value
  .map((line) => line.trim())
  .filter((line) => issuePattern.test(line))
  .slice(0, 60)
  .join("\n"));
const visibleOutput = computed(() => compactOutput(filteredOutput.value || "没有匹配的输出行。", 7000));

watch(outputQuery, () => {
  copied.value = false;
});

watch(() => state.output, () => {
  copied.value = false;
  issueCopied.value = false;
});

async function copyOutput(): Promise<void> {
  copied.value = await copyText(sanitizeOutputText(filteredOutput.value || state.output));
  state.notice = copied.value ? "脱敏输出已复制。" : "剪贴板不可用，输出未复制。";
}

async function copyIssueSummary(): Promise<void> {
  if (!issueSummary.value) return;
  issueCopied.value = await copyText(sanitizeOutputText(issueSummary.value));
  state.notice = issueCopied.value ? "输出问题摘要已复制。" : "剪贴板不可用，问题摘要未复制。";
}

async function copyBackgroundLogPath(): Promise<void> {
  if (!state.backgroundTask.log) return;
  state.notice = await copyText(state.backgroundTask.log) ? "后台日志路径已复制。" : "剪贴板不可用，日志路径未复制。";
}

async function refreshBackgroundLog(): Promise<void> {
  const { log, args, label } = state.backgroundTask;
  if (!log) return;
  const text = await runShell(backgroundLogCommand(log, args), `刷新后台日志 ${label}`, true);
  state.backgroundTask.updatedAt = Date.now();
  state.output = `后台日志已刷新：${label}\n\n${text || "日志为空。"}`;
  copied.value = false;
  issueCopied.value = false;
}

function clearOutputFilter(): void {
  outputQuery.value = "";
}
</script>

<template>
  <div class="grid gap-4">
    <PageHeader overline="Command Output" title="最近输出" description="所有后台命令的状态和结果集中显示在这里。">
      <template #actions>
        <Button variant="outline" @click="copyOutput"><Copy :size="17" />{{ copied ? "已复制脱敏" : "复制脱敏输出" }}</Button>
        <Button variant="outline" :disabled="!issueSummary" @click="copyIssueSummary"><Copy :size="17" />{{ issueCopied ? "已复制问题" : "复制问题" }}</Button>
      </template>
    </PageHeader>
    <RuntimeLogsPanel />
    <Card v-if="state.backgroundTask.log" class="grid gap-3">
      <div class="flex min-w-0 flex-wrap items-center justify-between gap-3">
        <div class="min-w-0">
          <p class="text-sm font-semibold">最近后台任务</p>
          <p class="mt-1 text-sm text-[var(--mn-ink-muted)]">{{ state.backgroundTask.label }} · {{ state.backgroundTask.status }}</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <Button variant="secondary" size="sm" @click="refreshBackgroundLog">刷新日志</Button>
          <Button variant="outline" size="sm" @click="copyBackgroundLogPath"><Copy :size="15" />复制路径</Button>
        </div>
      </div>
      <div class="grid gap-2 text-xs text-[var(--mn-ink-muted)] sm:grid-cols-3">
        <span>开始 {{ formatBackgroundTime(state.backgroundTask.startedAt) }}</span>
        <span>更新 {{ formatBackgroundTime(state.backgroundTask.updatedAt) }}</span>
        <span>耗时 {{ formatBackgroundDuration(state.backgroundTask) }}</span>
      </div>
      <div class="grid gap-2 text-xs text-[var(--mn-ink-muted)]">
        <code class="break-all rounded-md bg-[var(--mn-carrier-deep)] px-3 py-2 text-[var(--mn-ink-soft)]">{{ state.backgroundTask.log }}</code>
        <code class="break-all rounded-md bg-[var(--mn-carrier-deep)] px-3 py-2 text-[var(--mn-ink-soft)]">{{ state.backgroundTask.args }}</code>
      </div>
    </Card>
    <Card class="grid gap-3">
      <div class="grid gap-2 text-xs text-[var(--mn-ink-muted)] sm:grid-cols-4">
        <span>阶段 {{ state.phase }}</span>
        <span>{{ outputStats.lines }} 行</span>
        <span>{{ outputStats.chars }} 字符</span>
        <span>{{ outputStats.issueLines }} 条问题线索</span>
      </div>
      <div class="rounded-md border p-3" :class="outputDiagnosticTone(outputDiagnostic.status)">
        <p class="text-sm font-semibold">{{ outputDiagnostic.title }}</p>
        <p class="mt-1 break-words text-sm leading-6 opacity-80">{{ outputDiagnostic.detail }}</p>
      </div>
      <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
        <label class="relative block">
          <Search class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--mn-ink-muted)]" :size="15" />
          <Input v-model="outputQuery" class="pl-9" placeholder="过滤当前输出，例如 error、timeout、api stats" spellcheck="false" />
        </label>
        <Button variant="ghost" :disabled="!outputQuery" @click="clearOutputFilter"><X :size="16" />清除过滤</Button>
      </div>
      <div v-if="issueSummary" class="rounded-md mn-panel-warn p-3">
        <p class="text-xs font-semibold uppercase tracking-wide text-[var(--mn-warning)]">问题线索</p>
        <pre class="mt-2 max-h-32 overflow-auto text-xs leading-5 text-[var(--mn-warning)] whitespace-pre-wrap">{{ issueSummary }}</pre>
      </div>
      <div class="flex min-w-0 flex-wrap items-center gap-2 text-sm text-[var(--mn-ink-muted)]">
        <code class="min-w-0 truncate text-[var(--mn-ink-soft)]">{{ state.lastCommand || "等待执行" }}</code>
      </div>
      <pre class="max-h-[58vh] overflow-auto rounded-md bg-[var(--mn-carrier-deep)] p-3 text-xs leading-6 text-[var(--mn-ink-soft)] whitespace-pre-wrap">{{ visibleOutput }}</pre>
    </Card>
  </div>
</template>
